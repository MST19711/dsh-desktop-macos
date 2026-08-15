//! 服务器负载自动更新。
//!
//! 原理：这个 App 本质是「Rust 外壳 + npm 包 @deepseek-ai/dsh 负载」。
//! 启动时在后台检查 npm 上该包的最新版本，若有新版则安装到应用数据目录
//! （`~/Library/Application Support/com.dshdesktop.app/server`），
//! 不修改 .app 包内资源（避免破坏代码签名）；下次启动优先使用更新后的负载，
//! 校验失败自动回退到内置负载。
//!
//! 控制：
//! - `DSH_DESKTOP_AUTOUPDATE=0` 关闭自动更新
//! - `DSH_DESKTOP_FORCE_UPDATE=1` 忽略版本比较与节流，强制重装（测试用）
//! - `npm_config_registry` 可指向镜像/本地源（npm 标准环境变量）

use std::cmp::Ordering;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Command as StdCommand, Stdio};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use tauri::{AppHandle, Manager};

use crate::log_line;

/// 更新检查节流：距上次成功检查不足该时长则跳过。
const CHECK_THROTTLE: Duration = Duration::from_secs(6 * 3600);
/// npm view 超时。
const NPM_VIEW_TIMEOUT: Duration = Duration::from_secs(30);
/// npm install 超时（冷缓存安装数百个包可能耗时数分钟）。
const NPM_INSTALL_TIMEOUT: Duration = Duration::from_secs(600);
/// 滚动补丁标记（与 scripts/fetch-payload.sh 保持一致）。
const CSS_PATCH_MARK: &str = "dsh-desktop: 禁用页面级弹性滚动";
/// 负载包名。
const PKG: &str = "@deepseek-ai/dsh";

// ── 版本比较（semver 子集）────────────────────────────────────────────────

#[derive(Debug, PartialEq, Eq)]
struct Semver {
    major: u64,
    minor: u64,
    patch: u64,
    /// 预发布标识（"rc.6" → ["rc", "6"]）；空 = 正式版。
    pre: Vec<String>,
}

fn parse_semver(s: &str) -> Option<Semver> {
    let s = s.trim();
    let (core, pre) = match s.split_once('-') {
        Some((c, p)) => (c, p.split('.').map(String::from).collect()),
        None => (s, Vec::new()),
    };
    let mut parts = core.split('.');
    let major = parts.next()?.parse().ok()?;
    let minor = parts.next().unwrap_or("0").parse().ok()?;
    let patch = parts.next().unwrap_or("0").parse().ok()?;
    Some(Semver { major, minor, patch, pre })
}

fn cmp_pre(a: &[String], b: &[String]) -> Ordering {
    match (a.is_empty(), b.is_empty()) {
        (true, true) => return Ordering::Equal,
        // 正式版 > 预发布版
        (true, false) => return Ordering::Greater,
        (false, true) => return Ordering::Less,
        (false, false) => {}
    }
    for (x, y) in a.iter().zip(b.iter()) {
        let ord = match (x.parse::<u64>(), y.parse::<u64>()) {
            (Ok(nx), Ok(ny)) => nx.cmp(&ny),
            // 数字标识 > 字母标识
            (Ok(_), Err(_)) => Ordering::Greater,
            (Err(_), Ok(_)) => Ordering::Less,
            (Err(_), Err(_)) => x.cmp(y),
        };
        if ord != Ordering::Equal {
            return ord;
        }
    }
    a.len().cmp(&b.len())
}

impl Semver {
    fn cmp(&self, other: &Semver) -> Ordering {
        (self.major, self.minor, self.patch)
            .cmp(&(other.major, other.minor, other.patch))
            .then_with(|| cmp_pre(&self.pre, &other.pre))
    }
}

fn version_greater(a: &str, b: &str) -> bool {
    match (parse_semver(a), parse_semver(b)) {
        (Some(va), Some(vb)) => va.cmp(&vb) == Ordering::Greater,
        _ => false,
    }
}

// ── 路径解析 ──────────────────────────────────────────────────────────────

/// 内置 Node 二进制路径。
pub(crate) fn bundled_node_path(_app: &AppHandle) -> PathBuf {
    #[cfg(debug_assertions)]
    {
        std::env::var("DSH_DESKTOP_NODE")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from("node"))
    }
    #[cfg(not(debug_assertions))]
    {
        std::env::current_exe()
            .ok()
            .and_then(|exe| exe.parent().map(|p| p.join("node")))
            .unwrap_or_else(|| PathBuf::from("node"))
    }
}

