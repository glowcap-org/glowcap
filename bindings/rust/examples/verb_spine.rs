//! The Rust half of the verb-spine proof family: one process that walks the
//! promise, dial, listen, and GC verbs against the fixed peer and prints one
//! `VERB-SPINE <marker>` line per scene. `bindings/proofs/verb_spine/harness.ts`
//! owns the marker contract and the two locators it appends to argv. Read its
//! header before changing anything here.
//!
//! Two of that contract's clauses land differently in Rust than they do in a
//! dynamically typed binding, so this client says how it satisfies each.
//!
//! `Session::send` returns a `RemotePromise` by signature, so the escape this
//! family exists for, a promise-returning send that raises instead, cannot be
//! spelled as a returned error here. A panic is the one way the call could
//! still refuse synchronously, so every send whose scene expects a failure runs
//! inside `catch_unwind` and the scene fails if the call unwinds.
//!
//! `Session::release` takes its capability by value, which is the shape the
//! contract lets a binding satisfy the GC arm by construction. It does not
//! apply here: `Ref` is `Clone` and release state is shared across the clones,
//! so a spent capability is still nameable. This client therefore runs the full
//! arm, requiring both that a second release is refused and that a send through
//! the spent handle settles as a failure.
//!
//! Run via `zig build rust-verb-spine`.

use std::panic::AssertUnwindSafe;
use std::rc::Rc;
use std::time::Duration;

use glowcap::{
	Argument, ConnectOptions, Error, PendingWork, Ref, RemotePromise, Runtime, RuntimeConfig, Session, parse_locator,
	tcp,
};
use tokio::task::LocalSet;

/// How long the accepted half of the listen scene has to finish serving after
/// the dialing half closes. The harness owns the proof's own deadline. This one
/// keeps a stalled serve loop reported as the scene that stalled rather than as
/// a silent 25-second timeout with no marker.
const SERVE_TIMEOUT: Duration = Duration::from_secs(5);

fn fail(message: String) -> ! {
	eprintln!("FAIL: {message}");
	std::process::exit(1);
}

fn mark(marker: &str, detail: &str) {
	let detail = detail.replace(['\n', '\r'], " ");
	if detail.is_empty() {
		println!("VERB-SPINE {marker}");
	} else {
		println!("VERB-SPINE {marker} {detail}");
	}
}

fn expect_string(what: &str, actual: &Argument, wanted: &str) {
	match actual.as_str() {
		Some(text) if text == wanted => {}
		_ => fail(format!("{what}: expected {wanted:?}, got {actual:?}")),
	}
}

/// Await a handle for the value the scene wants, failing the scene on a break.
async fn value(what: &str, handle: RemotePromise) -> Argument {
	match handle.await {
		Ok(argument) => argument,
		Err(error) => fail(format!("{what}: {error}")),
	}
}

/// Whether a handle settled with a value. Every call site here expects a
/// reported failure, so the failure is consumed rather than propagated.
async fn settles(handle: RemotePromise) -> bool {
	handle.await.is_ok()
}

/// Send, and require that the call itself hands back a handle. The return type
/// already rules out an error, so what this guards is the remaining synchronous
/// refusal a promise-returning verb must not make: an unwind at the call.
fn send_handle(from: &Session, target: &Ref, verb: &str, args: &[Argument], what: &str) -> RemotePromise {
	match std::panic::catch_unwind(AssertUnwindSafe(|| from.send(target, verb, args))) {
		Ok(handle) => handle,
		Err(_) => fail(format!("{what}: send panicked instead of returning a handle")),
	}
}

fn expect(what: &str, outcome: Result<(), Error>) {
	if let Err(error) = outcome {
		fail(format!("{what}: {error}"));
	}
}

fn expect_value<T>(what: &str, outcome: Result<T, Error>) -> T {
	match outcome {
		Ok(value) => value,
		Err(error) => fail(format!("{what}: {error}")),
	}
}

/// Publish `echo` on the first session this listener accepts, and serve it
/// until the partner closes.
async fn serve_once(listener: Rc<tcp::Server>) -> Result<(), Error> {
	let served = listener.accept().await?;
	served.publish("echo", |verb, args| {
		if verb != "echo" {
			return Err(format!("echo has no verb {verb}"));
		}
		Ok(args.first().and_then(Argument::as_str).unwrap_or("?").into())
	})?;
	served.serve().await
}

