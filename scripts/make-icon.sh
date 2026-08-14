#!/bin/bash
# 生成应用图标：官方 DeepSeek 鲸鱼 logo（黑色）渲染为 1024x1024 源 PNG
# → `tauri icon` 生成全套图标（icns/ico/png）。
# 素材：scripts/deepseek-whale.svg（官方 favicon 路径，去掉了深色模式反色 style），
# 合成：scripts/deepseek-whale-icon.svg（白色圆角底 + 黑色鲸鱼）。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> 渲染源图标 (1024x1024, WKWebView)"
mkdir -p /tmp/swift-modcache /tmp/clang-modcache
CLANG_MODULE_CACHE_PATH=/tmp/clang-modcache \
SWIFT_MODULE_CACHE_PATH=/tmp/swift-modcache \
  swift "$ROOT/scripts/render-svg.swift" \
    "$ROOT/scripts/deepseek-whale-icon.svg" "$ROOT/app-icon.png"
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

echo "==> 图标完成"
