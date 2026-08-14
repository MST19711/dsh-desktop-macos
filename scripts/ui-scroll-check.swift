#!/usr/bin/env swift
// 功能验证：加载 dsh Web UI，检查滚动行为。
// 1) 文档（scrollingElement）不可滚动 —— 页面不会跟着弹性滚动
// 2) 存在内部可滚动容器 —— 应用内滚动不受影响
// 3) 截图供像素对比（布局未破坏）
import AppKit
import WebKit

let urlText = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "http://127.0.0.1:50017"
let outShot = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/tmp/ui-check.png"
guard let url = URL(string: urlText) else { fputs("bad url\n", stderr); exit(1) }

let webview = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 860))
var phase = 0
var result = ""

func runJS(_ js: String, _ done: @escaping (String) -> Void) {
    webview.evaluateJavaScript(js) { value, error in
        if let error = error { done("ERR: \(error.localizedDescription)") }
        else if let v = value { done(String(describing: v)) }
        else { done("nil") }
    }
}

webview.load(URLRequest(url: url))
DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
    let js = """
    (() => {
      const se = document.scrollingElement || document.documentElement;
      const docScrollable = se.scrollHeight > se.clientHeight + 1;
      const inner = [...document.querySelectorAll('*')].filter(el => {
        const s = getComputedStyle(el);
        return (s.overflowY === 'auto' || s.overflowY === 'scroll') && el.scrollHeight > el.clientHeight + 1;
      }).length;
      const bodyOverflow = getComputedStyle(document.body).overflow;
      const htmlOverflow = getComputedStyle(document.documentElement).overflow;
      return JSON.stringify({
        docScrollHeight: se.scrollHeight, docClientHeight: se.clientHeight,
        docScrollable, innerScrollContainers: inner,
        bodyOverflow, htmlOverflow,
        title: document.title, hasRoot: !!document.getElementById('root'),
        rootChildren: document.getElementById('root')?.children.length ?? -1
      });
    })()
    """
    runJS(js) { r in
        result = r
        webview.takeSnapshot(with: nil) { image, _ in
            if let image = image, let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: outShot))
            }
            print(result)
            exit(0)
        }
    }
}

while true { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1)) }