/// 内置 server 负载目录（.app 包内，只读）。
pub(crate) fn bundled_server_dir(app: &AppHandle) -> PathBuf {
    #[cfg(debug_assertions)]
    {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("server")
    }
    #[cfg(not(debug_assertions))]
    {
        app.path()
            .resource_dir()
            .map(|r| r.join("server"))
            .unwrap_or_else(|_| PathBuf::from("server"))
    }
}

/// 内置 npm CLI（node tarball 中随附的 npm，随包分发）。
fn bundled_npm_cli(app: &AppHandle) -> PathBuf {
    #[cfg(debug_assertions)]
    {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("npm/bin/npm-cli.js")
    }
    #[cfg(not(debug_assertions))]
    {
        app.path()
            .resource_dir()
            .map(|r| r.join("npm/bin/npm-cli.js"))
            .unwrap_or_else(|_| PathBuf::from("npm/bin/npm-cli.js"))
    }
}

/// 应用数据目录（`~/Library/Application Support/com.dshdesktop.app`）。
fn updates_root(app: &AppHandle) -> Option<PathBuf> {
    app.path().app_data_dir().ok()
}

/// 读取负载的 @deepseek-ai/dsh 版本；bin.js 缺失视为无效。
fn payload_version(server: &Path) -> Option<String> {
    let pkg = server.join("node_modules/@deepseek-ai/dsh/package.json");
    if !server.join("node_modules/@deepseek-ai/dsh/lib/bin.js").exists() {
        return None;
    }
    let text = std::fs::read_to_string(pkg).ok()?;
    let json: serde_json::Value = serde_json::from_str(&text).ok()?;
    json.get("version")?.as_str().map(String::from)
}

/// 选择本次启动使用的负载：优先应用数据目录中的更新版，失败回退内置版。
pub(crate) fn select_server(app: &AppHandle) -> Result<(PathBuf, String), String> {
    let bundled = bundled_server_dir(app);
    if let Some(root) = updates_root(app) {
        let updated = root.join("server");
        if let Some(ver) = payload_version(&updated) {
            log_line(&format!("payload: 更新版 v{ver}（{}）", updated.display()));
            return Ok((updated, format!("updated v{ver}")));
        }
    }
    let ver = payload_version(&bundled).unwrap_or_else(|| "?".to_string());
    log_line(&format!("payload: 内置版 v{ver}（{}）", bundled.display()));
    Ok((bundled, format!("bundled v{ver}")))
}

// ── npm 命令执行 ──────────────────────────────────────────────────────────

/// 运行内置 node + npm CLI，捕获 stdout；stderr 仅入日志。
/// 超时或非零退出返回 Err。
fn run_npm(
    app: &AppHandle,
    args: &[String],
    timeout: Duration,
) -> Result<String, String> {
    let node = bundled_node_path(app);
    let npm_cli = bundled_npm_cli(app);
    if !npm_cli.exists() {
        return Err(format!("npm CLI 缺失：{}", npm_cli.display()));
    }
    let cache = std::env::var_os("HOME")
        .map(|h| PathBuf::from(h).join("Library/Caches/DSHDesktop/npm"))
        .unwrap_or_else(|| PathBuf::from("/tmp/dsh-npm-cache"));

    let mut child = StdCommand::new(&node)
        .arg(&npm_cli)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .env("npm_config_cache", &cache)
        .env("npm_config_update_notifier", "false")
        .env("npm_config_fund", "false")
        .spawn()
        .map_err(|e| format!("启动 npm 失败（{}）：{e}", npm_cli.display()))?;

    let stdout = child.stdout.take().ok_or("无法读取 npm stdout")?;
    let stderr = child.stderr.take().ok_or("无法读取 npm stderr")?;

    // stderr → 日志
    {
        std::thread::spawn(move || {
            let reader = BufReader::new(stderr);
            for line in reader.lines() {
                if let Ok(line) = line {
                    log_line(&format!("[npm:err] {line}"));
                }
            }
        });
    }

    // stdout → 通道（持续排空）
    let (tx, rx) = mpsc::channel::<String>();
    std::thread::spawn(move || {
        let reader = BufReader::new(stdout);
        for line in reader.lines() {
            match line {
                Ok(line) => {
                    if tx.send(line).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    });

    let mut lines = Vec::new();
    let deadline = Instant::now() + timeout;
    let status = loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            let _ = child.kill();
            let _ = child.wait();
            return Err("npm 命令超时".to_string());
        }
        match rx.recv_timeout(remaining) {
            Ok(line) => lines.push(line),
            Err(RecvTimeoutError::Disconnected) => {
                break child.wait().map_err(|e| e.to_string())?;
            }
            Err(RecvTimeoutError::Timeout) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err("npm 命令超时".to_string());
            }
        }
    };
    if !status.success() {
        let tail: Vec<&str> = lines.iter().rev().take(20).rev().map(String::as_str).collect();
        return Err(format!(
            "npm 退出码 {:?}，输出尾部：\n{}",
            status.code(),
            tail.join("\n")
        ));
    }
    Ok(lines.join("\n"))
}

