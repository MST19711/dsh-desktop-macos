#!/bin/bash
# 自动验证构建产物：
#   1. 启动 dist/DSH Desktop.app
#   2. 等待日志出现就绪 URL，curl 校验页面（__DSH_BOOT__）
#   3. 确认 node 服务器子进程存在
#   4. 退出应用，确认子进程被清理、端口不再监听
#   5. codesign --verify
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/DSH Desktop.app"
LOG="$HOME/Library/Logs/DSHDesktop/desktop.log"

[ -d "$APP" ] || { echo "错误：$APP 不存在，先运行 build.sh" >&2; exit 1; }

echo "==== [0] 清理残留实例 ===="
# 先退出已运行的实例，避免单实例机制干扰；同时清理历史遗留的孤儿 node 子进程
# （例如应用被 SIGTERM 强杀时无法执行清理逻辑）。
osascript -e 'quit app "DSH Desktop"' >/dev/null 2>&1 || true
sleep 2
for pid in $(pgrep -f 'bin.js web --host 127.0.0.1 --port 0' || true); do
  if ps -p "$pid" -o command= 2>/dev/null | grep -q "$APP"; then
    kill "$pid" 2>/dev/null || true
  fi
done
sleep 1

echo "==== [1] codesign 校验 ===="
codesign --verify --deep --strict "$APP" && echo "codesign OK"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature|TeamIdentifier" | head -4 || true

echo "==== [2] 启动应用 ===="
rm -f "$LOG"
open "$APP"
echo "等待服务器就绪（最多 90 秒）..."
URL=""
for i in $(seq 1 90); do
  if [ -f "$LOG" ]; then
    # 注意：日志可能只写了 "spawning" 尚未写就绪行，grep 无匹配返回 1，
    # 在 set -e 下会杀死脚本，因此末尾加 || true。
    URL="$(grep -o 'server ready: http://127\.0\.0\.1:[0-9]*' "$LOG" 2>/dev/null | awk '{print $3}' | head -1 || true)"
    [ -n "$URL" ] && break
  fi
  sleep 1
done
[ -n "$URL" ] || { echo "错误：未在日志中看到就绪行"; [ -f "$LOG" ] && tail -20 "$LOG"; exit 1; }
echo "就绪 URL: $URL"

echo "==== [3] 页面校验 ===="
for i in $(seq 1 10); do
  BODY="$(curl -s -m 5 "$URL/")" && break
  sleep 1
done
echo "$BODY" | grep -q "__DSH_BOOT__" && echo "页面 OK（含 __DSH_BOOT__ 引导清单，$(echo "$BODY" | wc -c | tr -d ' ') 字节）" \
  || { echo "错误：页面未包含 __DSH_BOOT__"; exit 1; }

echo "==== [4] 服务器子进程 ===="
NODE_PID="$(pgrep -f 'node_modules/@deepseek-ai/dsh/lib/bin.js' | head -1)"
[ -n "$NODE_PID" ] && echo "node 子进程 PID=$NODE_PID" || { echo "错误：未找到 node 子进程"; exit 1; }

echo "==== [5] 退出应用并检查清理 ===="
osascript -e 'quit app "DSH Desktop"' || killall "DSH Desktop" 2>/dev/null || true
for i in $(seq 1 15); do
  if ! pgrep -f 'DSH Desktop.app/Contents/MacOS' >/dev/null; then break; fi
  sleep 1
done
sleep 2
if pgrep -f 'node_modules/@deepseek-ai/dsh/lib/bin.js' >/dev/null; then
  echo "错误：退出后仍有 node 孤儿进程"; exit 1
fi
echo "退出后无孤儿 node 进程"
if curl -s -m 2 -o /dev/null "$URL/"; then
  echo "警告：端口仍在监听"
else
  echo "端口已释放"
fi
grep -q "server child exited" "$LOG" && echo "日志确认：server child exited" || echo "（日志未见 child exited 标记）"

echo ""
echo "==== 验证通过 ===="
tail -6 "$LOG"
