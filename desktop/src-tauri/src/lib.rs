//! DeepSeek Harness 桌面外壳。
//!
//! 职责：启动内嵌的 dsh web 服务器（Node sidecar + npm 负载），
//! 在系统 WebView 窗口中加载其 Web UI；退出时确保子进程被终止。

use std::io::{BufRead, BufReader};
use std::path::PathBuf;
use std::process::{Child, Command as StdCommand, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::{
    AppHandle, Manager, RunEvent, WebviewUrl, WebviewWindowBuilder, WindowEvent,
};
use tauri_plugin_dialog::{DialogExt, MessageDialogKind};

/// 服务器就绪行前缀（dsh web 的官方 readiness 信号，见 web-app 的 printUrl）。
const READY_PREFIX: &str = "dsh web: http://";
/// 等待服务器就绪的最长时间。
const SERVER_TIMEOUT: Duration = Duration::from_secs(60);

/// 服务器子进程与运行状态。
struct ServerState {
    child: Mutex<Option<Child>>,
    url: Mutex<Option<String>>,
    quitting: AtomicBool,
}

impl Default for ServerState {
    fn default() -> Self {
        Self {
            child: Mutex::new(None),
            url: Mutex::new(None),
            quitting: AtomicBool::new(false),
        }
    }
}

/// 追加一行日志到 ~/Library/Logs/DeepSeekHarness/desktop.log（debug 构建同时打到 stderr）。
fn log_line(line: &str) {
    #[cfg(debug_assertions)]
    eprintln!("[dsh-desktop] {line}");
    let Some(home) = std::env::var_os("HOME") else { return };
    let dir = PathBuf::from(home).join("Library/Logs/DeepSeekHarness");
    if std::fs::create_dir_all(&dir).is_err() {
        return;
    }
    if let Ok(mut file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join("desktop.log"))
    {
        use std::io::Write;
        let ts = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0);
        let _ = writeln!(file, "[{ts}] {line}");
    }
}

/// 从 dsh 的就绪行中提取 http://127.0.0.1:<port>。
fn extract_url(line: &str) -> Option<String> {
    let rest = line.strip_prefix(READY_PREFIX)?;
    let host_port: String = rest.chars().take_while(|c| !c.is_whitespace()).collect();
    if host_port.is_empty() {
        return None;
    }
    Some(format!("http://{host_port}"))
}

/// 解析 Node 与 server 负载的位置。
///
/// - release：node 是 externalBin sidecar（打包后位于 Contents/MacOS/node）；
///   server 负载经 bundle.resources（"server/**"，相对 src-tauri 解析）复制到
///   Contents/Resources/server。
/// - debug：node 取 $DSH_DESKTOP_NODE 或 PATH 中的 node；server 取 src-tauri/server。
fn resolve_node_and_server(_app: &AppHandle) -> Result<(PathBuf, PathBuf), String> {
    #[cfg(debug_assertions)]
    {
        let node = std::env::var("DSH_DESKTOP_NODE").unwrap_or_else(|_| "node".to_string());
        let server = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("server");
        Ok((PathBuf::from(node), server))
    }
    #[cfg(not(debug_assertions))]
    {
        let exe = std::env::current_exe().map_err(|e| e.to_string())?;
        let exe_dir = exe
            .parent()
            .ok_or_else(|| "无法确定可执行文件目录".to_string())?
            .to_path_buf();
        let node = exe_dir.join("node");
        let resources = _app.path().resource_dir().map_err(|e| e.to_string())?;
        let server = resources.join("server");
        Ok((node, server))
    }
}

/// 弹出致命错误对话框（在独立线程阻塞显示，避免阻塞主线程），关闭后退出应用。
fn fatal_dialog(app: &AppHandle, message: String) {
    log_line(&format!("fatal: {message}"));
    let app = app.clone();
    std::thread::spawn(move || {
        app.dialog()
            .message(message)
            .title("DeepSeek Harness")
            .kind(MessageDialogKind::Error)
            .blocking_show();
        app.exit(1);
    });
}

/// 终止服务器子进程：SIGTERM → 最多等 3 秒 → SIGKILL。
fn kill_server(app: &AppHandle) {
    let state = app.state::<ServerState>();
    state.quitting.store(true, Ordering::SeqCst);
    let mut child = state.child.lock().unwrap().take();
    if let Some(child) = child.as_mut() {
        log_line("terminating server child (SIGTERM)");
        // SAFETY: kill 只接受 pid，无其他不安全操作。
        unsafe {
            libc::kill(child.id() as i32, libc::SIGTERM);
        }
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            match child.try_wait() {
                Ok(Some(_)) => {
                    log_line("server child exited");
                    break;
                }
                Ok(None) => {
                    if Instant::now() > deadline {
                        log_line("server child did not exit in time; SIGKILL");
                        let _ = child.kill();
                        let _ = child.wait();
                        break;
                    }
                    std::thread::sleep(Duration::from_millis(100));
                }
                Err(_) => break,
            }
        }
    }
}

