// PowerShell sidecar bridge.
//
// Owns the long-lived `pwsh windeploykit-sidecar.ps1` child process and exposes it to
// the JS frontend through three Tauri commands (`sidecar_invoke`,
// `sidecar_restart`, `sidecar_status`) plus two event channels
// (`sidecar://event` and `sidecar://log`).
//
// Protocol (see sidecar/lib/Ipc.ps1):
//   request  (stdin):  {"id": <int>, "cmd": "<name>", "params": {...}}\n
//   success  (stdout): {"id": <int>, "ok": true,  "data": <any>}\n
//   failure  (stdout): {"id": <int>, "ok": false, "error": "...", "code": "..."}\n
//   event    (stdout): {"event": "<name>", "data": <any>}\n
//   log line (stderr): free-form text, one line per record\n
//
// Request/response correlation uses a HashMap<i64, oneshot::Sender>.
// Events are forwarded as Tauri events. stderr lines are forwarded as logs.

use std::collections::HashMap;
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Arc;

use chrono::{DateTime, Utc};
use parking_lot::Mutex;
use serde::Serialize;
use serde_json::Value;
use tauri::{AppHandle, Emitter, Manager, Runtime};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;
use tracing::{debug, info, warn};

#[cfg(windows)]
use std::os::windows::process::CommandExt;

/// Hide the pwsh console when the GUI app spawns the sidecar (Win32 CREATE_NO_WINDOW).
#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x08000000;

pub type SidecarHandle = AppHandle;

const EVENT_CHANNEL: &str = "sidecar://event";
const LOG_CHANNEL: &str = "sidecar://log";
// Hard ceiling so a stuck sidecar can't trap a UI request forever.
const REQUEST_TIMEOUT_SECS: u64 = 120;
fn request_timeout_secs(cmd: &str) -> u64 {
    match cmd {
        // Long-running imaging work: WIM/ISO import and asset fetches move GBs, and
        // the sidecar is single-threaded, so a UI timeout would free the caller while
        // the sidecar stays blocked and every later command queues behind it.
        "ImportPxeBootWim" => 1800,
        "ImportPxeBootWimFromIso" => 1800,
        "ListPxeBootIsoWims" => 600,
        "ImportPxeBootIso" => 1800,
        "DownloadPxeBootFieldIso" => 1800,
        "DownloadPxeBootOptionalAsset" => 7200,
        "EnsurePxeBootCaddy" => 600,
        "EnsurePxeBootTftpd64" => 600,
        "StartPxeBootServices" | "StopPxeBootServices" => 600,
        "GetPxeBootPluginConfig" | "SetPxeBootPluginConfig" => 180,
        "GetPxeBootPluginStatus" => 90,
        "EnsureAria2Binary" => 600,
        _ => REQUEST_TIMEOUT_SECS,
    }
}

#[derive(thiserror::Error, Debug, Serialize)]
#[serde(tag = "kind", content = "details")]
pub enum SidecarError {
    #[error("sidecar is not running")]
    NotRunning,
    #[error("sidecar IO error: {0}")]
    Io(String),
    #[error("sidecar request timed out after {0}s")]
    Timeout(u64),
    #[error("sidecar returned error: {message} ({code})")]
    Remote { message: String, code: String },
    #[error("invalid response from sidecar: {0}")]
    BadResponse(String),
}

#[derive(Clone, Debug, Serialize)]
pub struct SidecarStatus {
    pub running: bool,
    pub ready: bool,
    pub pid: Option<u32>,
    #[serde(rename = "startedAt", skip_serializing_if = "Option::is_none")]
    pub started_at: Option<DateTime<Utc>>,
    #[serde(rename = "lastError", skip_serializing_if = "Option::is_none")]
    pub last_error: Option<String>,
}

