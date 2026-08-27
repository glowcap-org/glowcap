//! Live iroh scale proof for the Rust binding: many concurrent connections
//! served from one readiness loop (ADR-0057), the Rust sibling of the Zig
//! `zig build iroh-loop` gate.
//!
//! The iroh netlayer has one I/O model — an event-driven readiness loop. This
//! gate proves it through the binding: one [`Server`] runs a single readiness
//! loop (an `AsyncFd` over the endpoint's readiness fd, ADR-0057) and serves
//! every accepted connection's peer from the one tokio current-thread runtime.
//! Many clients dial it at once, each over its own iroh endpoint, fetch the
//! published greeter, and call it several times. Every reply must come back
//! correct — so the one server loop is provably multiplexing all the connections
//! at once.
//!
//! It exercises the whole loop surface live through the binding: the readiness
//! fd, the records `drain_ready` returns, non-blocking `try_accept`, and
//! `try_read` / `try_write` with their `WOULD_BLOCK` re-arming. Teardown is
//! non-blocking by construction — no parked read races a release.
//!
//! Needs `cargo` plus the iroh ABI companion library (`zig build iroh-abi`); run
//! via `zig build rust-iroh-loop`.

use std::rc::Rc;

use pancake_rust_dogfood::iroh::Reachability;
use pancake_rust_dogfood::iroh::Stream;
use pancake_rust_dogfood::{iroh, Argument, ConnectOptions, PendingWork, Runtime, RuntimeConfig, Session};
use tokio::io::AsyncWriteExt;

#[path = "../../../interop/_common/rust/helpers.rs"]
mod helpers;

type Fail = helpers::Fail;

// Concurrent connections, each served on the one server loop; calls each makes
// before closing. Mirrors the Zig iroh-loop gate.
const NUM_CONNS: usize = 16;
const CALLS_PER_CONN: usize = 4;
const GREETING: &str = "hello over the iroh loop";

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Fail> {
	helpers::ignore_port_args()?;
	// The `Session` driver is `!Send`, so it lives on a `LocalSet`.
	let local = tokio::task::LocalSet::new();
	local.run_until(run()).await
}

async fn run() -> Result<(), Fail> {
	let server = Rc::new(
		iroh::listen(
			iroh::Config::new(Reachability::LocalDiscovery),
			iroh::ListenOptions::default(),
		)
		.await?,
	);
	let server_id = server.node_id().to_string();
	println!("rust-iroh-loop: server endpoint id {server_id}");

	// Accept every dial, publish this connection's greeter, and keep its driver
	// alive, all served from the server's one readiness loop.
	let accept_server = Rc::clone(&server);
	let accept_task = tokio::task::spawn_local(async move {
		let mut served: Vec<Session> = Vec::new();
		while let Ok(session) = accept_server.accept().await {
			if session.publish("greeter", greeter).is_err() {
				continue;
			}
			served.push(session);
		}
		served // hold the connections (and their drivers) until the loop ends
	});

	// A valid but incomplete outer frame occupies one handshake lane. Later
	// clients must still complete before that lane's handshake timeout expires.
	let mut silent = Stream::connect(&server_id, "", Reachability::LocalDiscovery).await?;
	silent.write_all(b"1").await?;

	// Fan out all clients at once: they share nothing, so the only thing that can
	// serve them all is the one server loop multiplexing.
	let mut clients = Vec::new();
	for _ in 0..NUM_CONNS {
		let id = server_id.clone();
		clients.push(tokio::task::spawn_local(client_once(id)));
	}

	let mut failures = 0usize;
	for c in clients {
		match c.await {
			Ok(Ok(())) => {}
			Ok(Err(e)) => {
				eprintln!("rust-iroh-loop: a client failed: {e}");
				failures += 1;
			}
			Err(e) => {
				eprintln!("rust-iroh-loop: a client task panicked: {e}");
				failures += 1;
			}
		}
	}
	drop(silent);

	// Bring the server (and its readiness loop) down so the accept task ends and
	// the gate never hangs.
	server.close().await?;
	let _ = accept_task.await;

	if failures > 0 {
		return Err(format!("{failures}/{NUM_CONNS} client(s) failed").into());
	}

	// Host teardown owns admission on every transport. A task parked on iroh's
	// reactor must wake terminally rather than retaining the endpoint.
	let closing = Rc::new(
		iroh::listen(
			iroh::Config::new(Reachability::LocalDiscovery),
			iroh::ListenOptions::default(),
		)
		.await?,
	);
	let accept_server = Rc::clone(&closing);
	let pending_accept = tokio::task::spawn_local(async move { accept_server.accept().await });
	tokio::task::yield_now().await;
	closing.host().close(PendingWork::Cancel).await?;
	let closed_accept = tokio::time::timeout(std::time::Duration::from_secs(2), pending_accept)
		.await
		.map_err(|_| "Host release did not wake iroh accept")??;
	if closed_accept.is_ok() {
		return Err("a released Host admitted an iroh session".into());
	}
	closing.close().await?;

	println!(
		"rust-iroh-loop: OK, {NUM_CONNS} concurrent iroh connections, {CALLS_PER_CONN} calls each, \
         served from one loop over the readiness fd + non-blocking frame I/O"
	);
	Ok(())
}

// The published actor: answer `greet` with a static greeting.
fn greeter(verb: &str, _args: &[Argument]) -> Result<Argument, String> {
	if verb == "greet" {
		Ok(GREETING.into())
	} else {
		Err(format!("no such method: {verb}"))
	}
}

// One client: bind its own iroh endpoint, dial the server by id alone (the
// local-discovery book resolves it), fetch the greeter, and call it
// `CALLS_PER_CONN` times, checking every reply.
async fn client_once(server_id: String) -> Result<(), Fail> {
	let locator = pancake_rust_dogfood::iroh::locator(&server_id, None);
	let runtime = Runtime::open(RuntimeConfig::providers([iroh::provider(iroh::Config::new(
		Reachability::LocalDiscovery,
	))]))
	.await?;
	let session = runtime.connect(&locator, ConnectOptions::default()).await?;
	let greeter = session.fetch("greeter").await?;
	for _ in 0..CALLS_PER_CONN {
		let reply = session
			.send(&greeter, "greet", &[Argument::String("world".into())])
			.await?;
		if reply.as_str() != Some(GREETING) {
			return Err(format!("wrong reply: {reply:?}").into());
		}
	}
	session.close(PendingWork::Cancel).await?;
	Ok(())
}
