#!/bin/bash
# 生成应用图标：Swift 绘制 1024x1024 源 PNG → `tauri icon` 生成全套图标（icns/ico/png）。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> 绘制源图标 (1024x1024)"
mkdir -p /tmp/swift-modcache /tmp/clang-modcache
CLANG_MODULE_CACHE_PATH=/tmp/clang-modcache \
SWIFT_MODULE_CACHE_PATH=/tmp/swift-modcache \
  swift "$ROOT/scripts/make-icon.swift" "$ROOT/app-icon.png"

echo "==> tauri icon 生成全套图标"
(
  cd "$ROOT/desktop"
  if [ ! -d node_modules ]; then
    npm install --cache "$ROOT/.npm-cache" --no-audit --no-fund
  fi
  npx tauri icon "$ROOT/app-icon.png"
)

echo "==> 图标完成"