/// Result of the pre-bootstrap PowerShell 7 probe (before sidecar spawn).
#[derive(Clone, Debug, Serialize)]
pub struct PwshPrerequisite {
    pub available: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    pub platform: String,
    #[serde(rename = "installCommand", skip_serializing_if = "Option::is_none")]
    pub install_command: Option<String>,
    #[serde(rename = "releasesUrl")]
    pub releases_url: String,
}

const PWSH_RELEASES_URL: &str = "https://github.com/PowerShell/PowerShell/releases/latest";

// Outbound requests are funnelled through this single channel so the
// stdin-writer task owns the pwsh `stdin` exclusively.
struct OutboundRequest {
    line: String,
}

#[derive(Default)]
struct State {
    /// Pending in-flight requests keyed by id.
    pending: HashMap<i64, oneshot::Sender<Value>>,
    /// Current child process pid (None while restarting).
    pid: Option<u32>,
    /// Sender for outbound (stdin) lines. None when no child is running.
    outbound: Option<mpsc::UnboundedSender<OutboundRequest>>,
    /// Sidecar has emitted the `ready` event.
    ready: bool,
    started_at: Option<DateTime<Utc>>,
    last_error: Option<String>,
    /// stdin/stdout/stderr reader tasks for the current child.
    io_tasks: Vec<JoinHandle<()>>,
    /// Waits for pwsh to exit after stdin EOF so finally { umount } can run.
    wait_task: Option<JoinHandle<()>>,
    /// Guard against duplicate cleanup when both ExitRequested and Exit fire.
    exit_started: bool,
}

fn fail_pending_requests(st: &mut State, message: &str, code: &str) {
    let pending = std::mem::take(&mut st.pending);
    for (_id, tx) in pending {
        let _ = tx.send(serde_json::json!({
            "ok": false,
            "error": message,
            "code": code
        }));
    }
}

pub struct Sidecar {
    app: SidecarHandle,
    state: Mutex<State>,
    next_id: AtomicI64,
    spawn_env: Mutex<std::collections::HashMap<String, String>>,
    /// Serializes restart/spawn so concurrent JS wires (e.g. React StrictMode) cannot leave two pwsh children.
    restart_lock: tokio::sync::Mutex<()>,
}

impl Sidecar {
    pub fn new(app: SidecarHandle) -> Self {
        Self {
            app,
            state: Mutex::new(State::default()),
            next_id: AtomicI64::new(1),
            spawn_env: Mutex::new(std::collections::HashMap::new()),
            restart_lock: tokio::sync::Mutex::new(()),
        }
    }

    pub fn shutdown(&self) {
        let mut st = self.state.lock();
        fail_pending_requests(&mut st, "sidecar operation cancelled", "CANCELLED");
        st.ready = false;
        st.outbound.take();
        for h in st.io_tasks.drain(..) {
            h.abort();
        }
    }

    /// Graceful app exit: close stdin so pwsh can run finally, but do not abort the
    /// stdin-writer task before it sends EOF (aborting it leaves pwsh + smbfs alive).
    fn shutdown_for_exit(&self) {
        let mut st = self.state.lock();
        fail_pending_requests(&mut st, "sidecar shutting down", "CANCELLED");
        st.ready = false;
        st.outbound.take();
    }

    fn kill_sidecar_child(pid: Option<u32>) {
        let Some(pid) = pid else {
            return;
        };
        #[cfg(unix)]
        {
            for sig in ["-TERM", "-KILL"] {
                let _ = std::process::Command::new("/bin/kill")
                    .arg(sig)
                    .arg(pid.to_string())
                    .status();
                std::thread::sleep(std::time::Duration::from_millis(300));
            }
        }
        #[cfg(windows)]
        {
            let _ = std::process::Command::new("taskkill")
                .args(["/PID", &pid.to_string(), "/T", "/F"])
                .creation_flags(CREATE_NO_WINDOW)
                .status();
        }
    }

    fn force_kill_child(&self) {
        let pid = self.state.lock().pid;
        Self::kill_sidecar_child(pid);
        let mut st = self.state.lock();
        if let Some(h) = st.wait_task.take() {
            h.abort();
        }
        for h in st.io_tasks.drain(..) {
            h.abort();
        }
        st.pid = None;
        st.outbound = None;
        st.ready = false;
    }

