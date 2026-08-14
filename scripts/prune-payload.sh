#!/bin/bash
# 精简 desktop/src-tauri/server/node_modules：只保留 darwin-arm64 的原生预编译物。
# 保守清单：仅删除其他平台的预编译二进制，不触碰任何功能代码。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NM="$ROOT/desktop/src-tauri/server/node_modules"

[ -d "$NM" ] || { echo "desktop/src-tauri/server/node_modules 不存在，先运行 fetch-payload.sh"; exit 1; }

REMOVED=0

# node-pty：只留 darwin-arm64 prebuilds
if [ -d "$NM/node-pty/prebuilds" ]; then
  for d in "$NM"/node-pty/prebuilds/*/; do
    case "$(basename "$d")" in
      darwin-arm64) ;;
      *) rm -rf "$d"; REMOVED=$((REMOVED+1)) ;;
    esac
  done
fi

# @img/sharp-*：只留 darwin-arm64 相关包（sharp 本体 + libvips 运行库，两者都必需）
for d in "$NM"/@img/sharp-*/; do
  case "$(basename "$d")" in
    sharp-darwin-arm64|sharp-libvips-darwin-arm64) ;;
    *) rm -rf "$d"; REMOVED=$((REMOVED+1)) ;;
  esac
done

echo "==> 清理完成（删除 $REMOVED 项目），负载: $(du -sh "$NM" | cut -f1)"
