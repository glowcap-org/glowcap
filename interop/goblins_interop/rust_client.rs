//! Live interop proof for the Rust binding: a peer built on pancake's C ABI
//! holds a *keyed* OCapN conversation with a real Spritely Goblins vat over TCP —
//! driven through the *same* `connect`/`enliven`/`send` application surface the
//! cross-language demos use, so what is proven against a real Goblins vat is the
//! application API itself, not a bespoke handshake script.
//!
//! It spawns the conformance Goblins host, learns the echo cap's swiss-num from
//! its NDJSON readiness line, then `connect` (keyed `op:start-session`),
//! `enliven` the echo sturdyref (bootstrap fetch + ADR-0012 dedup), `send` a
//! positional call, then a repeat `enliven` of the same swiss-num. Needs
//! `racket` plus `goblins` on PATH; `zig build rust-goblins-interop`.

use pancake_rust_dogfood::{connect, tcp_locator, Reference};
use tokio::process::Command;

#[path = "../_common/rust/helpers.rs"]
mod helpers;

type Fail = helpers::Fail;

const HOST: &str = "127.0.0.1";
/// The Goblins vat's fixed port; `--port=N` (from
/// `zig build rust-goblins-interop -Dport=N`) moves it when 22096 is taken.
const DEFAULT_PORT: u16 = 22096;
const RACKET: &str = "/usr/local/bin/racket";
const HOST_SCRIPT: &str = "conformance/goblins-peer/racket/goblins-host.rkt";

fn parse_port() -> Result<u16, Fail> {
	helpers::parse_port(DEFAULT_PORT, 65535)
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

	let swiss = helpers::read_swiss(&mut child).await?;
	println!("rust-goblins-interop: goblins published echo swiss={swiss} on {HOST}:{port}");

	// The `Session` is `!Send`, so it lives on a `LocalSet`.
	let local = tokio::task::LocalSet::new();
	let result = local.run_until(converse(swiss, port)).await;
	let _ = child.kill().await;
	result
}

async fn converse(swiss: String, port: u16) -> Result<(), Fail> {
	// `connect` completes the keyed handshake; reaching here means Goblins
	// accepted our signed start-session and we accepted its.
	let conn = connect(&tcp_locator(HOST, port), None, None).await?;
	println!("rust-goblins-interop: session open, keyed start-session accepted by goblins");

	let sturdyref = format!("ocapn://goblins-echo.tcp/s/{swiss}");
	let echo = conn.enliven(&sturdyref).await?;
	println!("rust-goblins-interop: enlivened goblins echo cap, calling it");

	// Goblins invokes a cap positionally (no method symbol), so send with verb "".
	conn.send(&echo, "", &[b"pancake-ping".as_slice().into()])
		.await?;

	let again = conn.enliven(&sturdyref).await?;
	match (echo.reference(), again.reference()) {
		(Reference::Far { id: a, .. }, Reference::Far { id: b, .. }) if a == b => {}
		_ => {
			return Err("repeat enliven did not return the same far import (dedup miss)".into());
		}
	}
	conn.send(&again, "", &[b"pancake-ping-again".as_slice().into()])
		.await?;
	println!("rust-goblins-interop: repeat enliven same import (dedup), second call resolved");

	println!(
		"rust-goblins-interop OK: keyed handshake + enliven/dedup + echo deliver/resolve with live Goblins"
	);
	conn.close();
	Ok(())
}
