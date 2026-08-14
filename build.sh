#!/bin/bash
# 一键构建 DeepSeek Harness macOS 桌面 App。
#
# 产物：
#   dist/DeepSeek Harness.app
#   dist/DeepSeek Harness.dmg
#
# 依赖网络：npm registry、crates.io（可用镜像，见 src-tauri/.cargo/config.toml）、
# nodejs.org、static.rust-lang.org（首次构建还需编译约 400 个 Rust crate）。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# 可调版本（升级 dsh 只需改这里重新运行本脚本）
export DSH_VERSION="${DSH_VERSION:-0.1.0-rc.6}"
export NODE_MAJOR="${NODE_MAJOR:-24}"

echo "==== [0/6] Rust 工具链 ===="
source scripts/ensure-rust.sh

echo "==== [1/6] Node 运行时 ===="
bash scripts/fetch-node.sh

echo "==== [2/6] dsh 服务器负载 ===="
bash scripts/fetch-payload.sh

echo "==== [3/6] 精简负载 ===="
bash scripts/prune-payload.sh

echo "==== [4/6] 图标 ===="
bash scripts/make-icon.sh

echo "==== [5/6] Tauri 构建 (app + dmg) ===="
cd desktop
if [ ! -d node_modules ]; then
  npm install --cache "$ROOT/.npm-cache" --no-audit --no-fund
fi
# tauri-codegen 不跟踪 ui/ 目录文件（frontendDist 资产嵌入不触发重编译），
# 检测到 ui/ 比已构建二进制新时，强制 touch lib.rs 触发重新嵌入。
if [ "ui/index.html" -nt "src-tauri/target/release/dsh-desktop" ]; then
  touch src-tauri/src/lib.rs
  echo "==> ui/ 有变更，强制重编译以重新嵌入 splash 资产"
fi
npx tauri build --bundles app,dmg

echo "==== [6/6] 修正签名 + 拷贝产物到 dist/ ===="
# tauri 默认以 hardened runtime 签名 sidecar，会阻止 Node/V8 在 Apple Silicon 上
# 申请 JIT 内存（"Failed to reserve virtual memory for CodeRange"）。
# 修正：node sidecar 改为普通 ad-hoc 签名（不带 runtime），再重签整个 app 使封缄有效。
APP_BUNDLE="src-tauri/target/release/bundle/macos/DeepSeek Harness.app"
codesign --force --sign - --preserve-metadata=identifier \
  "$APP_BUNDLE/Contents/MacOS/node"
codesign --force --sign - --options runtime --preserve-metadata=identifier,entitlements \
  "$APP_BUNDLE"

mkdir -p "$ROOT/dist"
rm -rf "$ROOT/dist/DeepSeek Harness.app" "$ROOT/dist/DeepSeek Harness.dmg"
cp -R "$APP_BUNDLE" "$ROOT/dist/"
cp src-tauri/target/release/bundle/dmg/"DeepSeek Harness_0.1.0_aarch64.dmg" "$ROOT/dist/DeepSeek Harness.dmg"
codesign --verify --deep --strict "$ROOT/dist/DeepSeek Harness.app" && echo "codesign 校验通过"

echo ""
echo "构建完成："
echo "  $ROOT/dist/DeepSeek Harness.app"
echo "  $ROOT/dist/DeepSeek Harness.dmg"
echo "运行：open \"$ROOT/dist/DeepSeek Harness.app\""