    /// App exit: stop PXE boot services, close stdin, stop pwsh.
    pub fn exit(self: &Arc<Self>) {
        {
            let mut st = self.state.lock();
            if st.exit_started {
                return;
            }
            st.exit_started = true;
        }

        // Never block_on from the AppKit main thread — it deadlocks the Tauri tokio runtime (macOS hang on quit).
        let me = Arc::clone(self);
        let worker = std::thread::Builder::new()
            .name("windeploykit-sidecar-exit".into())
            .spawn(move || me.exit_worker())
            .ok();

        const MAX_WAIT: std::time::Duration = std::time::Duration::from_secs(8);
        let started = std::time::Instant::now();
        if let Some(handle) = worker {
            while started.elapsed() < MAX_WAIT {
                if handle.is_finished() {
                    let _ = handle.join();
                    return;
                }
                std::thread::sleep(std::time::Duration::from_millis(50));
            }
            warn!(
                "sidecar exit worker timed out after {}s — force killing",
                MAX_WAIT.as_secs()
            );
        }

        self.force_kill_child();
    }

    fn exit_worker(self: &Arc<Self>) {
        let running = self.state.lock().outbound.is_some();
        if running {
            let me = Arc::clone(self);
            tauri::async_runtime::block_on(async move {
                let _ = tokio::time::timeout(
                    std::time::Duration::from_millis(3000),
                    me.invoke(
                        "PrepareAppExit".to_string(),
                        serde_json::json!({}),
                    ),
                )
                .await;
            });
        }

        // Drop outbound only — stdin_writer must flush EOF to pwsh before we abort I/O tasks.
        self.shutdown_for_exit();

        const GRACE_SECS: u64 = 3;
        let wait_handle = self.state.lock().wait_task.take();
        let timed_out = if let Some(h) = wait_handle {
            tauri::async_runtime::block_on(async move {
                tokio::select! {
                    res = h => {
                        if let Err(e) = res {
                            warn!("sidecar wait task join error: {e}");
                        }
                        false
                    }
                    _ = tokio::time::sleep(std::time::Duration::from_secs(GRACE_SECS)) => {
                        warn!(
                            "sidecar did not exit within {GRACE_SECS}s after stdin closed"
                        );
                        true
                    }
                }
            })
        } else {
            false
        };

        if timed_out || self.state.lock().pid.is_some() {
            warn!("sidecar still running after graceful shutdown — force killing");
            self.force_kill_child();
        }

    }

    pub async fn restart(
        self: &Arc<Self>,
        spawn_env: Option<std::collections::HashMap<String, String>>,
    ) -> Result<(), SidecarError> {
        let _restart_guard = self.restart_lock.lock().await;
        if let Some(env) = spawn_env {
            *self.spawn_env.lock() = env;
        }
        self.shutdown();
        self.force_kill_child();
        let me = Arc::clone(self);
        me.spawn_async()
            .await
            .map_err(|e| SidecarError::Io(e.to_string()))
    }

    pub fn status(&self) -> SidecarStatus {
        let st = self.state.lock();
        SidecarStatus {
            running: st.outbound.is_some(),
            ready: st.ready,
            pid: st.pid,
            started_at: st.started_at,
            last_error: st.last_error.clone(),
        }
    }

