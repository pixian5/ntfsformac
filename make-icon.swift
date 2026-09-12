// make-icon.swift — 生成 NTFSFormac 图标（1024x1024 PNG）
// 用法: swift make-icon.swift <输出路径.png>
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let size = NSSize(width: 1024, height: 1024)

let image = NSImage(size: size)
image.lockFocus()

// 圆角渐变背景（蓝→深蓝）
let rect = NSRect(origin: .zero, size: size)
let path = NSBezierPath(roundedRect: rect.insetBy(dx: 48, dy: 48), xRadius: 180, yRadius: 180)
if let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.13, green: 0.47, blue: 0.92, alpha: 1),
    NSColor(calibratedRed: 0.10, green: 0.22, blue: 0.58, alpha: 1),
]) {
    gradient.draw(in: path, angle: -70)
}

// 硬盘示意（白色圆角条）
let barRect = NSRect(x: 212, y: 148, width: 600, height: 150)
NSColor(calibratedWhite: 1.0, alpha: 0.92).setFill()
NSBezierPath(roundedRect: barRect, xRadius: 40, yRadius: 40).fill()
// 硬盘凹槽
NSColor(calibratedWhite: 0.2, alpha: 0.35).setFill()
NSBezierPath(roundedRect: NSRect(x: 268, y: 200, width: 488, height: 46), xRadius: 23, yRadius: 23).fill()

// NTFS 文字
let text = "NTFS"
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 230, weight: .bold),
    .foregroundColor: NSColor.white,
]
let str = NSAttributedString(string: text, attributes: attrs)
let ts = str.size()
str.draw(at: NSPoint(x: (1024 - ts.width) / 2, y: (1024 - ts.height) / 2 - 60))

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("生成图标失败\n", stderr)
    exit(1)
}
try? png.write(to: URL(fileURLWithPath: outPath))
print("icon written: \(outPath)")
