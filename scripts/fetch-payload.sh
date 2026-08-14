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

# ── 桌面端补丁 ─────────────────────────────────────────────────────────────
# 禁用页面级弹性滚动（WKWebView 橡皮筋效应）：根文档不可滚动，
# 滚动只发生在应用内部容器（面板式布局，#root 为 100% 高度）。
# 幂等：标记注释存在即跳过。
PATCH_MARK="dsh-desktop: 禁用页面级弹性滚动"
INDEX_CSS="$(ls node_modules/@deepseek-ai/dsh-web-frontend/dist/assets/index-*.css 2>/dev/null | head -1)"
if [ -n "$INDEX_CSS" ] && ! grep -q "$PATCH_MARK" "$INDEX_CSS"; then
  printf '\n/* %s */\nhtml,body{height:100%%;overflow:hidden;overscroll-behavior:none}\n' "$PATCH_MARK" >> "$INDEX_CSS"
  echo "==> 已注入滚动补丁: $INDEX_CSS"
else
  echo "==> 滚动补丁已存在（幂等跳过）"
fi
