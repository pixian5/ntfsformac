import Cocoa
import ServiceManagement
import UserNotifications

/// NTFSFormac 菜单栏 App
/// 显示 NTFS 盘及读写状态，提供 挂载为读写 / 卸载 / 安全弹出 / 在 Finder 打开。
/// 特权操作通过 sudo 免密提权（/etc/sudoers.d/ntfsformac），无需弹窗。
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

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
        var fs: String         // ntfs / bitlocker
        var mountPoint: String
        var state: String      // rw / ro / none / locked
    }

    private var statusItem: NSStatusItem?
    private var disks: [Disk] = []
    private var timer: Timer?
    private var prevStates: [String: String] = [:]   // device -> state 上次快照（用于事件通知）
    private var autoTried: Set<String> = []          // 本会话已尝试过自动解锁的设备（避免反复试探）
    private let keychainService = "NTFSFormac"       // 钥匙串条目 service 名（BitLocker 密码记忆）

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = item.button {
            btn.image = NSImage(systemSymbolName: "externaldrive.fill",
                                accessibilityDescription: "NTFS 工具")
        }
        statusItem = item

        // 开机自启（macOS 13+ 官方 API；App 位于 /Applications 时才能注册成功）
        if #available(macOS 13.0, *) {
            try? SMAppService.mainApp.register()
        }
        // 挂载/卸载事件通知权限
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

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
        let before = prevStates
        disks = listDisks()

        // BitLocker：若钥匙串里存过密码，则插入后自动解锁（每设备本会话只试一次，绝不弹窗）
        autoTried = autoTried.intersection(Set(disks.map { $0.device }))
        for d in disks where d.fs == "bitlocker" && d.state == "locked" {
            if autoTried.contains(d.device) { continue }
            autoTried.insert(d.device)
            guard let pw = loadPassword(for: d.device) else { continue }
            if unlockBitLocker(device: d.device, password: pw) {
                postNotification(title: "BitLocker 已自动解锁",
                                 body: "\(d.label) 已用记住的密码解锁并挂载")
            } else {
                postNotification(title: "BitLocker 自动解锁失败",
                                 body: "\(d.label)：保存的密码已失效，已清除（请手动解锁）")
                forgetPassword(for: d.device)
            }
            disks = listDisks()
            break
        }

        var after: [String: String] = [:]
        for d in disks { after[d.device] = d.state }
        notifyChanges(before: before, after: after)
        prevStates = after
        updateIcon()
        buildMenu()
    }

    // MARK: - 事件通知（挂载/卸载）

    private func notifyChanges(before: [String: String], after: [String: String]) {
        for (dev, st) in after {
            guard let old = before[dev] else { continue }
            let label = disks.first(where: { $0.device == dev })?.label ?? dev
            if old != "rw" && st == "rw" {
                postNotification(title: "NTFS 已挂载", body: "\(label) 已挂载为读写")
            } else if old == "rw" && st != "rw" {
                postNotification(title: "NTFS 已卸载", body: "\(label) 已卸载")
            }
        }
    }

    private func postNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // MARK: - 图标状态化（无盘 / 有盘未挂 / 有盘 rw）

    private func updateIcon() {
        guard let btn = statusItem?.button else { return }
        if disks.contains(where: { $0.state == "rw" }) {
            btn.image = NSImage(systemSymbolName: "externaldrive.fill.badge.checkmark",
                                accessibilityDescription: "NTFS 工具")
        } else if disks.contains(where: { $0.state == "locked" }) {
            // 有 BitLocker 加密盘等待解锁
            btn.image = NSImage(systemSymbolName: "lock.fill",
                                accessibilityDescription: "NTFS 工具（有加密盘待解锁）")
        } else if disks.isEmpty {
            btn.image = NSImage(systemSymbolName: "externaldrive",
                                accessibilityDescription: "NTFS 工具")
        } else {
            btn.image = NSImage(systemSymbolName: "externaldrive.badge.exclamationmark",
                                accessibilityDescription: "NTFS 工具")
        }
    }

    private func listDisks() -> [Disk] {
        // 必须以 root 运行：BitLocker 签名检测需要读取裸设备首扇区，
        // 真实磁盘设备节点属主是 root:operator，普通用户无权读。
        let out = run("/usr/bin/sudo", ["-n", Self.ntfsctl, "list", "--porcelain"])
        var result: [Disk] = []
        for line in out.split(separator: "\n") {
            let f = line.split(separator: "|", omittingEmptySubsequences: false)
            guard f.count >= 5 else { continue }
            result.append(Disk(device: String(f[0]),
                               label: String(f[1]),
                               fs: String(f[2]),
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
        let ver = driverVersion()
        let driverTitle = driverOK
            ? "驱动：正常\(ver.isEmpty ? "" : " (ntfs-3g \(ver))")"
            : "驱动：未安装！"
        let driverItem = NSMenuItem(title: driverTitle, action: nil, keyEquivalent: "")
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

        let check = NSMenuItem(title: "检查驱动更新", action: #selector(checkUpdate), keyEquivalent: "")
        check.target = self
        menu.addItem(check)

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
        let tag: String
        switch disk.state {
        case "rw":     tag = "● RW"
        case "ro":     tag = "○ RO"
        case "locked": tag = "○ 加密未解锁"
        default:       tag = "○ 未挂载"
        }
        let item = NSMenuItem(title: "\(disk.label)  [\(tag)]", action: nil, keyEquivalent: "")
        let sub = NSMenu()

        if disk.fs == "bitlocker" && disk.state == "locked" {
            // 加密卷未解锁：主操作是解锁（不猜密码，由用户输入）
            let unlock = NSMenuItem(title: "解锁 BitLocker…", action: #selector(actionUnlockBL(_:)), keyEquivalent: "")
            unlock.target = self
            unlock.representedObject = disk
            sub.addItem(unlock)
        } else if disk.state != "rw" {
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

        if disk.fs == "bitlocker" && disk.state != "locked" {
            let lock = NSMenuItem(title: "重新锁定 BitLocker", action: #selector(actionLockBL(_:)), keyEquivalent: "")
            lock.target = self
            lock.representedObject = disk
            sub.addItem(lock)
        }

        if disk.fs == "bitlocker" {
            let forget = NSMenuItem(title: "忘记已保存的密码", action: #selector(actionForgetBL(_:)), keyEquivalent: "")
            forget.target = self
            forget.representedObject = disk
            sub.addItem(forget)
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
        runAdmin(["mount", d.device])
        refresh()
    }

    @objc private func actionUnmount(_ sender: NSMenuItem) {
        guard let d = sender.representedObject as? Disk else { return }
        runAdmin(["unmount", d.device])
        refresh()
    }

    @objc private func actionEject(_ sender: NSMenuItem) {
        guard let d = sender.representedObject as? Disk else { return }
        runAdmin(["eject", d.device])
        refresh()
    }

    // MARK: - BitLocker 解锁 / 锁定 / 密码记忆

    /// 弹窗输入 BitLocker 密码（可选「记住密码」存到登录钥匙串，下次插入自动解锁）
    private func promptBitLockerPassword(label: String) -> (String, Bool)? {
        let a = NSAlert()
        a.messageText = "解锁 BitLocker：\(label)"
        a.informativeText = "请输入该加密卷的用户密码（大小写敏感）。密码只在本机使用，不会上传。"
        a.alertStyle = .informational
        a.addButton(withTitle: "解锁")
        a.addButton(withTitle: "取消")

        let access = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 54))
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 28, width: 320, height: 24))
        field.placeholderString = "BitLocker 密码"
        let remember = NSButton(checkboxWithTitle: "记住密码（下次插入自动解锁）", target: nil, action: nil)
        remember.frame = NSRect(x: 0, y: 2, width: 320, height: 20)
        access.addSubview(field)
        access.addSubview(remember)
        a.accessoryView = access

        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let pw = field.stringValue
        guard !pw.isEmpty else { return nil }
        return (pw, remember.state == .on)
    }

    @objc private func actionUnlockBL(_ sender: NSMenuItem) {
        guard let d = sender.representedObject as? Disk else { return }
        guard let (pw, remember) = promptBitLockerPassword(label: d.label) else { return }
        if unlockBitLocker(device: d.device, password: pw) {
            if remember { savePassword(pw, for: d.device) }
            postNotification(title: "BitLocker 已解锁", body: "\(d.label) 已解锁并挂载为读写")
        }
        refresh()
    }

    @objc private func actionLockBL(_ sender: NSMenuItem) {
        guard let d = sender.representedObject as? Disk else { return }
        runAdmin(["lock", d.device])
        refresh()
    }

    @objc private func actionForgetBL(_ sender: NSMenuItem) {
        guard let d = sender.representedObject as? Disk else { return }
        forgetPassword(for: d.device)
        alert("已忘记密码", "已从钥匙串删除 \(d.label) 保存的密码。")
        refresh()
    }

    /// 解锁：密码写入 0600 临时文件后以 --password-file 传入，
    /// 避免密码出现在进程参数（ps）中；用完立即删除。
    private func unlockBitLocker(device: String, password: String) -> Bool {
        let tmp = NSTemporaryDirectory() + "ntfsformac-bl-\(UUID().uuidString)"
        do {
            try password.write(toFile: tmp, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp)
        } catch {
            alert("解锁失败", "无法创建临时密码文件：\(error.localizedDescription)")
            return false
        }
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        return runAdmin(["unlock", device, "--password-file", tmp])
    }

    // MARK: - 钥匙串（BitLocker 密码记忆）

    private func savePassword(_ pw: String, for device: String) {
        run("/usr/bin/security", ["delete-generic-password", "-s", keychainService, "-a", device])
        run("/usr/bin/security", ["add-generic-password", "-s", keychainService, "-a", device, "-w", pw])
    }

    private func loadPassword(for device: String) -> String? {
        let (code, out) = runWithStatus("/usr/bin/security",
                                        ["find-generic-password", "-s", keychainService, "-a", device, "-w"])
        guard code == 0 else { return nil }
        let pw = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return pw.isEmpty ? nil : pw
    }

    private func forgetPassword(for device: String) {
        run("/usr/bin/security", ["delete-generic-password", "-s", keychainService, "-a", device])
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
    private func runAdmin(_ args: [String]) -> Bool {
        // sudo 免密直接执行 ntfsctl（sudoers 白名单仅放行 ntfsctl，无 bash 包装，最小化提权面）
        let (code, out) = runWithStatus("/usr/bin/sudo", ["-n", Self.ntfsctl] + args)
        guard code == 0 else {
            alert("操作失败", "\(Self.ntfsctl) \(args.joined(separator: " "))\n\n\(out)\n\n提示：若提示需要密码，请检查 /etc/sudoers.d/ntfsformac 免密配置。")
            return false
        }
        return true
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.alertStyle = .warning
        a.runModal()
    }

    // MARK: - 驱动版本检查（本地 + 远端 GitHub release）

    private func driverVersion() -> String {
        let out = run("/usr/local/bin/ntfs-3g", ["--version"])
        return out.split(separator: "\n").first.map {
            String($0).trimmingCharacters(in: .whitespaces)
        } ?? ""
    }

    @objc private func checkUpdate() {
        Task { @MainActor in
            let (latest, err) = await fetchLatestVersion()
            if let latest {
                let local = driverVersion()
                if local.contains(latest) {
                    alert("驱动更新检查", "ntfs-3g 已是最新版本（\(latest)）")
                } else {
                    alert("驱动更新检查",
                          "本机 ntfs-3g：\(local)\nGitHub 最新：\(latest)\n\n升级方法：在终端运行 bash install-driver.sh（会重新构建安装）。")
                }
            } else {
                alert("驱动更新检查", "查询失败：\(err ?? "网络不可用")")
            }
        }
    }

    private func fetchLatestVersion() async -> (String?, String?) {
        let url = URL(string: "https://api.github.com/repos/macos-fuse-t/ntfs-3g/releases/latest")!
        var req = URLRequest(url: url)
        req.setValue("NTFSFormac/0.1", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                return (nil, "HTTP \(String(describing: (resp as? HTTPURLResponse)?.statusCode))")
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = json["tag_name"] as? String {
                return (tag, nil)
            }
            return (nil, "解析失败")
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    // MARK: - 子进程

    @discardableResult
    private func run(_ path: String, _ args: [String]) -> String {
        runWithStatus(path, args).1
    }

    /// 执行子进程，返回（退出码, 合并后的 stdout+stderr）
    private func runWithStatus(_ path: String, _ args: [String]) -> (Int32, String) {
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
            return (-1, "")
        }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        return (p.terminationStatus,
                (String(data: d, encoding: .utf8) ?? "") + (String(data: e, encoding: .utf8) ?? ""))
    }
}