/// 启动 dsh web 服务器并监视其输出，就绪后导航主窗口。
fn boot_server(app: &AppHandle) -> Result<(), String> {
    let (node, server) = resolve_node_and_server(app)?;
    let bin_js = server.join("node_modules/@deepseek-ai/dsh/lib/bin.js");
    if !bin_js.exists() {
        return Err(format!(
            "未找到服务器入口 {}（server/ 负载不完整，请重新运行 build.sh）",
            bin_js.display()
        ));
    }
    let home = app.path().home_dir().map_err(|e| e.to_string())?;
    log_line(&format!(
        "spawning server: {} {} web --host 127.0.0.1 --port 0 (cwd={})",
        node.display(),
        bin_js.display(),
        home.display()
    ));

    let mut child = StdCommand::new(&node)
        .arg(&bin_js)
        .args(["web", "--host", "127.0.0.1", "--port", "0"])
        .current_dir(&home)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("启动服务器失败（{}）：{e}", node.display()))?;

    let stdout = child.stdout.take().ok_or("无法读取服务器 stdout")?;
    let stderr = child.stderr.take().ok_or("无法读取服务器 stderr")?;

    {
        let state = app.state::<ServerState>();
        *state.child.lock().unwrap() = Some(child);
    }

    // stderr → 日志
    {
        std::thread::spawn(move || {
            let reader = BufReader::new(stderr);
            for line in reader.lines() {
                if let Ok(line) = line {
                    log_line(&format!("[server:err] {line}"));
                }
            }
        });
    }

    // stdout → 通道（持续排空，避免管道写满阻塞服务器）
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

    // 主监视循环：等就绪行 → 导航窗口；进程退出/超时 → 报错退出。
    let deadline = Instant::now() + SERVER_TIMEOUT;
    let mut ready = false;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if !ready && remaining.is_zero() {
            log_line("server did not become ready in time");
            fatal_dialog(
                app,
                "DeepSeek Harness 服务器启动超时。\n请查看日志：~/Library/Logs/DeepSeekHarness/desktop.log".to_string(),
            );
            return Ok(());
        }
        let wait = if ready {
            Duration::from_secs(3600)
        } else {
            remaining
        };
        match rx.recv_timeout(wait) {
            Ok(line) => {
                log_line(&format!("[server] {line}"));
                if !ready {
                    if let Some(url) = extract_url(&line) {
                        ready = true;
                        log_line(&format!("server ready: {url}"));
                        {
                            let state = app.state::<ServerState>();
                            *state.url.lock().unwrap() = Some(url.clone());
                        }
                        let app = app.clone();
                        let url = url.clone();
                        let app2 = app.clone();
                        app.run_on_main_thread(move || {
                            if let Some(window) = app2.get_webview_window("main") {
                                match url::Url::parse(&url) {
                                    Ok(url) => {
                                        let _ = window.navigate(url);
                                    }
                                    Err(error) => log_line(&format!("无法解析 URL: {error}")),
                                }
                            }
                        })
                        .ok();
                    }
                }
            }
            Err(RecvTimeoutError::Disconnected) => {
                log_line("server stdout closed (process exited)");
                let quitting = app.state::<ServerState>().quitting.load(Ordering::SeqCst);
                if !quitting {
                    fatal_dialog(
                        app,
                        if ready {
                            "DeepSeek Harness 服务器已退出，应用将关闭。".to_string()
                        } else {
                            "DeepSeek Harness 服务器启动失败（进程提前退出）。\n请查看日志：~/Library/Logs/DeepSeekHarness/desktop.log".to_string()
                        },
                    );
                }
                return Ok(());
            }
            Err(RecvTimeoutError::Timeout) => {
                // ready 后等待时间很长，理论上不会走到这里。
            }
        }
    }
}

/// 构建最小 macOS 菜单。
fn setup_menu(app: &tauri::App) -> tauri::Result<()> {
    let about = PredefinedMenuItem::about(app, None, None)?;
    let separator = PredefinedMenuItem::separator(app)?;
    let reload = MenuItem::with_id(app, "reload", "重新加载", true, Some("CmdOrCtrl+R"))?;
    let open_browser = MenuItem::with_id(app, "open-browser", "在浏览器中打开", true, None::<&str>)?;
    let quit = PredefinedMenuItem::quit(app, Some("退出 DeepSeek Harness"))?;
    let menu = Menu::with_items(
        app,
        &[&about, &separator, &reload, &open_browser, &separator, &quit],
    )?;
    app.set_menu(menu)?;
    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            // 单实例：再次启动时聚焦已有窗口。
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.set_focus();
            }
        }))
        .setup(|app| {
            app.manage(ServerState::default());
            setup_menu(app)?;

            // 先显示 splash 页，服务器就绪后导航到真实 UI。
            let window = WebviewWindowBuilder::new(
                app,
                "main",
                WebviewUrl::App("index.html".into()),
            )
            .title("DeepSeek Harness")
            .inner_size(1280.0, 860.0)
            .min_inner_size(900.0, 600.0)
            .build()?;
            window.show()?;

            let handle = app.handle().clone();
            std::thread::spawn(move || {
                if let Err(error) = boot_server(&handle) {
                    fatal_dialog(&handle, format!("无法启动 DeepSeek Harness 服务器：\n{error}"));
                }
            });
            Ok(())
        })
        .on_menu_event(|app, event| match event.id().as_ref() {
            "reload" => {
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.eval("window.location.reload()");
                }
            }
            "open-browser" => {
                let url = app.state::<ServerState>().url.lock().unwrap().clone();
                if let Some(url) = url {
                    let _ = StdCommand::new("open").arg(url).spawn();
                }
            }
            _ => {}
        })
        .on_window_event(|window, event| {
            if matches!(event, WindowEvent::Destroyed) {
                kill_server(window.app_handle());
            }
        })
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|app_handle, event| {
            if matches!(event, RunEvent::ExitRequested { .. } | RunEvent::Exit) {
                kill_server(app_handle);
            }
        });
}