    pub async fn invoke(
        self: &Arc<Self>,
        cmd: String,
        params: Value,
    ) -> Result<Value, SidecarError> {
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let req = serde_json::json!({ "id": id, "cmd": cmd, "params": params });
        let line = serde_json::to_string(&req)
            .map_err(|e| SidecarError::BadResponse(format!("serialize: {e}")))?;

        let (tx, rx) = oneshot::channel();
        let outbound = {
            let mut st = self.state.lock();
            st.pending.insert(id, tx);
            st.outbound.clone()
        };
        let outbound = outbound.ok_or(SidecarError::NotRunning)?;
        outbound
            .send(OutboundRequest { line })
            .map_err(|_| SidecarError::NotRunning)?;

        let timeout_secs = request_timeout_secs(&cmd);
        let timeout = tokio::time::Duration::from_secs(timeout_secs);
        match tokio::time::timeout(timeout, rx).await {
            Ok(Ok(resp)) => decode_response(resp),
            Ok(Err(_)) => {
                self.state.lock().pending.remove(&id);
                Err(SidecarError::NotRunning)
            }
            Err(_) => {
                self.state.lock().pending.remove(&id);
                Err(SidecarError::Timeout(timeout_secs))
            }
        }
    }

    async fn spawn_async(self: &Arc<Self>) -> anyhow::Result<()> {
        let script = resolve_sidecar_script(&self.app)?;
        let project_root = resolve_sidecar_project_root(&script, &self.app);
        let cwd = script
            .parent()
            .map(|p| p.to_path_buf())
            .unwrap_or_else(|| PathBuf::from("."));

        let (pwsh, pwsh_cwd) = resolve_pwsh_launch(&self.app).ok_or_else(|| {
            anyhow::anyhow!(
                "PowerShell 7 (pwsh) was not found. Install it, then restart the app."
            )
        })?;
        info!(
            "spawning sidecar: {} {} (sidecar_cwd={} pwsh_cwd={} project_root={})",
            pwsh.display(),
            script.display(),
            cwd.display(),
            pwsh_cwd.display(),
            project_root
                .as_ref()
                .map(|p| p.display().to_string())
                .unwrap_or_else(|| "(default)".to_string())
        );

        let mut child_cmd = Command::new(&pwsh);
        child_cmd
            .arg("-NoLogo")
            .arg("-NoProfile")
            .arg("-NonInteractive")
            .arg("-ExecutionPolicy")
            .arg("Bypass")
            .arg("-File")
            .arg(&script);
        // Hide the console via CREATE_NO_WINDOW below — do not pass pwsh -WindowStyle;
        // it is missing on several site pwsh builds and aborts before windeploykit-sidecar.ps1 runs.
        if let Some(root) = project_root {
            child_cmd.arg("-ProjectRoot").arg(root);
        }
        #[cfg(windows)]
        child_cmd.creation_flags(CREATE_NO_WINDOW);
        for (key, value) in self.spawn_env.lock().iter() {
            child_cmd.env(key, value);
        }
        let mut child = child_cmd
            .current_dir(&pwsh_cwd)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .map_err(|e| anyhow::anyhow!("failed to spawn `{}`: {e}", pwsh.display()))?;

        let pid = child.id();
        let stdin = child.stdin.take().ok_or_else(|| anyhow::anyhow!("no stdin"))?;
        let stdout = child.stdout.take().ok_or_else(|| anyhow::anyhow!("no stdout"))?;
        let stderr = child.stderr.take().ok_or_else(|| anyhow::anyhow!("no stderr"))?;

        let (tx, rx) = mpsc::unbounded_channel::<OutboundRequest>();

        let stdin_task = tokio::spawn(stdin_writer(stdin, rx));
        let stdout_task = tokio::spawn(stdout_reader(stdout, Arc::clone(self)));
        let stderr_task = tokio::spawn(stderr_reader(stderr, self.app.clone()));
        let wait_task = tokio::spawn(child_waiter(child, Arc::clone(self)));

        {
            let mut st = self.state.lock();
            st.pid = pid;
            st.outbound = Some(tx);
            st.ready = false;
            st.started_at = Some(Utc::now());
            st.last_error = None;
            st.io_tasks = vec![stdin_task, stdout_task, stderr_task];
            st.wait_task = Some(wait_task);
        }

        Ok(())
    }
}

