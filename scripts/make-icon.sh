#!/bin/bash
# 生成应用图标：macOS 窗口风格图标（scripts/deepseek-window-icon.svg）
# 渲染为 1024x1024 源 PNG → `tauri icon` 生成全套图标（icns/ico/png）。
# 素材：scripts/deepseek-window-icon.svg（窗口 + 右下角鲸鱼徽章）。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> 渲染源图标 (1024x1024, WKWebView)"
mkdir -p /tmp/swift-modcache /tmp/clang-modcache
CLANG_MODULE_CACHE_PATH=/tmp/clang-modcache \
SWIFT_MODULE_CACHE_PATH=/tmp/swift-modcache \
  swift "$ROOT/scripts/render-svg.swift" \
    "$ROOT/scripts/deepseek-window-icon.svg" "$ROOT/app-icon.png"
# WKWebView takeSnapshot 输出为 2x，缩放到 1024
sips -z 1024 1024 "$ROOT/app-icon.png" --out "$ROOT/app-icon.png" >/dev/null
sips -g pixelWidth -g pixelHeight "$ROOT/app-icon.png" | tail -2

echo "==> tauri icon 生成全套图标"
(
  cd "$ROOT/desktop"
  if [ ! -d node_modules ]; then
    npm install --cache "$ROOT/.npm-cache" --no-audit --no-fund
  fi
  npx tauri icon "$ROOT/app-icon.png"
)

echo "==> 托盘图标 (menu bar template, 透明底黑鲸鱼)"
CLANG_MODULE_CACHE_PATH=/tmp/clang-modcache \
SWIFT_MODULE_CACHE_PATH=/tmp/swift-modcache \
  swift "$ROOT/scripts/render-svg.swift" \
    "$ROOT/scripts/dsh-tray.svg" "$ROOT/desktop/src-tauri/icons/tray.png"
sips -z 128 128 "$ROOT/desktop/src-tauri/icons/tray.png" --out "$ROOT/desktop/src-tauri/icons/tray.png" >/dev/null

echo "==> 图标完成"
