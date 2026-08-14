#!/usr/bin/env swift
// 绘制 DeepSeek Harness 应用图标源图（1024x1024 PNG）：
// 深蓝渐变圆角方块 + 白色 "DSH" 字样。
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// 圆角矩形路径
let rect = NSRect(x: 0, y: 0, width: size, height: size)
let radius: CGFloat = 224
let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

// 深蓝渐变（DeepSeek 蓝）
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.36, green: 0.46, blue: 1.00, alpha: 1.0),
    NSColor(calibratedRed: 0.22, green: 0.30, blue: 0.80, alpha: 1.0),
])!
gradient.draw(in: path, angle: -60)

// 白色 "DSH" 字样
let text = "DSH" as NSString
let font = NSFont.systemFont(ofSize: 380, weight: .bold)
let attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor.white,
]
let textSize = text.size(withAttributes: attrs)
let textRect = NSRect(
    x: (size - textSize.width) / 2,
    y: (size - textSize.height) / 2,
    width: textSize.width,
    height: textSize.height
)
text.draw(in: textRect, withAttributes: attrs)

image.unlockFocus()

// 写 PNG
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("error: 无法生成 PNG\n", stderr)
    exit(1)
}
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "app-icon.png"
try! png.write(to: URL(fileURLWithPath: out))
print("written: \(out)")
