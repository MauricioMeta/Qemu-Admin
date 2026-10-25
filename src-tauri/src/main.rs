// QEMU Admin as a native desktop app — the Eleuther.IO shell.
//
// The application itself is unchanged: a Phoenix/LiveView server. Tauri
// contributes a window and a lifecycle — it starts the bundled Elixir
// release (which carries its own portable QEMU), waits for it to accept
// connections, points a webview at it, and makes sure the BEAM dies when the
// window closes.
//
// One thing differs from Eleuther.IO: closing. The VMs are QEMU processes
// under the BEAM, and killing the tree pulls the plug on every guest. So a
// close request (the title bar's ×, Alt+F4, the taskbar) is handed to the
// page, which asks when VMs are running, shuts them down, and only then
// destroys the window.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::fs::File;
use std::net::{Ipv4Addr, SocketAddrV4, TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use tauri::{Manager, RunEvent, WebviewUrl, WebviewWindowBuilder, WindowEvent};

/// How long the BEAM gets to open its listener before we give up and show
/// the failure instead of a splash that never resolves.
const BOOT_TIMEOUT: Duration = Duration::from_secs(60);

/// The running release, so the exit handler can stop it.
struct Beam(Mutex<Option<Child>>);

/// Whether the page is up, so it can be asked before closing. When it cannot
/// answer (disconnected, hung), the page's own hook destroys the window —
/// see `assets/js/hooks/window_controls.js`.
struct CloseGuard {
    booted: AtomicBool,
}

fn main() {
    tauri::Builder::default()
        .manage(Beam(Mutex::new(None)))
        .manage(CloseGuard {
            booted: AtomicBool::new(false),
        })
        .setup(|app| {
            let handle = app.handle().clone();

            let data_dir = app.path().app_data_dir()?;
            std::fs::create_dir_all(&data_dir)?;

            // No decorations: the app draws its own title bar, in whichever
            // daisyUI theme the user picked (`App.TitleBar`). Dragging and the
            // three buttons come over the IPC — see `capabilities/default.json`.
            let window = WebviewWindowBuilder::new(app, "main", WebviewUrl::App("index.html".into()))
                .title("QEMU Admin")
                .decorations(false)
                // Opens taking the screen; the size is what it restores to.
                .maximized(true)
                .inner_size(1440.0, 900.0)
                .min_inner_size(960.0, 640.0)
                .center()
                .resizable(true)
                .build()?;

            // Booting takes a second or two. Doing it off the main thread
            // keeps the splash painting.
            std::thread::spawn(move || match boot(&handle, &data_dir) {
                Ok(port) => {
                    let url = format!("http://127.0.0.1:{port}/");
                    if let Ok(parsed) = url.parse() {
                        let _ = window.navigate(parsed);
                        handle.state::<CloseGuard>().booted.store(true, Ordering::SeqCst);
                    }
                }
                Err(error) => {
                    eprintln!("QEMU Admin: {error}");
                    show_error(&window, &error, &data_dir);
                }
            });

            Ok(())
        })
        .on_window_event(|window, event| {
            if let WindowEvent::CloseRequested { api, .. } = event {
                let guard = window.state::<CloseGuard>();

                // Before the page is up (splash, boot error) there are no VMs:
                // close straight away.
                if !guard.booted.load(Ordering::SeqCst) {
                    return;
                }

                // The page decides (`window_close` in AdminLive): it answers
                // by destroying the window, which does not come back here.
                api.prevent_close();
                if let Some(webview) = window.app_handle().get_webview_window(window.label()) {
                    let _ = webview.eval("window.dispatchEvent(new Event('qa:close-requested'))");
                }
            }
        })
        .build(tauri::generate_context!())
        .expect("erro ao inicializar a janela")
        .run(|app, event| {
            // Closing the window takes the BEAM with it — and the QEMU
            // processes under it, which by now the page has shut down.
            if let RunEvent::Exit = event {
                if let Some(mut child) = app.state::<Beam>().0.lock().unwrap().take() {
                    stop(&mut child);
                }
            }
        });
}

/// Starts the release and blocks until it answers, returning its port.
fn boot(app: &tauri::AppHandle, data_dir: &Path) -> Result<u16, String> {
    let release = release_dir(app)?;
    let launcher = launcher(&release)?;
    let port = free_port().map_err(|e| format!("nenhuma porta livre disponível: {e}"))?;

    let log_path = data_dir.join("server.log");
    let log = File::create(&log_path)
        .map_err(|e| format!("não foi possível escrever {}: {e}", log_path.display()))?;
    let errors = log
        .try_clone()
        .map_err(|e| format!("não foi possível duplicar o log: {e}"))?;

    let mut command = build_command(&launcher);
    command
        .current_dir(&release)
        .env("PORT", port.to_string())
        .env("QEMU_ADMIN_DATA_DIR", data_dir)
        // Tells the app it is inside this window and not a browser tab: the
        // title bar and the close guard.
        .env("QEMU_ADMIN_DESKTOP", "1")
        // The release writes its resolved runtime config under RELEASE_TMP;
        // the installed release's own folder is not writable.
        .env("RELEASE_TMP", data_dir.join("tmp"))
        // No clustering, and no epmd in the process tree.
        .env("RELEASE_DISTRIBUTION", "none")
        .stdin(Stdio::null())
        .stdout(Stdio::from(log))
        .stderr(Stdio::from(errors));

    let child = command
        .spawn()
        .map_err(|e| format!("falha ao iniciar {}: {e}", launcher.display()))?;

    *app.state::<Beam>().0.lock().unwrap() = Some(child);

    wait_for_port(port, app)?;
    Ok(port)
}

/// Polls the port until the endpoint accepts a connection, failing early if
/// the release exits first.
fn wait_for_port(port: u16, app: &tauri::AppHandle) -> Result<(), String> {
    let address = SocketAddrV4::new(Ipv4Addr::LOCALHOST, port);
    let deadline = Instant::now() + BOOT_TIMEOUT;

    while Instant::now() < deadline {
        if TcpStream::connect_timeout(&address.into(), Duration::from_millis(500)).is_ok() {
            return Ok(());
        }

        if let Some(child) = app.state::<Beam>().0.lock().unwrap().as_mut() {
            match child.try_wait() {
                Ok(Some(status)) => {
                    return Err(format!("o servidor encerrou durante a inicialização ({status})"))
                }
                Ok(None) => {}
                Err(e) => return Err(format!("não foi possível monitorar o servidor: {e}")),
            }
        }

        std::thread::sleep(Duration::from_millis(120));
    }

    Err(format!("o servidor não respondeu em {}s", BOOT_TIMEOUT.as_secs()))
}

/// Asks the OS for a free port and immediately gives it back. A fixed port
/// would collide with another copy of the app and with the dev server.
fn free_port() -> std::io::Result<u16> {
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0))?;
    let port = listener.local_addr()?.port();
    drop(listener);
    Ok(port)
}

