//! Live three-party handoff with the Rust binding as the GIFTER (the
//! introducer), proving pancake can mint a `desc:handoff-give` that live Goblins
//! redeems and a `deposit-gift` that live Goblins accepts — the exporter half of
//! ADR-0009 against a real cross-implementation peer, the mirror of
//! `rust-goblins-handoff` (where pancake is the recipient).
//!
//! Topology (all TCP loopback):
//!   Bob    (Goblins exporter)  hosts a greeter behind a swiss; long-lived.
//!   Gifter (pancake)           fetches Bob's greeter, publishes an "introducer"
//!                              that returns it, and listens for the recipient.
//!   Carol  (Goblins recipient) dials the pancake introducer, asks for the
//!                              greeter, transparently redeems pancake's give, and
//!                              calls the greeter directly on Bob.
//!
//! pancake is the gifter: when Carol asks for the greeter, returning Bob's
//! greeter (whose home is the gifter↔Bob connection) on Carol's connection trips
//! the transparent gifter — it deposits the greeter back with Bob over its own
//! Bob connection and resolves Carol's send with a signed give. One node identity
//! (`gifter.host()`) serves both the recipient and the exporter connection, so
//! the give's signature matches the deposit. Goblins Bob must accept the deposit;
//! Goblins Carol must redeem the give and reach Bob directly. The proof is
//! Carol's `GIFT OK` line carrying the greeter's reply with the name she sent.
//!
//! Needs `racket` plus the `goblins` collection on PATH; run via
//! `zig build rust-goblins-gift`.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use pancake_rust_dogfood::{
	connect, listen, socket_addr_designator, tcp_locator, Argument, Session,
};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, BufReader};
use tokio::process::{Child, ChildStdout, Command};

#[path = "../_common/rust/helpers.rs"]
mod helpers;

type Fail = helpers::Fail;

const HOST: &str = "127.0.0.1";
/// Bob (the Goblins exporter) listens on PORT; Carol binds her own peer on
/// PORT+1. pancake (the gifter) takes an ephemeral port, the recipient learns it
/// at spawn time. `--port=N` (from `zig build rust-goblins-gift -Dport=N`) moves
/// the pair when 22124 is taken.
const DEFAULT_PORT: u16 = 22124;
const RACKET: &str = "/usr/local/bin/racket";
const EXPORTER_SCRIPT: &str = "conformance/goblins-peer/racket/gift-exporter-host.rkt";
const RECIPIENT_SCRIPT: &str = "conformance/goblins-peer/racket/gift-recipient.rkt";
// pancake hardcodes the same swiss the exporter host registers, the way the
// interop clients fix the echo swiss.
const GREETER_SWISS: &str = "pancakeGiftGreeterSwissnum000001";
const INTRODUCER_SWISS: &str = "introducer";

