# DeepSeek Harness 桌面版（macOS）

把 [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) 的 Web GUI 打包成
自包含的 macOS 桌面 App：内嵌 Node.js 运行时 + 官方 `@deepseek-ai/dsh` npm 负载，
用 [Tauri v2](https://v2.tauri.app)（系统 WebKit）做窗口外壳。

```
DeepSeek Harness.app/
  Contents/MacOS/DeepSeek Harness          # Rust 主程序
  Contents/MacOS/node                      # Node.js 24 LTS（externalBin sidecar）
  Contents/Resources/_up_/server/          # dsh 服务器负载（node_modules + 前端 dist）
  Contents/Resources/ui/                   # 启动 splash 页
```

运行流程：启动 → 显示 splash → 派生 `node <server>/node_modules/@deepseek-ai/dsh/lib/bin.js web
--host 127.0.0.1 --port 0`（cwd=用户主目录）→ 从 stdout 的 `dsh web: http://127.0.0.1:<port>`
就绪行拿到端口 → 窗口导航到该地址 → 退出时 SIGTERM（3 秒宽限）→ SIGKILL 清理子进程。

## 构建

```sh
./build.sh
```

产物：`dist/DeepSeek Harness.app` 与 `dist/DeepSeek Harness.dmg`。

- 需要网络：npm registry、crates.io、nodejs.org；首次构建会编译约 400 个 Rust crate（5–15 分钟）。
- 只支持当前架构（Apple Silicon arm64；Intel 机器运行脚本会自动下载 x64 Node）。
- 签名：ad-hoc（`signingIdentity: "-"`），本机运行无需开发者账号；未做公证。
- 版本：`DSH_VERSION`（默认 `0.1.0-rc.6`）与 `NODE_MAJOR`（默认 `24`）可用环境变量覆盖后重新构建以升级。

## 开发调试

```sh
cd desktop
npm install          # @tauri-apps/cli
npx tauri dev        # debug 构建：使用 PATH 中的 node + 仓库 server/ 负载
```

debug 模式可用 `DSH_DESKTOP_NODE=/path/to/node npx tauri dev` 指定 Node。

## 运行与数据

- 首次打开：窗口会显示 splash 直到服务器就绪（通常 2–5 秒），之后自动加载 Web UI。
- 服务器日志：`~/Library/Logs/DeepSeekHarness/desktop.log`（含就绪 URL 与服务器输出）。
- 用户数据：沿用 harness 惯例存于 `~/.dsh`（与命令行 `dsh` 共享；可用 `DSH_HOME` 覆盖）。
- 使用：在 Web UI 中 **Settings → Models** 配置 API Key，然后 **选择工作目录** 即可开始对话。
- 单实例：重复打开会聚焦已有窗口。
- 菜单：重新加载（⌘R）、在浏览器中打开、退出（⌘Q）。

## 目录结构

```
build.sh              一键构建（fetch node/payload → prune → icon → tauri build）
scripts/fetch-node.sh     下载官方 Node 24 LTS → src-tauri/binaries/node-<triple>
scripts/fetch-payload.sh  npm install @deepseek-ai/dsh → server/
scripts/prune-payload.sh  删除非 darwin-arm64 预编译物（省 ~60MB）
scripts/make-icon.sh      生成应用图标（Swift 绘制 + tauri icon）
ui/                    splash 页面（frontendDist）
server/                服务器负载（构建生成，gitignored）
desktop/               Tauri 应用（src-tauri：Rust 外壳；package.json：tauri CLI）
dist/                  构建产物（gitignored）
```

## 故障排查

- 启动超时/报错对话框 → 查看 `~/Library/Logs/DeepSeekHarness/desktop.log`。
- 重新构建前如负载损坏：`rm -rf server desktop/src-tauri/binaries && ./build.sh`。
- 网络受限环境：需先在有网机器上完成 `./build.sh`，或预置 `server/` 与 `binaries/node-*`。
