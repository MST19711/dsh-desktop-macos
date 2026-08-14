#!/bin/bash
# 安装 @deepseek-ai/dsh（官方 npm 包，即 `npx @deepseek-ai/dsh web` 的负载）到
# desktop/src-tauri/server/（bundle.resources 的 "server/**" 以 src-tauri 为基准解析）。
# 使用工作区内的独立 npm 缓存（~/.npm 存在 root 属主权限问题）。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DSH_VERSION="${DSH_VERSION:-0.1.0-rc.6}"
SERVER_DIR="$ROOT/desktop/src-tauri/server"

mkdir -p "$SERVER_DIR"
cd "$SERVER_DIR"

if [ ! -f package.json ]; then
  echo '{"name":"dsh-desktop-server","private":true,"version":"0.0.0"}' > package.json
fi

echo "==> npm install @deepseek-ai/dsh@${DSH_VERSION} (--omit=dev, 独立缓存 .npm-cache)"
npm install --cache "$ROOT/.npm-cache" --omit=dev --no-audit --no-fund \
  "@deepseek-ai/dsh@${DSH_VERSION}"

echo "==> 安装完成: $(du -sh node_modules | cut -f1)"
