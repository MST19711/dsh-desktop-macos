#!/bin/bash
# 一键构建 DeepSeek Harness macOS 桌面 App。
#
# 产物：
#   dist/DeepSeek Harness.app
#   dist/DeepSeek Harness.dmg
#
# 依赖网络：npm registry、crates.io、nodejs.org（首次构建还需编译约 400 个 Rust crate）。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# 可调版本（升级 dsh 只需改这里重新运行本脚本）
export DSH_VERSION="${DSH_VERSION:-0.1.0-rc.6}"
export NODE_MAJOR="${NODE_MAJOR:-24}"

echo "==== [1/5] Node 运行时 ===="
bash scripts/fetch-node.sh

echo "==== [2/5] dsh 服务器负载 ===="
bash scripts/fetch-payload.sh

echo "==== [3/5] 精简负载 ===="
bash scripts/prune-payload.sh

echo "==== [4/5] 图标 ===="
bash scripts/make-icon.sh

echo "==== [5/5] Tauri 构建 (app + dmg) ===="
cd desktop
npx tauri build --bundles app,dmg

echo "==== 拷贝产物到 dist/ ===="
mkdir -p "$ROOT/dist"
rm -rf "$ROOT/dist/DeepSeek Harness.app" "$ROOT/dist/DeepSeek Harness.dmg"
cp -R src-tauri/target/release/bundle/macos/"DeepSeek Harness.app" "$ROOT/dist/"
cp src-tauri/target/release/bundle/dmg/"DeepSeek Harness.dmg" "$ROOT/dist/"

echo ""
echo "构建完成："
echo "  $ROOT/dist/DeepSeek Harness.app"
echo "  $ROOT/dist/DeepSeek Harness.dmg"
echo "运行：open \"$ROOT/dist/DeepSeek Harness.app\""