/// Where the bundled release lives. Falls back to the staging folder so
/// `cargo run` works without bundling.
fn release_dir(app: &tauri::AppHandle) -> Result<PathBuf, String> {
    if let Ok(dir) = std::env::var("QEMU_ADMIN_REL_DIR") {
        let path = PathBuf::from(dir);
        if path.is_dir() {
            return Ok(path);
        }
    }

    if let Ok(resources) = app.path().resource_dir() {
        let bundled = simplify(resources.join("rel"));
        if bundled.is_dir() {
            return Ok(bundled);
        }
    }

    let local = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("resources").join("rel");
    if local.is_dir() {
        return Ok(local);
    }

    Err("release do Elixir não encontrada — rode `mix desktop.stage` antes de compilar".to_string())
}

/// Drops Windows' `\\?\` verbatim prefix: `cmd.exe`, which the release
/// script goes through, does not accept it.
#[cfg(windows)]
fn simplify(path: PathBuf) -> PathBuf {
    let text = path.to_string_lossy();

    match text.strip_prefix(r"\\?\") {
        Some(rest) if rest.starts_with("UNC\\") => PathBuf::from(format!(r"\\{}", &rest[4..])),
        Some(rest) => PathBuf::from(rest),
        None => path,
    }
}

#[cfg(not(windows))]
fn simplify(path: PathBuf) -> PathBuf {
    path
}

/// The release's start script for this platform.
fn launcher(release: &Path) -> Result<PathBuf, String> {
    let name = if cfg!(windows) { "qemu_admin.bat" } else { "qemu_admin" };

    let path = release.join("bin").join(name);
    if path.is_file() {
        Ok(path)
    } else {
        Err(format!("{} não existe", path.display()))
    }
}

#[cfg(windows)]
fn build_command(launcher: &Path) -> Command {
    use std::os::windows::process::CommandExt;

    // The release entry point is a batch file, so it goes through cmd.
    // CREATE_NO_WINDOW keeps a console from flashing next to the app — and
    // QEMU, started by the BEAM, inherits that hidden console.
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;

    let mut command = Command::new("cmd");
    command
        .args(["/C", &launcher.to_string_lossy(), "start"])
        .creation_flags(CREATE_NO_WINDOW);
    command
}

#[cfg(not(windows))]
fn build_command(launcher: &Path) -> Command {
    let mut command = Command::new(launcher);
    command.arg("start");
    command
}

#[cfg(windows)]
fn stop(child: &mut Child) {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;

    // Killing the child only kills cmd.exe — the BEAM (and the QEMUs under
    // it) are grandchildren. taskkill /T takes the whole tree.
    let killed = Command::new("taskkill")
        .args(["/T", "/F", "/PID", &child.id().to_string()])
        .creation_flags(CREATE_NO_WINDOW)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();

    if killed.is_err() {
        let _ = child.kill();
    }

    let _ = child.wait();
}

#[cfg(not(windows))]
fn stop(child: &mut Child) {
    let _ = child.kill();
    let _ = child.wait();
}

/// Replaces the splash with what went wrong, plus where to read the log. It
/// writes into `#app`, not the body: the body also holds the title bar, the
/// only way left to close an undecorated window that failed to boot.
fn show_error(window: &tauri::WebviewWindow, error: &str, data_dir: &Path) {
    let log = data_dir.join("server.log");
    let script = format!(
        r#"
        var target = document.getElementById('app') || document.body;
        target.innerHTML = {};
        target.style.padding = '2rem';
        target.style.textAlign = 'center';
        "#,
        serde_json::to_string(&format!(
            "<h1 style=\"color:#ff6b6b;letter-spacing:.1em\">Falha ao iniciar</h1>\
             <p style=\"color:rgba(255,240,228,.7)\">{}</p>\
             <p style=\"color:rgba(255,240,228,.35);font-size:.7rem\">Detalhes em {}</p>",
            html_escape(error),
            html_escape(&log.display().to_string())
        ))
        .unwrap_or_else(|_| "\"Falha ao iniciar\"".to_string())
    );

    let _ = window.eval(&script);
}

fn html_escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}