async fn stdin_writer(mut stdin: ChildStdin, mut rx: mpsc::UnboundedReceiver<OutboundRequest>) {
    while let Some(req) = rx.recv().await {
        if let Err(e) = stdin.write_all(req.line.as_bytes()).await {
            warn!("stdin write_all failed: {e}");
            break;
        }
        if let Err(e) = stdin.write_all(b"\n").await {
            warn!("stdin newline failed: {e}");
            break;
        }
        if let Err(e) = stdin.flush().await {
            warn!("stdin flush failed: {e}");
            break;
        }
    }
    let _ = stdin.shutdown().await;
    debug!("stdin writer exiting");
}

async fn stdout_reader(stdout: tokio::process::ChildStdout, sc: Arc<Sidecar>) {
    let mut lines = BufReader::new(stdout).lines();
    loop {
        match lines.next_line().await {
            Ok(Some(line)) => {
                if line.is_empty() {
                    continue;
                }
                handle_stdout_line(&sc, &line);
            }
            Ok(None) => {
                debug!("sidecar stdout closed");
                break;
            }
            Err(e) => {
                warn!("stdout read error: {e}");
                break;
            }
        }
    }
}

fn handle_stdout_line(sc: &Arc<Sidecar>, line: &str) {
    let parsed: Value = match serde_json::from_str(line) {
        Ok(v) => v,
        Err(e) => {
            // Forward as a log line so the user can see it in the log overlay.
            warn!("non-JSON stdout line: {e}: {line}");
            emit_log(&sc.app, format!("[stdout] {line}"));
            return;
        }
    };

    // Distinguish between event-shaped and response-shaped messages.
    if parsed.get("event").is_some() {
        let event_name = parsed
            .get("event")
            .and_then(|v| v.as_str())
            .unwrap_or("unknown")
            .to_string();
        let data = parsed.get("data").cloned().unwrap_or(Value::Null);
        if event_name == "ready" {
            sc.state.lock().ready = true;
        }
        emit_event(&sc.app, &event_name, data);
        return;
    }

    if let Some(id) = parsed.get("id").and_then(|v| v.as_i64()) {
        let waiter = sc.state.lock().pending.remove(&id);
        if let Some(tx) = waiter {
            let _ = tx.send(parsed);
        } else {
            debug!("response for unknown id {id} dropped");
        }
        return;
    }

    warn!("unrecognised stdout payload: {line}");
}

async fn stderr_reader<R: Runtime>(stderr: tokio::process::ChildStderr, app: AppHandle<R>) {
    let mut lines = BufReader::new(stderr).lines();
    loop {
        match lines.next_line().await {
            Ok(Some(line)) => {
                let line = strip_ansi_escapes(&line);
                if !line.is_empty() {
                    emit_log(&app, line);
                }
            }
            Ok(None) => break,
            Err(e) => {
                warn!("stderr read error: {e}");
                break;
            }
        }
    }
}

async fn child_waiter(mut child: Child, sc: Arc<Sidecar>) {
    let child_pid = child.id();
    let mut exit_code: Option<i32> = None;
    let mut success = false;
    let mut wait_error: Option<String> = None;

    match child.wait().await {
        Ok(status) => {
            info!("sidecar exited: {status}");
            success = status.success();
            exit_code = status.code();
            let mut st = sc.state.lock();
            // Restart/spawn may have replaced this child — ignore stale waiters.
            if st.pid != child_pid {
                return;
            }
            st.outbound = None;
            st.ready = false;
            st.pid = None;
            st.wait_task = None;
            if !success {
                st.last_error = Some(format!("sidecar exited with {status}"));
            }
        }
        Err(e) => {
            warn!("sidecar wait error: {e}");
            wait_error = Some(e.to_string());
            let mut st = sc.state.lock();
            if st.pid != child_pid {
                return;
            }
            st.wait_task = None;
            st.last_error = Some(e.to_string());
        }
    }
    // Fail every in-flight request — they will not get answered.
    let pending = std::mem::take(&mut sc.state.lock().pending);
    for (_id, tx) in pending {
        let _ = tx.send(serde_json::json!({
            "ok": false,
            "error": "sidecar exited",
            "code": "CANCELLED"
        }));
    }
    emit_event(
        &sc.app,
        "exited",
        serde_json::json!({
            "pid": child_pid,
            "exitCode": exit_code,
            "success": success,
            "waitError": wait_error,
        }),
    );
}

