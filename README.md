# DeepSeek Harness 桌面版（macOS）

> **⚠️ 非官方项目（Unofficial）**
>
> 本项目是社区第三方项目，**不是 DeepSeek（深度求索）官方发布**，与 DeepSeek 及其关联公司
> 无任何隶属、合作或背书关系。本项目仅将官方开源项目
> [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) 的 Web UI
> （官方 npm 包 `@deepseek-ai/dsh`）封装为 macOS 桌面应用。
>
> **This is an unofficial, community project. It is not affiliated with, endorsed by, or
> sponsored by DeepSeek. It merely packages the official open-source project
> [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) into a
> macOS desktop app.**
>
> 关于 dsh 本身的功能、缺陷与安全问题，请反馈至上游官方仓库；本仓库只负责桌面封装层。
> DeepSeek、DeepSeek Harness 及相关标志均为其各自所有者的商标或财产。

把 [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) 的 Web GUI 打包成
自包含的 macOS 桌面 App：内嵌 Node.js 运行时 + 官方 `@deepseek-ai/dsh` npm 负载，
用 [Tauri v2](https://v2.tauri.app)（系统 WebKit）做窗口外壳。

```
DeepSeek Harness.app/
  Contents/MacOS/DeepSeek Harness          # Rust 主程序
  Contents/MacOS/node                      # Node.js 24 LTS（externalBin sidecar）
  Contents/Resources/server/              # dsh 服务器负载（node_modules + 前端 dist）
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
  构建脚本还会把 node sidecar 改为不带 hardened runtime 的 ad-hoc 签名（否则
  Apple Silicon 上 V8 无法申请 JIT 内存，服务器会以 CodeRange OOM 崩溃）。
- 版本：`DSH_VERSION`（默认 `0.1.0-rc.6`）与 `NODE_MAJOR`（默认 `24`）可用环境变量覆盖后重新构建以升级。
  内置负载只是「出厂版本」；运行时另有自动更新机制（见下文「自动更新」），
  日常升级通常无需重新构建 App。

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
- 单实例：重复打开会恢复并聚焦已有窗口。
- 生命周期：**关闭窗口只隐藏窗口**，服务器继续在后台运行（菜单栏出现鲸鱼托盘图标）；
  真正退出：点击托盘图标 → 退出，或菜单栏 ⌘Q / Dock 右键退出。点击托盘图标（左键）
  或 Dock 图标可重新显示主窗口。
- 菜单：重新加载（⌘R）、在浏览器中打开、退出（⌘Q）。

## 自动更新

App 启动时会在后台检查 npm 上 `@deepseek-ai/dsh` 的最新版本（内置 node + 随包分发的
npm CLI，节流 6 小时一次）：

1. 有新版 → 安装到应用数据目录 `~/Library/Application Support/com.deepseek-ai.dsh-desktop/server.new`
   （暂存目录，校验 `bin.js` 存在后原子替换为 `server/`）。
2. 本次运行仍使用旧负载，**下次启动生效**：优先加载更新版负载，损坏/缺失时自动回退内置负载。
3. 更新只写应用数据目录，不改 `.app` 包内资源，不破坏代码签名；失败（离线/超时/校验失败）
   仅记入日志，不影响正常启动。

控制环境变量：

| 变量 | 作用 |
| --- | --- |
| `DSH_DESKTOP_AUTOUPDATE=0` | 关闭自动更新 |
| `DSH_DESKTOP_FORCE_UPDATE=1` | 忽略版本比较与 6 小时节流，强制重装（测试用） |
| `npm_config_registry=...` | npm 镜像/本地源（npm 标准变量，透传给更新器） |

回退内置负载：删除 `~/Library/Application Support/com.deepseek-ai.dsh-desktop/server` 目录即可。
日志：`~/Library/Logs/DeepSeekHarness/desktop.log` 中以 `auto-update:` 前缀记录每次检查与安装结果。

## 目录结构

```
build.sh              一键构建（fetch node/payload → prune → icon → tauri build）
scripts/fetch-node.sh     下载官方 Node 24 LTS 与随附 npm CLI → binaries/ 与 src-tauri/npm/
scripts/fetch-payload.sh  npm install @deepseek-ai/dsh → desktop/src-tauri/server/
scripts/prune-payload.sh  删除非 darwin-arm64 预编译物（省 ~60MB）
scripts/make-icon.sh      生成应用图标（Swift 绘制 + tauri icon）
scripts/verify-app.sh     构建产物自动验证（启动/就绪/子进程/清理/codesign）
ui/                    splash 页面（frontendDist）
desktop/src-tauri/server/  服务器负载（构建生成，gitignored）
desktop/src-tauri/npm/     随附 npm CLI（构建生成，gitignored，供自动更新使用）
desktop/               Tauri 应用（src-tauri：Rust 外壳；package.json：tauri CLI）
dist/                  构建产物（gitignored）
```

## 故障排查

- 启动超时/报错对话框 → 查看 `~/Library/Logs/DeepSeekHarness/desktop.log`。
- 自动更新异常（一直用旧版/回退内置版）→ 查看日志中 `auto-update:` 行；
  清理 `~/Library/Application Support/com.deepseek-ai.dsh-desktop/server` 可重置为内置负载。
- 重新构建前如负载损坏：`rm -rf desktop/src-tauri/server desktop/src-tauri/binaries && ./build.sh`。
- crates.io 直连 TLS 失败时使用 rsproxy 镜像（见 `desktop/src-tauri/.cargo/config.toml`），
  可自行换成其他镜像源。
- 网络受限环境：需先在有网机器上完成 `./build.sh`，或预置 `server/` 与 `binaries/node-*`。
