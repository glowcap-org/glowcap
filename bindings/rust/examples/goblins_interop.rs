//! Live interop proof for the Rust binding: a peer built on `libpancake`'s C ABI
//! holds a *keyed* OCapN conversation with a real Spritely Goblins vat over TCP —
//! driven through the *same* `connect`/`fetch`/`send` application surface the
//! cross-language demos use, so what is proven against a real Goblins vat is the
//! application API itself, not a bespoke handshake script.
//!
//! It spawns the conformance Goblins host, learns the echo cap's swiss-num from
//! its NDJSON readiness line, then `connect` (which completes the keyed
//! `op:start-session` handshake), `fetch` the echo cap, and `send` it a
//! positional call — asserting Goblins resolves it. Needs `racket` plus the
//! `goblins` collection on PATH; run via `zig build rust-goblins-interop`.

use std::time::Duration;

use pancake_rust_dogfood::{connect, Argument};
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::{Child, Command};

const HOST: &str = "127.0.0.1";
/// The Goblins vat's fixed port; `--port=N` (from
/// `zig build rust-goblins-interop -Dport=N`) moves it when 22096 is taken.
const DEFAULT_PORT: u16 = 22096;
const RACKET: &str = "/usr/local/bin/racket";
const HOST_SCRIPT: &str = "conformance/goblins-peer/racket/goblins-host.rkt";

type Fail = Box<dyn std::error::Error>;

fn parse_port() -> Result<u16, Fail> {
    let mut port = DEFAULT_PORT;
    for arg in std::env::args().skip(1) {
        match arg.strip_prefix("--port=") {
            Some(text) => port = text.parse()?,
            None => return Err(format!("unknown argument '{arg}'").into()),
        }
    }
    Ok(port)
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Fail> {
    let port = parse_port()?;
    let mut child = Command::new(RACKET)
        .args([HOST_SCRIPT, HOST, &port.to_string()])
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true)
        .spawn()?;

    let swiss = read_swiss(&mut child).await?;
    println!("rust-goblins-interop: goblins published echo swiss={swiss} on {HOST}:{port}");

    // The `Connection` is `!Send`, so it lives on a `LocalSet`.
    let local = tokio::task::LocalSet::new();
    let result = local.run_until(converse(swiss, port)).await;
    let _ = child.kill().await;
    result
}

async fn converse(swiss: String, port: u16) -> Result<(), Fail> {
    // `connect` completes the keyed handshake; reaching the fetch means Goblins
    // accepted our signed start-session and we accepted its.
    let conn = connect((HOST, port)).await?;
    println!("rust-goblins-interop: session open, keyed start-session accepted by goblins");

    let echo = conn.fetch(&swiss).await?;
    println!("rust-goblins-interop: fetched goblins echo cap, calling it");

    // Goblins invokes a cap positionally (no method symbol), so send with verb "".
    conn.send(&echo, "", &[Argument::Bytes(b"pancake-ping".to_vec())]).await?;

    println!(
        "rust-goblins-interop OK: keyed handshake + bootstrap fetch + echo deliver/resolve with live Goblins"
    );
    conn.close();
    Ok(())
}

async fn read_swiss(child: &mut Child) -> Result<String, Fail> {
    let stdout = child.stdout.take().ok_or("no child stdout")?;
    let mut lines = BufReader::new(stdout).lines();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    loop {
        match tokio::time::timeout_at(deadline, lines.next_line()).await?? {
            Some(line) => {
                if let Some(swiss) = extract_swiss(&line) {
                    return Ok(swiss);
                }
            }
            None => return Err("goblins exited before publishing the echo cap".into()),
        }
    }
}

fn extract_swiss(line: &str) -> Option<String> {
    let needle = "\"swiss\":\"";
    let start = line.find(needle)? + needle.len();
    let rest = &line[start..];
    let end = rest.find('"')?;
    Some(rest[..end].to_string())
}