fn emit_event<R: Runtime>(app: &AppHandle<R>, name: &str, data: Value) {
    let payload = serde_json::json!({ "event": name, "data": data });
    if let Err(e) = app.emit(EVENT_CHANNEL, &payload) {
        warn!("emit event failed: {e}");
    }
}

fn emit_log<R: Runtime>(app: &AppHandle<R>, line: String) {
    if let Err(e) = app.emit(LOG_CHANNEL, &line) {
        warn!("emit log failed: {e}");
    }
}

/// Remove CSI/OSC ANSI sequences so pwsh host styling does not leak into the log panel.
fn strip_ansi_escapes(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\x1b' {
            if chars.peek() == Some(&'[') {
                chars.next();
                for c2 in chars.by_ref() {
                    if ('@'..='~').contains(&c2) {
                        break;
                    }
                }
            }
            continue;
        }
        out.push(c);
    }
    out
}


fn decode_response(v: Value) -> Result<Value, SidecarError> {
    let ok = v.get("ok").and_then(|x| x.as_bool()).unwrap_or(false);
    if ok {
        return Ok(v.get("data").cloned().unwrap_or(Value::Null));
    }
    let message = v
        .get("error")
        .and_then(|x| x.as_str())
        .unwrap_or("unknown error")
        .to_string();
    let code = v
        .get("code")
        .and_then(|x| x.as_str())
        .unwrap_or("UNKNOWN")
        .to_string();
    Err(SidecarError::Remote { message, code })
}

/// Bundled portable PowerShell (`Resources/powershell` on macOS, `resources/powershell` on Windows).
fn bundled_pwsh_dir(resource_dir: &std::path::Path) -> Option<(PathBuf, PathBuf)> {
    let root = resource_dir.join("powershell");
    for name in ["pwsh.exe", "pwsh"] {
        let exe = root.join(name);
        if exe.is_file() {
            return Some((exe, root));
        }
    }
    None
}

pub fn check_pwsh_prerequisite<R: Runtime>(app: &AppHandle<R>) -> PwshPrerequisite {
    let platform = if cfg!(target_os = "windows") {
        "windows"
    } else if cfg!(target_os = "macos") {
        "macos"
    } else if cfg!(target_os = "linux") {
        "linux"
    } else {
        "unknown"
    }
    .to_string();

    let install_command = match platform.as_str() {
        "windows" => Some("winget install Microsoft.PowerShell".to_string()),
        "macos" => Some("brew install powershell".to_string()),
        _ => None,
    };

    let resolved = resolve_pwsh_launch(app);
    PwshPrerequisite {
        available: resolved.is_some(),
        path: resolved.map(|(exe, _)| exe.display().to_string()),
        platform,
        install_command,
        releases_url: PWSH_RELEASES_URL.to_string(),
    }
}

