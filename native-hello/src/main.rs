//! native-hello: the smallest possible ryra "native" service.
//!
//! No framework, no dependencies. A std-only HTTP server that:
//!   - binds `127.0.0.1:$SERVICE_PORT_HTTP` (networking),
//!   - answers every request with `hello world`,
//!   - appends the visitor + their request headers to `$SERVICE_HOME/data/visits.log` (state).
//!
//! It reads ryra's existing service contract from the environment, so the same
//! binary runs identically whether launched by `cargo run` (standalone) or by a
//! ryra-generated systemd unit (which loads the service's `.env` and sets
//! `SERVICE_HOME`). That's the whole point of starting here: it exercises
//! networking, persistent data, and the compile-and-run pipeline at once.

use std::io::{BufRead, BufReader, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// State directory. ryra hands a service its data dir via `SERVICE_HOME`;
/// standalone (`cargo run`) we fall back to `./` so it works out of the box.
fn data_dir() -> PathBuf {
    let base = std::env::var("SERVICE_HOME").unwrap_or_else(|_| ".".to_string());
    PathBuf::from(base).join("data")
}

/// Listen port. ryra allocates the host port and exposes it as
/// `SERVICE_PORT_HTTP` in the service's `.env`; default 3000 for standalone.
fn port() -> u16 {
    std::env::var("SERVICE_PORT_HTTP")
        .ok()
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(3000)
}

fn main() {
    let dir = data_dir();
    if let Err(e) = std::fs::create_dir_all(&dir) {
        eprintln!("native-hello: cannot create data dir {}: {e}", dir.display());
    }
    let log_path = dir.join("visits.log");

    let port = port();
    let listener = match TcpListener::bind(("127.0.0.1", port)) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("native-hello: cannot bind 127.0.0.1:{port}: {e}");
            std::process::exit(1);
        }
    };
    println!(
        "native-hello listening on http://127.0.0.1:{port}  (visits -> {})",
        log_path.display()
    );

    for conn in listener.incoming() {
        match conn {
            Ok(stream) => {
                let log_path = log_path.clone();
                std::thread::spawn(move || {
                    if let Err(e) = handle(stream, &log_path) {
                        eprintln!("native-hello: connection error: {e}");
                    }
                });
            }
            Err(e) => eprintln!("native-hello: accept error: {e}"),
        }
    }
}

/// Read one HTTP request, log the visitor + headers, reply `hello world`.
fn handle(mut stream: TcpStream, log_path: &Path) -> std::io::Result<()> {
    let peer = stream
        .peer_addr()
        .map(|a| a.to_string())
        .unwrap_or_else(|_| "unknown".to_string());

    let mut reader = BufReader::new(stream.try_clone()?);

    // Request line, e.g. `GET / HTTP/1.1`.
    let mut request_line = String::new();
    reader.read_line(&mut request_line)?;
    let request_line = request_line.trim_end().to_string();

    // Headers up to the blank line that ends them.
    let mut headers = Vec::new();
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line)? == 0 {
            break;
        }
        let line = line.trim_end();
        if line.is_empty() {
            break;
        }
        headers.push(line.to_string());
    }

    append_visit(log_path, &peer, &request_line, &headers);

    let body = "hello world\n";
    let response = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    stream.write_all(response.as_bytes())?;
    stream.flush()
}

/// Append one visit record (timestamp, peer, request line, every header).
fn append_visit(log_path: &Path, peer: &str, request_line: &str, headers: &[String]) {
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    let mut record = format!("[{ts}] {peer} \"{request_line}\"\n");
    for h in headers {
        record.push_str("    ");
        record.push_str(h);
        record.push('\n');
    }

    match std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(log_path)
    {
        Ok(mut f) => {
            let _ = f.write_all(record.as_bytes());
        }
        Err(e) => eprintln!("native-hello: cannot write {}: {e}", log_path.display()),
    }
}
