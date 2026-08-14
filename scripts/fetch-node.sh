#!/bin/bash
# 下载官方 Node.js v24 LTS 二进制，放到 src-tauri/binaries/，
# 作为 Tauri sidecar（externalBin）随 .app 一起打包。
# 文件名必须带目标三元组后缀（tauri-bundler 会去掉后缀后放入 Contents/MacOS/）。
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
mkdir -p "$(dirname "$DEST")"

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

echo "==> 解出 bin/node"
rm -rf "/tmp/node-extract-${VERSION}"
mkdir -p "/tmp/node-extract-${VERSION}"
tar -xzf "/tmp/${TARBALL}" -C "/tmp/node-extract-${VERSION}"
cp "/tmp/node-extract-${VERSION}/node-v${VERSION}-${NODE_ARCH}/bin/node" "$DEST"
chmod +x "$DEST"

echo "==> 验证: $("$DEST" --version) ($(du -h "$DEST" | cut -f1))"
