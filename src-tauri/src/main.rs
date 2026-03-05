#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::net::TcpStream;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, Instant};

use tauri::{Manager, RunEvent};

struct ServerProcess(Mutex<Option<Child>>);

/// Resolve the bundle-app directory.
/// In a macOS .app bundle: Contents/Resources/bundle-app/
/// In dev: src-tauri/bundle-app/
fn resolve_bundle_dir() -> PathBuf {
    let exe_path = std::env::current_exe().expect("Failed to get current exe path");

    // macOS .app bundle: exe is at Contents/MacOS/Paperclip
    // Resources are at Contents/Resources/
    if let Some(macos_dir) = exe_path.parent() {
        let resources_dir = macos_dir
            .parent() // Contents/
            .map(|p| p.join("Resources").join("bundle-app"));

        if let Some(ref dir) = resources_dir {
            if dir.join("node").exists() {
                return dir.clone();
            }
        }
    }

    // Dev mode: walk up from src-tauri/target/debug to find src-tauri/bundle-app
    let mut dir = exe_path
        .parent()
        .expect("Failed to get exe parent")
        .to_path_buf();
    for _ in 0..10 {
        let candidate = dir.join("bundle-app");
        if candidate.join("node").exists() {
            return candidate;
        }
        // Also check if we're in the project root
        let src_tauri_candidate = dir.join("src-tauri").join("bundle-app");
        if src_tauri_candidate.join("node").exists() {
            return src_tauri_candidate;
        }
        match dir.parent() {
            Some(parent) => dir = parent.to_path_buf(),
            None => break,
        }
    }

    // Last fallback: CWD
    let cwd = std::env::current_dir().expect("Failed to get current dir");
    let candidate = cwd.join("src-tauri").join("bundle-app");
    if candidate.join("node").exists() {
        return candidate;
    }

    eprintln!("ERROR: Could not find bundle-app directory with Node.js binary");
    eprintln!("  Searched from exe: {:?}", exe_path);
    std::process::exit(1);
}

fn spawn_server(bundle_dir: &std::path::Path) -> Child {
    let node_bin = bundle_dir.join("node");
    let app_dir = bundle_dir.join("app");
    let server_entry = app_dir.join("dist").join("index.js");

    // Verify required files
    if !node_bin.exists() {
        eprintln!("Node.js binary not found at {:?}", node_bin);
        std::process::exit(1);
    }
    if !server_entry.exists() {
        eprintln!("Server entry not found at {:?}", server_entry);
        std::process::exit(1);
    }

    // Resolve home directory for data storage
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    let paperclip_home = format!("{home}/.paperclip");

    // Remove env vars that prevent Claude Code agents from running
    // (these are set when Paperclip itself is launched from within a Claude Code session)
    Command::new(&node_bin)
        .arg(&server_entry)
        .env("SERVE_UI", "true")
        .env("PORT", "3100")
        .env("HOST", "127.0.0.1")
        .env("PAPERCLIP_DEPLOYMENT_MODE", "local_trusted")
        .env("PAPERCLIP_DEPLOYMENT_EXPOSURE", "private")
        .env("PAPERCLIP_MIGRATION_AUTO_APPLY", "true")
        .env("PAPERCLIP_HOME", &paperclip_home)
        .env("PAPERCLIP_INSTANCE_ID", "default")
        .env("NODE_ENV", "production")
        .env_remove("CLAUDE_CODE_SSE_PORT")
        .env_remove("CLAUDE_CODE_ENTRYPOINT")
        .env_remove("CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS")
        .env_remove("CLAUDECODE")
        .env_remove("CLAUDE_CODE_SESSION")
        .env_remove("CLAUDE_CODE_TASK_ID")
        .env_remove("CLAUDE_CODE_AGENT_ID")
        .current_dir(&app_dir)
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("Failed to start Node.js server")
}

fn wait_for_server_port(port: u16, timeout: Duration) -> bool {
    let start = Instant::now();
    let addr = format!("127.0.0.1:{}", port);
    while start.elapsed() < timeout {
        if TcpStream::connect(&addr).is_ok() {
            return true;
        }
        thread::sleep(Duration::from_millis(500));
    }
    false
}

fn main() {
    let bundle_dir = resolve_bundle_dir();
    eprintln!("Paperclip bundle dir: {:?}", bundle_dir);

    eprintln!("Starting Paperclip server...");
    let child = spawn_server(&bundle_dir);
    let server_state = ServerProcess(Mutex::new(Some(child)));

    // Wait for server to be ready (up to 90s for first-run: embedded postgres init + migrations)
    if !wait_for_server_port(3100, Duration::from_secs(90)) {
        eprintln!("Server failed to start within 90 seconds");
        if let Some(mut child) = server_state.0.lock().unwrap().take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        std::process::exit(1);
    }

    eprintln!("Server is ready. Opening Paperclip window...");

    let app = tauri::Builder::default()
        .manage(server_state)
        .setup(|app| {
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.navigate("http://localhost:3100".parse().unwrap());
            }
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("Error while building Tauri application");

    app.run(|app_handle, event| {
        if let RunEvent::Exit = event {
            let state = app_handle.state::<ServerProcess>();
            let mut guard = state.0.lock().unwrap();
            if let Some(mut child) = guard.take() {
                drop(guard);
                eprintln!("Shutting down Paperclip server...");
                #[cfg(unix)]
                {
                    unsafe {
                        libc::kill(child.id() as i32, libc::SIGTERM);
                    }
                    let start = Instant::now();
                    loop {
                        match child.try_wait() {
                            Ok(Some(_)) => break,
                            Ok(None) => {
                                if start.elapsed() > Duration::from_secs(10) {
                                    let _ = child.kill();
                                    let _ = child.wait();
                                    break;
                                }
                                thread::sleep(Duration::from_millis(100));
                            }
                            Err(_) => {
                                let _ = child.kill();
                                break;
                            }
                        }
                    }
                }
                #[cfg(not(unix))]
                {
                    let _ = child.kill();
                    let _ = child.wait();
                }
                eprintln!("Server stopped.");
            }
        }
    });
}