fn npm_view(app: &AppHandle) -> Result<String, String> {
    let args = [
        "view".to_string(),
        PKG.to_string(),
        "version".to_string(),
        "--json".to_string(),
        "--fetch-timeout=15000".to_string(),
        "--fetch-retries=0".to_string(),
    ];
    let out = run_npm(app, &args, NPM_VIEW_TIMEOUT)?;
    let trimmed = out.trim().trim_matches('"');
    if trimmed.is_empty() {
        return Err("npm view 返回为空".to_string());
    }
    Ok(trimmed.to_string())
}

fn npm_install(app: &AppHandle, prefix: &Path, version: &str) -> Result<(), String> {
    std::fs::create_dir_all(prefix).map_err(|e| e.to_string())?;
    let pkg_json = prefix.join("package.json");
    std::fs::write(&pkg_json, "{\"name\":\"dsh-desktop-server\",\"private\":true}\n")
        .map_err(|e| e.to_string())?;
    let args = [
        "install".to_string(),
        "--prefix".to_string(),
        prefix.display().to_string(),
        "--omit=dev".to_string(),
        "--no-audit".to_string(),
        "--no-fund".to_string(),
        "--fetch-timeout=60000".to_string(),
        format!("{PKG}@{version}"),
    ];
    run_npm(app, &args, NPM_INSTALL_TIMEOUT)?;
    Ok(())
}

// ── 负载补丁（与 scripts/fetch-payload.sh / prune-payload.sh 保持一致）──────

/// 滚动修复 CSS 补丁（幂等）。
fn patch_css(server: &Path) {
    let assets = server.join("node_modules/@deepseek-ai/dsh-web-frontend/dist/assets");
    let Ok(entries) = std::fs::read_dir(&assets) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.starts_with("index-") && name.ends_with(".css") {
            let path = entry.path();
            let Ok(content) = std::fs::read_to_string(&path) else {
                continue;
            };
            if content.contains(CSS_PATCH_MARK) {
                continue;
            }
            if let Ok(mut f) = std::fs::OpenOptions::new().append(true).open(&path) {
                let _ = std::io::Write::write_fmt(
                    &mut f,
                    format_args!(
                        "\n/* {} */\nhtml,body{{height:100%;overflow:hidden;overscroll-behavior:none}}\n",
                        CSS_PATCH_MARK
                    ),
                );
            }
        }
    }
}

/// 精简原生预编译物：只保留 darwin-arm64（与 prune-payload.sh 一致）。
fn prune_native(server: &Path) {
    let nm = server.join("node_modules");
    // node-pty：只留 darwin-arm64 prebuilds
    let pty = nm.join("node-pty/prebuilds");
    if let Ok(entries) = std::fs::read_dir(&pty) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name != "darwin-arm64" {
                let _ = std::fs::remove_dir_all(entry.path());
            }
        }
    }
    // @img/sharp-*：只留 darwin-arm64 相关包
    let img = nm.join("@img");
    if let Ok(entries) = std::fs::read_dir(&img) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with("sharp-") && !name.contains("darwin-arm64") {
                let _ = std::fs::remove_dir_all(entry.path());
            }
        }
    }
}

fn patch_payload(server: &Path) {
    patch_css(server);
    prune_native(server);
}

