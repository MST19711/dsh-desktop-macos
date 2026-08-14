#!/bin/bash
# 下载官方 Node.js v24 LTS 二进制与随附的 npm CLI：
# - bin/node → src-tauri/binaries/node-<triple>（Tauri externalBin sidecar，
#   文件名带目标三元组后缀，打包时放入 Contents/MacOS/node）
# - lib/node_modules/npm → src-tauri/npm/（随包分发，供运行时自动更新使用）
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_MAJOR="${NODE_MAJOR:-24}"

ARCH="$(uname -m)"
case "$ARCH" in
  arm64) TRIPLE="aarch64-apple-darwin" ;;
  x86_64) TRIPLE="x86_64-apple-darwin" ;;
  *) echo "错误：不支持的架构 $ARCH" >&2; exit 1 ;;
esac

DEST="$ROOT/desktop/src-tauri/binaries/node-${TRIPLE}"
NPM_DEST="$ROOT/desktop/src-tauri/npm"
mkdir -p "$(dirname "$DEST")"

if [ -x "$DEST" ] && "$DEST" --version >/dev/null 2>&1 && [ -f "$NPM_DEST/bin/npm-cli.js" ]; then
  echo "==> node 与 npm 已存在: $("$DEST" --version)，跳过下载"
  exit 0
fi

echo "==> 查询 nodejs.org 最新 v${NODE_MAJOR} LTS 版本..."
VERSION="$(curl -fsSL https://nodejs.org/dist/index.json | \
  python3 -c "
import json,sys
releases=json.load(sys.stdin)
major=int('$NODE_MAJOR')
for r in releases:
    v=r['version'][1:]
    if v.startswith(f'{major}.') and r.get('lts'):
        print(v); break
")"
if [ -z "${VERSION:-}" ]; then
  echo "错误：未找到 v${NODE_MAJOR} LTS 版本" >&2
  exit 1
fi
echo "==> 使用 Node ${VERSION}"

case "$ARCH" in
  arm64) NODE_ARCH="darwin-arm64" ;;
  x86_64) NODE_ARCH="darwin-x64" ;;
esac

TARBALL="node-v${VERSION}-${NODE_ARCH}.tar.gz"
URL="https://nodejs.org/dist/v${VERSION}/${TARBALL}"
echo "==> 下载 $URL"
curl -fL --retry 3 -o "/tmp/${TARBALL}" "$URL"

echo "==> 解出 bin/node 与 npm CLI"
rm -rf "/tmp/node-extract-${VERSION}"
mkdir -p "/tmp/node-extract-${VERSION}"
tar -xzf "/tmp/${TARBALL}" -C "/tmp/node-extract-${VERSION}"
EXTRACT="/tmp/node-extract-${VERSION}/node-v${VERSION}-${NODE_ARCH}"
cp "$EXTRACT/bin/node" "$DEST"
chmod +x "$DEST"
rm -rf "$NPM_DEST"
cp -R "$EXTRACT/lib/node_modules/npm" "$NPM_DEST"

echo "==> 验证: $("$DEST" --version) ($(du -h "$DEST" | cut -f1)), npm CLI $(du -sh "$NPM_DEST" | cut -f1)"
"$DEST" "$NPM_DEST/bin/npm-cli.js" --version 2>/dev/null | tail -1 | xargs echo "   npm"
