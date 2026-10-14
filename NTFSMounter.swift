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
        var guid: String = ""  // BitLocker 卷 GUID（明文可读、跨插拔稳定，用于钥匙串键）；非 BitLocker 为空
    }

    private var statusItem: NSStatusItem?
    private var disks: [Disk] = []
    private var timer: Timer?
    private var prevStates: [String: String] = [:]   // device -> state 上次快照（用于事件通知）
    private var autoTried: Set<String> = []          // 本会话已尝试过自动解锁的键（避免反复试探）
    private var noCredChecked: Set<String> = []      // 本会话已确认「无保存凭据」的键（避免每 3 秒重复查钥匙串）
    private var manualLockNoticed: Set<String> = []  // 已记录过「手动锁定」日志的键（避免每 3 秒刷屏）
    private let keychainService = "NTFSFormac"       // 钥匙串条目 service 名（BitLocker 密码记忆）

    /// ntfsctl 的运行时目录（root 属主但权限 0755，App 以普通用户身份可读，无需提权）
    private static let runDir = "/var/run/ntfsformac"

    /// 该盘是否被用户「手动锁定」：ntfsctl lock 会落下 <runDir>/locked.<dev> 标记。
    /// 标记由 ntfsctl unlock / eject 清除，设备节点消失（拔盘）时由 ntfsctl list 自动清理，
    /// 所以重新插拔后（哪怕盘号没变）自动解锁会恢复正常。
    private func isManuallyLocked(_ disk: Disk) -> Bool {
        FileManager.default.fileExists(atPath: "\(Self.runDir)/locked.\(disk.device)")
    }

    // MARK: - 运行日志（开发测试版：详细记录自动解锁等关键决策，便于排错）
    // 写入 ~/Library/Logs/NTFSFormac/app.log（用户目录可写，符合 macOS 日志惯例；
    // 绝不记录凭据明文，只记方法码与长度）。
    private static let appLogPath =
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/NTFSFormac/app.log")

    func appLog(_ s: String) {
        let dir = (Self.appLogPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // 超过 1MB 就截断重开，避免无限增长
        if let sz = try? FileManager.default.attributesOfItem(atPath: Self.appLogPath)[.size] as? Int,
           sz > 1_048_576 {
            try? FileManager.default.removeItem(atPath: Self.appLogPath)
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(fmt.string(from: Date())) \(s)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let fh = FileHandle(forWritingAtPath: Self.appLogPath) {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: Self.appLogPath))
        }
    }

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        appLog("applicationDidFinishLaunching: 启动")
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

        // BitLocker：若钥匙串里存过凭据（用户密码 / 恢复密码 / .BEK 路径），插入后自动解锁
        //（每设备本会话只试一次，绝不弹窗，也绝不猜密码）
        // 键用「卷 GUID」（跨插拔稳定），无 GUID 时回退设备名
        let liveKeys = Set(disks.map { keychainAccount(for: $0) })
        autoTried = autoTried.intersection(liveKeys)
        noCredChecked = noCredChecked.intersection(liveKeys)
        manualLockNoticed = manualLockNoticed.intersection(liveKeys)
        for d in disks where d.fs == "bitlocker" && d.state == "locked" {
            let key = keychainAccount(for: d)
            // 用户手动锁定过（命令行 ntfsctl lock / 菜单「重新锁定 BitLocker」）→ 尊重意图，不自动解锁。
            // 否则命令行的 lock 会在 3 秒内被 App 重新解开，等于锁不住。
            if isManuallyLocked(d) {
                if manualLockNoticed.insert(key).inserted {
                    appLog("\(d.device) 存在手动锁定标记，跳过自动解锁（ntfsctl unlock 或菜单解锁后恢复）")
                }
                continue
            }
            manualLockNoticed.remove(key)
            if autoTried.contains(key) || noCredChecked.contains(key) { continue }
            // 必须先确认「有保存的凭据」才记入 autoTried。
            // 旧版在这里就先写入 autoTried，于是「第一次插入时还没记住密码」的盘会被永久标记为
            // 已尝试，之后哪怕保存了凭据（如重新锁定后再看）也永远不会再自动解锁。
            guard let (method, cred) = loadCredential(for: d) else {
                noCredChecked.insert(key)   // 确无凭据：本会话不再每 3 秒重复查一次钥匙串
                continue
            }
            autoTried.insert(key)
            // 记住的 .BEK 文件若已被移走就跳过并清除，避免无谓的失败提示
            if method == .bekFile && !FileManager.default.fileExists(atPath: cred) {
                appLog("\(d.device) 记住的 BEK 文件已不存在，清除凭据")
                forgetPassword(for: d)
                continue
            }
            appLog("\(d.device) guid=\(d.guid) 找到凭据 method=\(methodCode(method))，尝试自动解锁")
            if unlockBitLocker(device: d.device, method: method, credential: cred) {
                appLog("\(d.device) 自动解锁成功")
                postNotification(title: "BitLocker 已自动解锁",
                                 body: "\(d.label) 已用记住的凭据解锁并挂载")
            } else {
                appLog("\(d.device) 自动解锁失败，已清除保存的凭据")
                postNotification(title: "BitLocker 自动解锁失败",
                                 body: "\(d.label)：保存的凭据已失效，已清除（请手动解锁）")
                forgetPassword(for: d)
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
                               state: String(f[4]),
                               guid: f.count >= 6 ? String(f[5]) : ""))
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
        // 手动锁定（命令行 ntfsctl lock 或菜单锁定）会让 App 停止自动解锁，菜单里明示出来
        let manualLocked = disk.state == "locked" && isManuallyLocked(disk)
        // 「其它分区」：非 NTFS/BitLocker 的外置分区（如 Ventoy 的 VTOYEFI）。
        // 这类分区 macOS 因分区类型拒绝挂载，ntfsctl 改走「只读裸镜像」路径（挂的是内容副本，
        // 写入不回写原盘），语义与普通盘的读写挂载不同，菜单需区别对待。
        let isOther = disk.fs != "ntfs" && disk.fs != "bitlocker"
        let tag: String
        if isOther {
            switch disk.state {
            case "ro":  tag = "○ 只读已挂载"
            case "rw":  tag = "● RW"                 // 理论上不会出现（其它分区只读）
            default:    tag = "○ 只读副本·未挂载"
            }
        } else {
            switch disk.state {
            case "rw":     tag = "● RW"
            case "ro":     tag = "○ RO"
            case "locked": tag = manualLocked ? "○ 加密·已手动锁定" : "○ 加密未解锁"
            default:       tag = "○ 未挂载"
            }
        }
        let title = isOther ? "\(disk.label)  [\(tag)]（\(disk.fs)）" : "\(disk.label)  [\(tag)]"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()

        if isOther {
            // 其它分区只提供「只读浏览」：说明这是副本，写入不回写原盘
            let hint = NSMenuItem(title: "只读浏览：导出为免分区表镜像后挂载，写入不回写原盘",
                                  action: nil, keyEquivalent: "")
            hint.isEnabled = false
            sub.addItem(hint)
            sub.addItem(.separator())
            if disk.state != "ro" && disk.state != "rw" {
                let mount = NSMenuItem(title: "只读挂载（浏览副本）",
                                       action: #selector(actionMount(_:)), keyEquivalent: "")
                mount.target = self
                mount.representedObject = disk
                sub.addItem(mount)
            }
        } else if disk.fs == "bitlocker" && disk.state == "locked" {
            if manualLocked {
                let hint = NSMenuItem(title: "已手动锁定：不会自动解锁（解锁后即恢复）",
                                      action: nil, keyEquivalent: "")
                hint.isEnabled = false
                sub.addItem(hint)
                sub.addItem(.separator())
            }
            // 加密卷未解锁：提供三种凭据入口（用户密码 / 48 位恢复密码 / .BEK 恢复密钥文件）。
            // 绝不猜密码，凭据一律由用户主动输入或选择文件。
            let entries: [(String, Selector)] = [
                ("用密码解锁…", #selector(actionUnlockBL(_:))),
                ("用恢复密码解锁…", #selector(actionUnlockBLRecovery(_:))),
                ("用 .BEK 文件解锁…", #selector(actionUnlockBLBEK(_:))),
            ]
            for (title, sel) in entries {
                let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
                it.target = self
                it.representedObject = disk
                sub.addItem(it)
            }
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
            let lock = NSMenuItem(title: "锁定 BitLocker（锁定后不再自动解锁）",
                                  action: #selector(actionLockBL(_:)), keyEquivalent: "")
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

    // MARK: - BitLocker 解锁 / 锁定 / 凭据记忆

    /// BitLocker 解锁凭据类型（对应 ntfsctl unlock 的不同参数）
    private enum UnlockMethod {
        case userPassword      // --password：用户设置的密码
        case recoveryPassword  // --recovery：48 位数字恢复密码
        case bekFile           // --bek：Windows 导出的 .BEK 恢复密钥文件
    }

    /// 把方法映射为钥匙串里的标记码
    private func methodCode(_ method: UnlockMethod) -> String {
        switch method {
        case .userPassword:     return "u"
        case .recoveryPassword: return "r"
        case .bekFile:          return "b"
        }
    }

    /// 弹窗输入 BitLocker 用户密码（可选「记住密码」存到登录钥匙串，下次插入自动解锁）
    private func promptBitLockerPassword(label: String) -> (String, Bool)? {
        let a = NSAlert()
        a.messageText = "用密码解锁 BitLocker：\(label)"
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

    /// 弹窗输入 48 位 BitLocker 恢复密码（连字符可带也可省略，ntfsctl 会规范化为 dislocker 要求的格式）
    private func promptBitLockerRecovery(label: String) -> (String, Bool)? {
        let a = NSAlert()
        a.messageText = "用恢复密码解锁：\(label)"
        a.informativeText = "请输入 48 位数字恢复密码（形如 123456-123456-…，连字符可省略）。"
            + "可在 Windows 的 BitLocker 恢复密钥页面或 Microsoft 账户中查询。"
        a.alertStyle = .informational
        a.addButton(withTitle: "解锁")
        a.addButton(withTitle: "取消")

        let access = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 54))
        let field = NSTextField(frame: NSRect(x: 0, y: 28, width: 380, height: 24))
        field.placeholderString = "48 位恢复密码"
        field.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)  // 等宽便于核对数字
        let remember = NSButton(checkboxWithTitle: "记住恢复密码（下次插入自动解锁）", target: nil, action: nil)
        remember.frame = NSRect(x: 0, y: 2, width: 380, height: 20)
        access.addSubview(field)
        access.addSubview(remember)
        a.accessoryView = access

        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let v = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return nil }
        return (v, remember.state == .on)
    }

    /// 选择 Windows 导出的 .BEK 恢复密钥文件；返回文件路径（BEK 只是一份密钥文件，不做记忆）
    private func promptBEKFile(label: String) -> String? {
        let panel = NSOpenPanel()
        panel.title = "选择 .BEK 恢复密钥文件"
        panel.message = "解锁 \(label)：请选择 Windows 导出的 BitLocker 恢复密钥文件（*.BEK）"
        panel.prompt = "选择"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)   // 菜单栏 App 需显式激活，面板才会弹到前台
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }

    @objc private func actionUnlockBL(_ sender: NSMenuItem) {
        guard let d = sender.representedObject as? Disk else { return }
        guard let (pw, remember) = promptBitLockerPassword(label: d.label) else { return }
        if unlockBitLocker(device: d.device, method: .userPassword, credential: pw) {
            if remember { saveCredential(pw, method: .userPassword, for: d) }
            postNotification(title: "BitLocker 已解锁", body: "\(d.label) 已解锁并挂载为读写")
        }
        refresh()
    }

    @objc private func actionUnlockBLRecovery(_ sender: NSMenuItem) {
        guard let d = sender.representedObject as? Disk else { return }
        guard let (rec, remember) = promptBitLockerRecovery(label: d.label) else { return }
        if unlockBitLocker(device: d.device, method: .recoveryPassword, credential: rec) {
            if remember { saveCredential(rec, method: .recoveryPassword, for: d) }
            postNotification(title: "BitLocker 已解锁", body: "\(d.label) 已用恢复密码解锁并挂载为读写")
        }
        refresh()
    }

    @objc private func actionUnlockBLBEK(_ sender: NSMenuItem) {
        guard let d = sender.representedObject as? Disk else { return }
        guard let bek = promptBEKFile(label: d.label) else { return }
        if unlockBitLocker(device: d.device, method: .bekFile, credential: bek) {
            postNotification(title: "BitLocker 已解锁", body: "\(d.label) 已用 .BEK 恢复密钥解锁并挂载为读写")
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
        forgetPassword(for: d)
        alert("已忘记凭据", "已从钥匙串删除 \(d.label) 保存的 BitLocker 凭据。")
        refresh()
    }

    /// 解锁统一入口。密码/恢复密码属敏感信息，先写入 0600 临时文件再以文件参数传入，
    /// 避免出现在进程参数（ps）里；用完立即删除。.BEK 传的是文件路径，直接传参即可。
    private func unlockBitLocker(device: String, method: UnlockMethod, credential: String) -> Bool {
        switch method {
        case .userPassword, .recoveryPassword:
            let tmp = NSTemporaryDirectory() + "ntfsformac-bl-\(UUID().uuidString)"
            do {
                try credential.write(toFile: tmp, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp)
            } catch {
                alert("解锁失败", "无法创建临时凭据文件：\(error.localizedDescription)")
                return false
            }
            defer { try? FileManager.default.removeItem(atPath: tmp) }
            let flag = (method == .userPassword) ? "--password-file" : "--recovery-file"
            return runAdmin(["unlock", device, flag, tmp])
        case .bekFile:
            return runAdmin(["unlock", device, "--bek", credential])
        }
    }

    // MARK: - 钥匙串（BitLocker 凭据记忆）

    /// 该盘在钥匙串里使用的 account 键：优先用 BitLocker 卷 GUID（明文可读、跨插拔稳定），
    /// 无 GUID（旧卷/读不到）时回退设备名。
    /// 用设备名（diskXsY）做键是「记住密码后下次插入不自动解锁」的根因——
    /// 每次插拔盘号都会变（disk4→disk6），键变了自然查不到旧条目。
    private func keychainAccount(for disk: Disk) -> String {
        disk.guid.isEmpty ? disk.device : disk.guid
    }

    /// 记忆格式：把 `<方法码><凭据>` 的 UTF-8 字节整体做十六进制编码后存入钥匙串，
    /// account 键优先用卷 GUID（跨插拔稳定），无 GUID 时回退设备名。
    private func saveCredential(_ credential: String, method: UnlockMethod, for disk: Disk) {
        writeCredential(credential, method: method, account: keychainAccount(for: disk))
        // 顺带清掉可能遗留的「按设备名」旧条目，避免同一凭据存两份
        if !disk.guid.isEmpty { deleteCredential(account: disk.device) }
        // 清掉本会话的「已尝试 / 已确认无凭据」标记，这样用户重新锁定该盘后仍会自动解锁
        let keys = [keychainAccount(for: disk), disk.device]
        for k in keys { autoTried.remove(k); noCredChecked.remove(k) }
        appLog("已保存凭据 disk=\(disk.device) guid=\(disk.guid) method=\(methodCode(method))")
    }

    /// 读取已保存的凭据：先按 GUID 键查，查不到再按设备名查（兼容 v0.0.11 及以前保存的旧条目）
    private func loadCredential(for disk: Disk) -> (UnlockMethod, String)? {
        if let r = readCredential(account: keychainAccount(for: disk)) { return r }
        if !disk.guid.isEmpty, let r = readCredential(account: disk.device) { return r }
        return nil
    }

    /// 忘记凭据：GUID 键与设备名键都删（两种键都可能存在旧条目）
    private func forgetPassword(for disk: Disk) {
        deleteCredential(account: keychainAccount(for: disk))
        if !disk.guid.isEmpty { deleteCredential(account: disk.device) }
    }

    /// 记忆格式：把 `<方法码><凭据>` 的 UTF-8 字节整体做十六进制编码后存入钥匙串。
    /// 为什么必须十六进制编码：macOS 的 `security` 在值含控制字符（如换行）时，
    /// 会把值存成十六进制文本，`find -w` 读出来也是那段十六进制文本。
    /// 旧版用「密码\n方法码」做分隔，于是存进去的其实是 `39393939393939390a75`
    /// ——「记住密码」失效的根因：读回来的不是密码，而是密码的十六进制文本。
    /// 编码成纯可打印十六进制后，无论凭据含什么字节都不会再被 security 二次改写。
    private func encodePayload(_ credential: String, method: UnlockMethod) -> String {
        let payload = Array((methodCode(method) + credential).utf8)
        return payload.map { String(format: "%02x", $0) }.joined()
    }

    /// 解码钥匙串里存的值。兼容三种写法：
    ///   新格式 `<方法码><凭据>`（整体十六进制）—— 本版本写入口径
    ///   旧格式 `<凭据>\n<方法码>`（经 security 二次十六进制）—— v0.0.11 及以前
    ///   最旧格式 纯凭据（无方法码）—— 按用户密码处理
    private func decodePayload(_ s: String) -> (UnlockMethod, String)? {
        let chars = Array(s.lowercased())
        guard chars.count >= 2, chars.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var i = 0
        while i < chars.count {
            guard let b = UInt8(String(chars[i...(i + 1)]), radix: 16) else { return nil }
            bytes.append(b)
            i += 2
        }
        guard let str = String(bytes: bytes, encoding: .utf8), !str.isEmpty else { return nil }
        // 新格式：首字符是方法码
        let head = String(str.first!)
        let tail = String(str.dropFirst())
        switch head {
        case "u": return tail.isEmpty ? nil : (.userPassword, tail)
        case "r": return tail.isEmpty ? nil : (.recoveryPassword, tail)
        case "b": return tail.isEmpty ? nil : (.bekFile, tail)
        default: break
        }
        // 旧格式：最后一个换行之后是方法码
        if let nl = str.lastIndex(of: "\n") {
            let cred = String(str[str.startIndex..<nl])
            switch String(str[str.index(after: nl)...]) {
            case "u": return cred.isEmpty ? nil : (.userPassword, cred)
            case "r": return cred.isEmpty ? nil : (.recoveryPassword, cred)
            case "b": return cred.isEmpty ? nil : (.bekFile, cred)
            default:  break
            }
        }
        return (.userPassword, str)   // 最旧格式：整串即凭据
    }

    private func writeCredential(_ credential: String, method: UnlockMethod, account: String) {
        deleteCredential(account: account)
        run("/usr/bin/security", ["add-generic-password", "-s", keychainService, "-a", account,
                                  "-w", encodePayload(credential, method: method)])
    }

    private func deleteCredential(account: String) {
        run("/usr/bin/security", ["delete-generic-password", "-s", keychainService, "-a", account])
    }

    /// 读取某 account 键的凭据。
    /// 注意：不能对整串做 trimmingCharacters(.whitespacesAndNewlines)——那会连同
    /// security 自己追加的结尾换行一起影响解析；这里只剥掉结尾换行再交给 decodePayload。
    private func readCredential(account: String) -> (UnlockMethod, String)? {
        let (code, out) = runWithStatus("/usr/bin/security",
                                        ["find-generic-password", "-s", keychainService, "-a", account, "-w"])
        guard code == 0 else { return nil }
        var s = out
        while s.hasSuffix("\n") || s.hasSuffix("\r") { s.removeLast() }
        guard !s.isEmpty else { return nil }
        let r = decodePayload(s)
        appLog("readCredential(\(account)) 解析结果=\(r.map { "method=\(methodCode($0.0)) credLen=\($0.1.count)" } ?? "nil")")
        return r
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

    /// 错误/提示窗口（非阻塞、不置顶、文字可选中复制）。
    ///
    /// 为什么不再用 NSAlert + runModal()：
    ///   1. runModal() 会独占事件循环 —— 弹窗期间菜单栏 App 完全卡死，定时器停摆，
    ///      用户必须点掉才能继续用电脑；
    ///   2. NSAlert 的 informativeText 是普通标签，文字**不能选中**，长报错无法复制去搜索；
    ///   3. NSAlert 默认浮在最前并抢占焦点，会挡住正在操作的窗口。
    /// 新实现：NSPanel(.nonactivatingPanel) + 普通窗口层级（level = .normal，不置顶）
    ///         + 可选中 NSTextView + 「复制全部」按钮 + orderFrontRegardless()（显示但不激活 App）。
    private var errorPanels: [String: ErrorPanel] = [:]   // key -> 面板（保活 + 同内容去重）

    private func alert(_ title: String, _ text: String) {
        let key = title + "\u{1}" + text
        // 同一条错误已经开着就不再叠一层（自动解锁失败等场景可能反复触发）
        if errorPanels[key] != nil { return }
        appLog("提示窗口: \(title) | \(text.replacingOccurrences(of: "\n", with: " ⏎ "))")
        let p = ErrorPanel(title: title, text: text)
        errorPanels[key] = p
        p.onClose = { [weak self] in self?.errorPanels.removeValue(forKey: key) }
        p.show()
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

// MARK: - 可复制的非阻塞提示面板

/// 报错/提示面板：文字可选中、带「复制全部」按钮、不置顶、不抢焦点、不阻塞 App。
/// 由 AppDelegate.alert(_:_:) 创建并持有（保活），窗口关闭时通过 onClose 回调释放引用。
final class ErrorPanel: NSObject, NSWindowDelegate {

    /// 窗口关闭时的回调（AppDelegate 用它把自己持有的引用清掉，避免面板泄漏）
    var onClose: (() -> Void)?

    private let panel: NSPanel
    private let body: String
    /// 已弹出过的面板数量（用于错位摆放，避免多个报错窗口完全重叠看不清）
    private static var shown = 0

    init(title: String, text: String) {
        self.body = text

        // .nonactivatingPanel：点击面板不会把 App 变成前台活跃应用（不打断用户当前操作）
        // .utilityWindow：小标题栏，视觉上不与正经文档窗口抢注意力
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 340),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        p.title = title
        p.level = .normal                 // 关键：普通层级 = 不置顶，不会一直压在其它 App 上面
        p.isFloatingPanel = false         // 不随 App 失活而浮到最前
        p.becomesKeyOnlyIfNeeded = true   // 只有用户真要输入/选择时才成为 key window
        p.hidesOnDeactivate = false       // App 失活时不要自动隐藏（否则用户找不到报错）
        p.isReleasedWhenClosed = false    // 交给 ARC 管理，避免关闭后野指针崩溃
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.minSize = NSSize(width: 420, height: 200)
        self.panel = p
        super.init()
        p.delegate = self

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 340))
        p.contentView = content

        // 标题（加粗）
        let titleLbl = NSTextField(labelWithString: title)
        titleLbl.font = NSFont.boldSystemFont(ofSize: 13)
        titleLbl.lineBreakMode = .byTruncatingTail
        titleLbl.maximumNumberOfLines = 1

        // 正文：可选中 + 可滚动的只读文本视图（NSAlert 的 informativeText 做不到选中）
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 220))
        tv.isEditable = false
        tv.isSelectable = true            // 关键：允许选中 → ⌘C 可复制
        tv.isRichText = false
        tv.allowsUndo = false
        tv.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)  // 等宽，路径/设备名好核对
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.autoresizingMask = [.width]
        tv.string = text
        scroll.documentView = tv

        // 提示 + 按钮
        let hint = NSTextField(labelWithString: "可直接选中文字后按 ⌘C 复制")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let copyBtn = NSButton(title: "复制全部", target: self, action: #selector(copyAll(_:)))
        copyBtn.bezelStyle = .rounded
        let closeBtn = NSButton(title: "关闭", target: self, action: #selector(closePanel(_:)))
        closeBtn.bezelStyle = .rounded
        closeBtn.keyEquivalent = "\u{1b}"   // Esc 关闭

        for v in [titleLbl, scroll, hint, copyBtn, closeBtn] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            titleLbl.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            titleLbl.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            titleLbl.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            scroll.topAnchor.constraint(equalTo: titleLbl.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            hint.centerYAnchor.constraint(equalTo: copyBtn.centerYAnchor),

            copyBtn.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            copyBtn.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            copyBtn.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),

            closeBtn.centerYAnchor.constraint(equalTo: copyBtn.centerYAnchor),
            closeBtn.trailingAnchor.constraint(equalTo: copyBtn.leadingAnchor, constant: -10),
        ])

        // 点窗口时第一个响应者是文本视图，方便直接拖选
        p.initialFirstResponder = tv
    }

    /// 显示面板：orderFrontRegardless() 只把窗口提到前面，**不激活 App、不抢键盘焦点**。
    func show() {
        panel.center()
        // 多个报错窗口依次错位，避免完全重叠看不出有几个
        let n = ErrorPanel.shown % 6
        ErrorPanel.shown += 1
        if n > 0 {
            var f = panel.frame
            f.origin.x += CGFloat(n) * 26
            f.origin.y -= CGFloat(n) * 26
            panel.setFrame(f, display: true)
        }
        panel.orderFrontRegardless()
    }

    /// 「复制全部」：整段报错写入剪贴板（选中局部时请用 ⌘C）
    @objc private func copyAll(_ sender: Any?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(body, forType: .string)
        // 按钮短暂变成「已复制」给出反馈（面板不是 key window，不能用声音/焦点提示）
        guard let btn = sender as? NSButton else { return }
        let old = btn.title
        btn.title = "已复制 ✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak btn] in
            btn?.title = old
        }
    }

    @objc private func closePanel(_ sender: Any?) {
        panel.close()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