fn parse_port() -> Result<u16, Fail> {
	helpers::parse_port(DEFAULT_PORT, 65534)
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Fail> {
	let port = parse_port()?;

	// Spawn Bob (the Goblins exporter) and wait for its readiness NDJSON.
	let mut bob = Command::new(RACKET)
		.args([EXPORTER_SCRIPT, HOST, &port.to_string()])
		.stdout(std::process::Stdio::piped())
		.stderr(std::process::Stdio::piped())
		.kill_on_drop(true)
		.spawn()?;

	// Drain Bob's stderr in the background. A piped child stream that is never
	// read deadlocks the child once its OS pipe fills, Goblins logs to stderr
	// during operation, so leaving it undrained stalls the deposit and the whole
	// handoff times out. The captured text is printed only on failure.
	let bob_stderr = Arc::new(Mutex::new(Vec::<u8>::new()));
	if let Some(mut stderr) = bob.stderr.take() {
		let sink = Arc::clone(&bob_stderr);
		tokio::spawn(async move {
			let mut buf = [0u8; 4096];
			while let Ok(n) = stderr.read(&mut buf).await {
				if n == 0 {
					break;
				}
				sink.lock()
					.expect("bob stderr buffer is not poisoned")
					.extend_from_slice(&buf[..n]);
			}
		});
	}

	let stdout = bob.stdout.take().ok_or("no exporter stdout")?;
	let mut reader = BufReader::new(stdout);
	helpers::await_greeter_ready(&mut reader).await?;
	// Keep draining Bob's stdout for the rest of the run, same pipe-deadlock
	// guard the stderr drain gives.
	drain_in_background(reader);
	println!(
		"rust-goblins-gift: goblins-bob exporting greeter swiss={GREETER_SWISS} on {HOST}:{port}"
	);

	// The `Session`/`Server` are `!Send`, so the gifter runs on a `LocalSet`.
	let local = tokio::task::LocalSet::new();
	let result = local.run_until(gift(port)).await;

	let _ = bob.kill().await;
	if result.is_err() {
		let err = String::from_utf8_lossy(
			&bob_stderr
				.lock()
				.expect("bob stderr buffer is not poisoned"),
		)
		.trim()
		.to_string();
		if !err.is_empty() {
			eprintln!("rust-goblins-gift: exporter stderr:\n{err}");
		}
	}
	result
}

async fn gift(port: u16) -> Result<(), Fail> {
	// pancake (the gifter) listens for the recipient on an ephemeral port. One
	// node identity serves both the recipient connection and the exporter
	// connection, so the give's signature matches the deposit.
	let server = listen((HOST, 0)).await?;
	let gifter_port = server.local_addr()?.port();
	let host = server.host();

	// Run the accept loop, retaining every accepted connection: dropping a
	// `Session` closes it, so the recipient's connection must be held for the
	// duration of the handoff.
	tokio::task::spawn_local(async move {
		let mut held: Vec<Session> = Vec::new();
		while let Ok(conn) = server.accept().await {
			held.push(conn);
		}
	});

	// Dial Bob and fetch his greeter, sharing the gifter's node identity. The
	// fetched ref's home is this gifter↔Bob connection, which is what lets
	// pancake re-gift it across to the recipient.
	let to_bob = connect(&tcp_locator(HOST, port), None, Some(host.clone())).await?;
	let greeter = to_bob.fetch(GREETER_SWISS).await?;
	println!("rust-goblins-gift: fetched goblins-bob's greeter");

	// Publish the introducer Host-wide. Returning Bob's greeter (home = the Bob
	// session) to the recipient's session trips the transparent gifter,
	// which deposits with Bob and resolves the recipient with a signed give. The
	// giftable is a factory because an actor behavior is a `!Clone` `FnMut`: each
	// session it is published on gets a freshly minted behavior with the same
	// logic, all returning the one greeter.
	host.publish_giftable(INTRODUCER_SWISS, move || {
		let greeter = greeter.clone();
		Box::new(move |verb: &str, _args: &[Argument]| {
			if verb == "get-greeter" {
				Ok(Argument::from(&greeter))
			} else {
				Err(format!("introducer: no such verb {verb:?}"))
			}
		})
	});
	println!("rust-goblins-gift: pancake publishing introducer swiss={INTRODUCER_SWISS} on {HOST}:{gifter_port}");

	// Spawn Carol (the Goblins recipient): she dials pancake's introducer, asks
	// for the greeter, redeems pancake's give, and calls Bob directly.
	let mut carol = Command::new(RACKET)
		.args([
			RECIPIENT_SCRIPT,
			&socket_addr_designator(HOST, gifter_port),
			INTRODUCER_SWISS,
			&(port + 1).to_string(),
		])
		.stdout(std::process::Stdio::piped())
		.stderr(std::process::Stdio::piped())
		.kill_on_drop(true)
		.spawn()?;

	let output = tokio::time::timeout(Duration::from_secs(60), carol_output(&mut carol))
		.await
		.map_err(|_| "recipient did not finish within 60s")??;
	let reply = String::from_utf8_lossy(&output.0).trim().to_string();
	let carol_err = String::from_utf8_lossy(&output.1).trim().to_string();
	if !reply.is_empty() {
		println!("rust-goblins-gift: {reply}");
	}
	if !output.2 {
		return Err(format!(
			"recipient exited non-zero{}",
			if carol_err.is_empty() {
				String::new()
			} else {
				format!("; stderr:\n{carol_err}")
			}
		)
		.into());
	}
	if !reply.starts_with("GIFT OK:") || !reply.contains("goblins-carol") {
		return Err(format!(
			"recipient did not confirm the greeter reply with its name: {reply:?}"
		)
		.into());
	}

	println!(
        "rust-goblins-gift OK: pancake minted a three-party handoff give that live Goblins redeemed, \
         reaching the exporter directly"
    );
	to_bob.close();
	Ok(())
}

// Keep emptying a child stream to the end so its OS pipe never fills (which would
// deadlock the child). Discards the bytes; the run only needs the readiness line.
fn drain_in_background(mut reader: BufReader<ChildStdout>) {
	tokio::spawn(async move {
		let mut sink = String::new();
		loop {
			sink.clear();
			match reader.read_line(&mut sink).await {
				Ok(0) | Err(_) => break,
				Ok(_) => {}
			}
		}
	});
}

// Wait for Carol and collect her output: (stdout, stderr, success). Reads both
// pipes concurrently with the wait so neither pipe deadlocks the child.
async fn carol_output(carol: &mut Child) -> Result<(Vec<u8>, Vec<u8>, bool), Fail> {
	let mut stdout = carol.stdout.take().ok_or("no recipient stdout")?;
	let mut stderr = carol.stderr.take().ok_or("no recipient stderr")?;
	let mut out = Vec::new();
	let mut err = Vec::new();
	let (status, _, _) = tokio::join!(
		carol.wait(),
		stdout.read_to_end(&mut out),
		stderr.read_to_end(&mut err)
	);
	Ok((out, err, status?.success()))
}