/// Returns `(pwsh executable, working directory for the child process)` when a
/// real install exists. PowerShell is a directory install on macOS/Windows — cwd
/// must be the install root.
fn resolve_pwsh_launch<R: Runtime>(app: &AppHandle<R>) -> Option<(PathBuf, PathBuf)> {
    if let Ok(p) = std::env::var("STMC_PWSH") {
        let pb = PathBuf::from(p.trim());
        if pb.is_file() {
            let cwd = pb
                .parent()
                .map(|p| p.to_path_buf())
                .unwrap_or_else(|| PathBuf::from("."));
            return Some((pb, cwd));
        }
    }

    if let Ok(resource_dir) = app.path().resource_dir() {
        if let Some((exe, cwd)) = bundled_pwsh_dir(&resource_dir) {
            return Some((exe, cwd));
        }
    }

    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            for name in ["pwsh", "pwsh.exe"] {
                let candidate = dir.join(name);
                if candidate.is_file() {
                    let cwd = dir.to_path_buf();
                    return Some((candidate, cwd));
                }
            }
        }
    }

    // Finder-launched .app often has a minimal PATH (no Homebrew dirs).
    #[cfg(target_os = "macos")]
    for candidate in [
        "/opt/homebrew/bin/pwsh",
        "/usr/local/bin/pwsh",
        "/usr/local/microsoft/powershell/7/pwsh",
    ] {
        let pb = PathBuf::from(candidate);
        if pb.is_file() {
            let cwd = pb.parent().unwrap_or(std::path::Path::new("/")).to_path_buf();
            return Some((pb, cwd));
        }
    }

    // Explorer / Start-menu launches often inherit a minimal PATH without
    // PowerShell 7. Elevated ("Run as administrator") processes get the full
    // machine PATH, which is one reason admin-only launches appear to work.
    #[cfg(target_os = "windows")]
    {
        let mut candidates: Vec<PathBuf> = Vec::new();
        if let Ok(pf) = std::env::var("ProgramFiles") {
            candidates.push(PathBuf::from(pf).join("PowerShell/7/pwsh.exe"));
        }
        if let Ok(pfx) = std::env::var("ProgramFiles(x86)") {
            candidates.push(PathBuf::from(pfx).join("PowerShell/7/pwsh.exe"));
        }
        if let Ok(local) = std::env::var("LOCALAPPDATA") {
            candidates.push(PathBuf::from(local).join("Microsoft/WindowsApps/pwsh.exe"));
        }
        candidates.push(PathBuf::from(r"C:\Program Files\PowerShell\7\pwsh.exe"));
        for pb in candidates {
            if pb.is_file() {
                let cwd = pb
                    .parent()
                    .map(|p| p.to_path_buf())
                    .unwrap_or_else(|| PathBuf::from("."));
                return Some((pb, cwd));
            }
        }
    }

    None
}

fn resolve_sidecar_project_root<R: Runtime>(
    script: &std::path::Path,
    app: &AppHandle<R>,
) -> Option<PathBuf> {
    if let Ok(resource_dir) = app.path().resource_dir() {
        if script.starts_with(&resource_dir) {
            return Some(resource_dir);
        }
    }
    script
        .parent()
        .and_then(|sidecar_dir| sidecar_dir.parent().map(|p| p.to_path_buf()))
}

fn resolve_sidecar_script<R: Runtime>(app: &AppHandle<R>) -> anyhow::Result<PathBuf> {
    // Allow override for dev environments where the bundled resource layout
    // doesn't apply (we want the script the user is editing live).
    if let Ok(p) = std::env::var("STMC_SIDECAR_SCRIPT") {
        let pb = PathBuf::from(p);
        if pb.is_file() {
            return Ok(pb);
        }
    }

    // Dev mode: the workspace root sits two levels above src-tauri/.
    // The script lives at <repo>/sidecar/windeploykit-sidecar.ps1.
    let cwd = std::env::current_dir()?;
    let candidates = [
        cwd.join("../sidecar/windeploykit-sidecar.ps1"),
        cwd.join("sidecar/windeploykit-sidecar.ps1"),
        cwd.join("../../sidecar/windeploykit-sidecar.ps1"),
    ];
    for c in candidates.iter() {
        if c.is_file() {
            return Ok(c.clone());
        }
    }

    // Production bundle: shipped under the app's resource dir.
    if let Ok(resource_dir) = app.path().resource_dir() {
        let bundled = resource_dir.join("sidecar/windeploykit-sidecar.ps1");
        if bundled.is_file() {
            return Ok(bundled);
        }
    }

    anyhow::bail!(
        "could not locate windeploykit-sidecar.ps1 — set STMC_SIDECAR_SCRIPT or place the sidecar next to the app"
    )
}
