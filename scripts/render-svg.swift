#!/usr/bin/env swift
// 用 WKWebView 把 SVG 渲染为 1024x1024 PNG（完整 WebKit SVG 支持）。
// 用法: swift render-svg.swift <input.svg> <output.png>
import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count >= 3 else {
    fputs("usage: render-svg.swift <input.svg> <output.png>\n", stderr)
    exit(1)
}
let svgText = try! String(contentsOfFile: args[1], encoding: .utf8)
let outPath = args[2]

let html = """
<!doctype html><html><head><meta charset="utf-8"><style>
html,body{margin:0;padding:0;background:transparent;width:1024px;height:1024px}
</style></head><body>\(svgText)</body></html>
"""

let webview = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 1024))
webview.setValue(false, forKey: "drawsBackground")

var finished = false
var result: NSImage?

webview.loadHTMLString(html, baseURL: nil)
DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
    webview.takeSnapshot(with: nil) { image, _ in
        result = image
        finished = true
    }
}

while !finished {
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
}

guard let image = result,
      let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("error: 渲染失败\n", stderr)
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("written: \(outPath) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
