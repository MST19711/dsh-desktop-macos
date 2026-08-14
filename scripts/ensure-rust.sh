#!/bin/bash
# 确保项目使用 >=1.86 的 Rust 工具链（当前 tauri 依赖树需要）。
# 工具链装在 .rustup-home / .cargo-home（gitignored），不改动系统全局设置。
# 若系统 cargo 已满足版本要求则直接复用。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export RUSTUP_HOME="$ROOT/.rustup-home"
export CARGO_HOME="$ROOT/.cargo-home"

MIN_RUSTC="1.86.0"

version_ge() { # $1 >= $2
  printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

# 1) 项目自带工具链
if [ -x "$CARGO_HOME/bin/cargo" ]; then
  export PATH="$CARGO_HOME/bin:$PATH"
  echo "==> 使用项目工具链: $("$CARGO_HOME/bin/rustc" --version)"
  exit 0
fi

# 2) 系统工具链（版本足够）
if command -v cargo >/dev/null 2>&1; then
  SYS_VER="$(rustc --version 2>/dev/null | awk '{print $2}')"
  if [ -n "$SYS_VER" ] && version_ge "$SYS_VER" "$MIN_RUSTC"; then
    echo "==> 使用系统工具链: rustc $SYS_VER"
    exit 0
  fi
  echo "==> 系统 rustc $SYS_VER 过旧（需要 >= $MIN_RUSTC），将安装项目专用工具链"
else
  echo "==> 未找到 cargo，将安装项目专用工具链"
fi

# 3) 安装 rustup + stable 到项目目录
ARCH="$(uname -m)"
curl -sfL -o /tmp/rustup-init "https://static.rust-lang.org/rustup/dist/${ARCH}-apple-darwin/rustup-init"
chmod +x /tmp/rustup-init
RUSTUP_HOME="$RUSTUP_HOME" CARGO_HOME="$CARGO_HOME" \
  /tmp/rustup-init -y --no-modify-path --profile minimal --default-toolchain stable
export PATH="$CARGO_HOME/bin:$PATH"
echo "==> 安装完成: $("$CARGO_HOME/bin/rustc" --version)"
