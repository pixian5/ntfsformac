import Cocoa

/// NTFSFormac 菜单栏 App
/// 显示 NTFS 盘及读写状态，提供 挂载为读写 / 卸载 / 安全弹出 / 在 Finder 打开。
/// 特权操作通过 sudo 免密提权（/etc/sudoers.d/ntfsformac），无需弹窗。
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    static let ntfsctl = "/usr/local/bin/ntfsctl"
    static let driver = "/usr/local/bin/ntfs-3g"
    static let logFile = "/var/log/ntfsformac-automount.log"

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    struct Disk: Equatable {
        var device: String
        var label: String
        var mountPoint: String
        var state: String   // rw / ro / none
    }

    private var statusItem: NSStatusItem?
    private var disks: [Disk] = []
    private var timer: Timer?

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = item.button {
            btn.image = NSImage(systemSymbolName: "externaldrive.fill",
                                accessibilityDescription: "NTFS 工具")
        }
        statusItem = item

        timer = Timer(timeInterval: 3, target: self, selector: #selector(refresh),
                      userInfo: nil, repeats: true)
        RunLoop.main.add(timer!, forMode: .common)

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refresh),
            name: NSWorkspace.didMountNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refresh),
            name: NSWorkspace.didUnmountNotification, object: nil)

        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }

    // MARK: - 刷新

    @objc func refresh() {
        disks = listDisks()
        buildMenu()
    }

    private func listDisks() -> [Disk] {
        let out = run(Self.ntfsctl, ["list", "--porcelain"])
        var result: [Disk] = []
        for line in out.split(separator: "\n") {
            let f = line.split(separator: "|", omittingEmptySubsequences: false)
            guard f.count >= 5 else { continue }
            result.append(Disk(device: String(f[0]),
                               label: String(f[1]),
                               mountPoint: String(f[3]),
                               state: String(f[4])))
        }
        return result
    }

    // MARK: - 菜单

    private func buildMenu() {
        let menu = NSMenu()

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let header = NSMenuItem(title: "NTFSFormac v\(version)（FUSE-T）", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let driverOK = FileManager.default.isExecutableFile(atPath: Self.driver)
        let driverItem = NSMenuItem(title: driverOK ? "驱动：正常" : "驱动：未安装！", action: nil, keyEquivalent: "")
        driverItem.isEnabled = false
        menu.addItem(driverItem)

        menu.addItem(.separator())

        if disks.isEmpty {
            let empty = NSMenuItem(title: "未检测到 NTFS 磁盘", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for disk in disks {
                menu.addItem(makeDiskItem(disk))
            }
        }

        menu.addItem(.separator())

        let rescan = NSMenuItem(title: "重新扫描", action: #selector(refresh), keyEquivalent: "r")
        rescan.target = self
        menu.addItem(rescan)

        let log = NSMenuItem(title: "打开自动挂载日志", action: #selector(openLog), keyEquivalent: "")
        log.target = self
        menu.addItem(log)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem?.menu = menu
    }

    private func makeDiskItem(_ disk: Disk) -> NSMenuItem {
        let tag = disk.state == "rw" ? "● RW" : (disk.state == "ro" ? "○ RO" : "○ 未挂载")
        let item = NSMenuItem(title: "\(disk.label)  [\(tag)]", action: nil, keyEquivalent: "")
        let sub = NSMenu()

        if disk.state != "rw" {
            let mount = NSMenuItem(title: "挂载为读写", action: #selector(actionMount(_:)), keyEquivalent: "")
            mount.target = self
            mount.representedObject = disk
            sub.addItem(mount)
        }

        if !disk.mountPoint.isEmpty {
            let open = NSMenuItem(title: "在 Finder 中打开", action: #selector(actionOpen(_:)), keyEquivalent: "")
            open.target = self
            open.representedObject = disk
            sub.addItem(open)
        }

        let unmount = NSMenuItem(title: "卸载", action: #selector(actionUnmount(_:)), keyEquivalent: "")
        unmount.target = self
        unmount.representedObject = disk
        sub.addItem(unmount)

        let eject = NSMenuItem(title: "安全弹出", action: #selector(actionEject(_:)), keyEquivalent: "")
        eject.target = self
        eject.representedObject = disk
        sub.addItem(eject)

        item.submenu = sub
        return item
    }

    // MARK: - 动作

    @objc private func actionMount(_ sender: NSMenuItem) {
        guard let d = sender.representedObject as? Disk else { return }
        runAdmin("\(Self.ntfsctl) mount \(d.device)")
        refresh()
    }

    @objc private func actionUnmount(_ sender: NSMenuItem) {
        guard let d = sender.representedObject as? Disk else { return }
        runAdmin("\(Self.ntfsctl) unmount \(d.device)")
        refresh()
    }

    @objc private func actionEject(_ sender: NSMenuItem) {
        guard let d = sender.representedObject as? Disk else { return }
        runAdmin("\(Self.ntfsctl) eject \(d.device)")
        refresh()
    }

    @objc private func actionOpen(_ sender: NSMenuItem) {
        guard let d = sender.representedObject as? Disk, !d.mountPoint.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: d.mountPoint))
    }

    @objc private func openLog() {
        if FileManager.default.fileExists(atPath: Self.logFile) {
            NSWorkspace.shared.open(URL(fileURLWithPath: Self.logFile))
        } else {
            alert("日志文件不存在", "守护进程可能尚未运行。")
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - 特权执行

    @discardableResult
    private func runAdmin(_ command: String) -> Bool {
        // sudo 已配置免密（/etc/sudoers.d/ntfsformac），直接提权执行，无需授权框
        let out = run("/usr/bin/sudo", ["-n", "/bin/bash", "-c", command])
        let ok = !out.contains("error") && !out.contains("password")
        if !ok {
            alert("操作失败", "\(command)\n\n\(out)\n\n提示：若提示需要密码，请检查 /etc/sudoers.d/ntfsformac 免密配置。")
        }
        return ok
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.alertStyle = .warning
        a.runModal()
    }

    // MARK: - 子进程

    private func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return ""
        }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        return (String(data: d, encoding: .utf8) ?? "") + (String(data: e, encoding: .utf8) ?? "")
    }
}
