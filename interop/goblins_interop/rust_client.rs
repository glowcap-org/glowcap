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

use pancake_rust_dogfood::{format_locator_uri, tcp, Argument, ConnectOptions, Runtime, RuntimeConfig};
use tokio::process::Command;

#[path = "../_common/rust/helpers.rs"]
mod helpers;

type Fail = helpers::Fail;

const HOST: &str = "127.0.0.1";
/// The Goblins vat's fixed port; `--port=N` (from
/// `zig build rust-goblins-interop -Dport=N`) moves it when 22096 is taken.
const DEFAULT_PORT: u16 = 22096;
const RACKET: &str = "racket";
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

	let sturdyref_path = helpers::read_sturdyref_path(&mut child).await?;
	println!("rust-goblins-interop: goblins published its echo sturdyref path on {HOST}:{port}");

	// The `Session` is `!Send`, so it lives on a `LocalSet`.
	let local = tokio::task::LocalSet::new();
	let result = match tokio::time::timeout(
		helpers::INTEROP_TIMEOUT,
		local.run_until(converse(sturdyref_path, port)),
	)
	.await
	{
		Ok(result) => result,
		Err(_) => Err("rust-goblins-interop timed out".into()),
	};
	let _ = child.kill().await;
	result
}

async fn converse(sturdyref_path: String, port: u16) -> Result<(), Fail> {
	// `connect` completes the keyed handshake; reaching here means Goblins
	// accepted our signed start-session and we accepted its.
	let locator = tcp::locator(HOST, port);
	let runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())])).await?;
	let session = runtime.connect(&locator, ConnectOptions::default()).await?;
	println!("rust-goblins-interop: session open, keyed start-session accepted by goblins");

	// A sturdyref names a peer, and the enliven checks that peer against the
	// session it rides (ADR-0098). Build it from the very locator this session
	// dialed, so the two cannot drift apart.
	let sturdyref = format!("{}/s/{sturdyref_path}", format_locator_uri(&locator)?);
	let echo = session.enliven(&sturdyref).await?;
	println!("rust-goblins-interop: enlivened goblins echo cap, calling it");

	// Goblins invokes a cap positionally (no method symbol), so send with verb "".
	// The echo actor is `(lambda args args)`: it returns its argument list, so
	// assert the content survived the round-trip (the native driver's bar).
	fn assert_echoed(reply: &Argument, expected: &[u8]) -> Result<(), Box<dyn std::error::Error>> {
		match reply {
			Argument::List(items) if items.len() == 1 => match &items[0] {
				Argument::Bytes(bytes) if bytes == expected => Ok(()),
				other => Err(format!("echo returned {other:?}, expected {expected:?}").into()),
			},
			other => Err(format!("echo reply is not a one-bytes list: {other:?}").into()),
		}
	}
	let reply = session.send(&echo, "", &[b"pancake-ping".as_slice().into()]).await?;
	assert_echoed(&reply, b"pancake-ping")?;

	let again = session.enliven(&sturdyref).await?;
	if echo != again {
		return Err("repeat enliven did not return the same Host identity (dedup miss)".into());
	}
	let reply_again = session
		.send(&again, "", &[b"pancake-ping-again".as_slice().into()])
		.await?;
	assert_echoed(&reply_again, b"pancake-ping-again")?;
	println!("rust-goblins-interop: repeat enliven same Host identity (dedup), second call resolved");

	println!("rust-goblins-interop OK: keyed handshake + enliven/dedup + echo deliver/resolve with live Goblins");
	session.close(pancake_rust_dogfood::PendingWork::Cancel).await?;
	Ok(())
}