async fn walk(peer_uri: String, dead_uri: String) {
	let runtime = expect_value(
		"open a runtime over the TCP provider",
		Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())])).await,
	);

	// ── dial-ok ─────────────────────────────────────────────────────────────
	let partner = expect_value("parse the peer locator", parse_locator(&peer_uri));
	let session = expect_value(
		"dial the peer",
		runtime.connect(&partner, ConnectOptions::default()).await,
	);
	let spine = expect_value("fetch spine", session.fetch("spine").await);
	mark("dial-ok", &peer_uri);

	// ── promise-handle ──────────────────────────────────────────────────────
	let greeted = value(
		"greet",
		send_handle(&session, &spine, "greet", &["spine".into()], "greet"),
	)
	.await;
	expect_string("greet", &greeted, "hello, spine");
	mark("promise-handle", "");

	// ── promise-index / promise-untag / promise-get ─────────────────────────
	// Each projection is issued at the unsettled answer, before anything awaits
	// it: that is what makes a dependent read one round trip rather than two.
	let listing = session.send(&spine, "list", &[]);
	let second_element = listing.index(1);
	expect_string("list index 1", &value("list index 1", second_element).await, "beta");
	mark("promise-index", "");

	let boxed = session.send(&spine, "boxed", &[]);
	let cell_tail = boxed.untag("cell").index(1);
	expect_string(
		"boxed untag then index 1",
		&value("boxed untag then index 1", cell_tail).await,
		"cell-1",
	);
	mark("promise-untag", "");

	let record = session.send(&spine, "record", &[]);
	let record_name = record.get("name");
	expect_string(
		"record field name",
		&value("record field name", record_name).await,
		"spine-record",
	);
	mark("promise-get", "");

	// ── gc-released ─────────────────────────────────────────────────────────
	let minted_reply = value("mint", session.send(&spine, "mint", &[])).await;
	let minted = match Ref::try_from(&minted_reply) {
		Ok(capability) => capability,
		Err(()) => fail(format!("mint did not answer with a capability: {minted_reply:?}")),
	};
	expect_string(
		"minted ping",
		&value("minted ping", session.send(&minted, "ping", &[])).await,
		"pong",
	);
	// The clone is what keeps the released capability nameable after the move,
	// so the two refusals below are behavior rather than a type-system carve-out.
	let spent = minted.clone();
	expect("release the minted capability", session.release(minted));
	if session.release(spent.clone()).is_ok() {
		fail("releasing a spent capability twice was accepted".to_string());
	}
	let through_spent = send_handle(&session, &spent, "ping", &[], "send through a released capability");
	if settles(through_spent).await {
		fail("a send through a released capability was answered".to_string());
	}
	mark("gc-released", "");

	// ── promise-failed ──────────────────────────────────────────────────────
	// The documented escape, as behavior: a send that could never be issued
	// comes back as a settled failure, never as a refusal at the call.
	expect("close the peer session", session.close(PendingWork::Cancel).await);
	let ghost = send_handle(&session, &spine, "greet", &["ghost".into()], "send on a closed session");
	if settles(ghost).await {
		fail("a send on a closed session was answered".to_string());
	}
	mark("promise-failed", "");

	// ── listen-served ───────────────────────────────────────────────────────
	let server = Rc::new(expect_value(
		"open a TCP listener",
		tcp::listen("127.0.0.1", 0, tcp::ListenOptions::default()).await,
	));
	// A closed listener has no locator to read, so name it while it lives.
	let own_uri = expect_value("read the listener locator", server.uri());
	let own_locator = expect_value("read the listener locator", server.locator());
	let serving = tokio::task::spawn_local(serve_once(Rc::clone(&server)));
	let own = expect_value(
		"dial this process's own listener",
		runtime.connect(&own_locator, ConnectOptions::default()).await,
	);
	let echo = expect_value("fetch echo", own.fetch("echo").await);
	expect_string(
		"own listener echo",
		&value("own listener echo", own.send(&echo, "echo", &["heard".into()])).await,
		"heard",
	);
	expect("close the dialed half", own.close(PendingWork::Cancel).await);
	match tokio::time::timeout(SERVE_TIMEOUT, serving).await {
		Ok(Ok(outcome)) => expect("serve the accepted session", outcome),
		Ok(Err(joined)) => fail(format!("the serve task failed: {joined}")),
		Err(_) => fail(format!(
			"the accepted session was still serving {}s after the dialed half closed",
			SERVE_TIMEOUT.as_secs()
		)),
	}
	expect("close the listener", server.close().await);
	mark("listen-served", &own_uri);

	// ── dial-refused ────────────────────────────────────────────────────────
	let dead = expect_value("parse the dead locator", parse_locator(&dead_uri));
	match runtime.connect(&dead, ConnectOptions::default()).await {
		Ok(stray) => {
			let _ = stray.close(PendingWork::Cancel).await;
			fail(format!(
				"dialing {dead_uri} opened a session; nothing is listening there"
			));
		}
		Err(refusal) => mark("dial-refused", &refusal.to_string()),
	}

	expect("close the runtime", runtime.close(PendingWork::Cancel).await);
	mark("ok", "");
}

fn main() {
	// The harness appends the two locators; anything before them belongs to
	// whoever launched this client.
	let args: Vec<String> = std::env::args().collect();
	if args.len() < 3 {
		eprintln!("usage: verb_spine <peerUri> <deadUri>");
		std::process::exit(2);
	}
	let peer_uri = args[args.len() - 2].clone();
	let dead_uri = args[args.len() - 1].clone();

	let rt = tokio::runtime::Builder::new_current_thread()
		.enable_all()
		.build()
		.unwrap();
	let local = LocalSet::new();
	local.block_on(&rt, walk(peer_uri, dead_uri));
}