// ── 更新主流程 ────────────────────────────────────────────────────────────

/// 启动时后台执行：查最新版 → 有新版则安装到暂存目录 → 校验 → 原子替换。
pub(crate) fn run(app: &AppHandle) {
    if std::env::var("DSH_DESKTOP_AUTOUPDATE").as_deref() == Ok("0") {
        log_line("auto-update disabled by DSH_DESKTOP_AUTOUPDATE=0");
        return;
    }
    let force = std::env::var("DSH_DESKTOP_FORCE_UPDATE").as_deref() == Ok("1");
    let Some(root) = updates_root(app) else {
        log_line("auto-update: 无法解析应用数据目录，跳过");
        return;
    };
    let _ = std::fs::create_dir_all(&root);

    // 节流：距上次成功检查不足 6 小时则跳过（force 除外）
    let throttle_path = root.join(".last-update-check");
    if !force {
        let last = std::fs::read_to_string(&throttle_path)
            .ok()
            .and_then(|s| s.trim().parse::<u64>().ok())
            .unwrap_or(0);
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        if now.saturating_sub(last) < CHECK_THROTTLE.as_secs() {
            log_line("auto-update: 距上次检查不足 6 小时，跳过");
            return;
        }
    }

    // 查最新版本
    let latest = match npm_view(app) {
        Ok(v) => v,
        Err(e) => {
            log_line(&format!("auto-update: 查询最新版本失败（可能离线）：{e}"));
            return;
        }
    };
    log_line(&format!("auto-update: npm 最新版本 {latest}"));

    // 当前版本（更新目录优先，其次内置）
    let current = {
        let updated = root.join("server");
        payload_version(&updated).or_else(|| payload_version(&bundled_server_dir(app)))
    };
    if !force {
        if let Some(cur) = &current {
            if !version_greater(&latest, cur) {
                log_line(&format!("auto-update: 已是最新（v{cur}），无需更新"));
                let now = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .map(|d| d.as_secs())
                    .unwrap_or(0);
                let _ = std::fs::write(&throttle_path, now.to_string());
                return;
            }
        }
        log_line(&format!(
            "auto-update: 发现新版本 v{latest}（当前 {}），开始安装…",
            current.as_deref().unwrap_or("未知")
        ));
    } else {
        log_line("auto-update: DSH_DESKTOP_FORCE_UPDATE=1 强制重装");
    }

    // 安装到暂存目录，成功后原子替换（避免中断产生半成品负载）
    let staging = root.join("server.new");
    let target = root.join("server");
    let _ = std::fs::remove_dir_all(&staging);
    match npm_install(app, &staging, &latest) {
        Ok(()) => {}
        Err(e) => {
            log_line(&format!("auto-update: 安装失败：{e}"));
            let _ = std::fs::remove_dir_all(&staging);
            return;
        }
    }
    patch_payload(&staging);
    if payload_version(&staging).is_none() {
        log_line("auto-update: 安装结果校验失败（bin.js 缺失），回退内置负载");
        let _ = std::fs::remove_dir_all(&staging);
        return;
    }
    let installed = payload_version(&staging).unwrap_or_else(|| latest.clone());
    let _ = std::fs::remove_dir_all(&target);
    match std::fs::rename(&staging, &target) {
        Ok(()) => {
            log_line(&format!(
                "auto-update: 更新完成（v{installed}），下次启动生效：{}",
                target.display()
            ));
            let now = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0);
            let _ = std::fs::write(&throttle_path, now.to_string());
        }
        Err(e) => {
            log_line(&format!("auto-update: 替换失败：{e}"));
        }
    }
}

// ── 单元测试 ──────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn semver_parse_and_compare() {
        assert!(version_greater("0.1.0-rc.7", "0.1.0-rc.6"));
        assert!(version_greater("0.1.0-rc.10", "0.1.0-rc.9"));
        assert!(version_greater("0.1.0", "0.1.0-rc.99"));
        assert!(version_greater("0.2.0-rc.1", "0.1.0-rc.99"));
        assert!(!version_greater("0.1.0-rc.6", "0.1.0-rc.6"));
        assert!(!version_greater("0.1.0-rc.6", "0.1.0"));
        assert!(!version_greater("0.1.0", "0.1.1"));
        assert!(!version_greater("0.1.0-rc.6", "garbage"));
    }
}
