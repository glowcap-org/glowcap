//! Live three-party handoff with the Rust binding as the recipient (Carol),
//! proving the binding redeems a `desc:handoff-give` transparently — through the
//! same `connect`/`fetch`/`send` application surface the demos use, with no
//! bespoke handoff choreography in the application. The binding counterpart of
//! `zig build goblins-handoff` (which proves it at the Zig driver level).
//!
//! It spawns the conformance Goblins introducer host (Alice on PORT, Bob the
//! exporter on PORT+1), learns Alice's introducer swiss-num from its NDJSON
//! readiness line, then:
//!   1. `connect` to Alice and `fetch` the introducer.
//!   2. `send(introducer, "get-greeter")`. Alice hands back Bob's greeter as a
//!      three-party handoff give. The binding's node router redeems it: it
//!      dials Bob directly (keyed with the *same* identity Alice saw), withdraws
//!      the gift, and resolves the send to an ordinary capability — the
//!      application never sees the give or the second connection.
//!   3. `send(greeter, "", ["pancake-carol"])`. The bytes go straight to Bob;
//!      the reply must carry the name back, proving data integrity end to end.
//!
//! Needs `racket` plus the `goblins` collection on PATH; run via
//! `zig build rust-goblins-handoff`.

use pancake_rust_dogfood::{connect, tcp_locator, Argument, Ref};
use tokio::process::Command;

#[path = "../_common/rust/helpers.rs"]
mod helpers;

type Fail = helpers::Fail;

const HOST: &str = "127.0.0.1";
/// Alice's port; Bob (the exporter) listens on PORT+1. `--port=N` (from
/// `zig build rust-goblins-handoff -Dport=N`) moves the pair when 22115 is taken.
const DEFAULT_PORT: u16 = 22115;
const RACKET: &str = "/usr/local/bin/racket";
const HOST_SCRIPT: &str = "conformance/goblins-peer/racket/handoff-introducer-host.rkt";

fn parse_port() -> Result<u16, Fail> {
	helpers::parse_port(DEFAULT_PORT, 65534)
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Fail> {
	let port = parse_port()?;
	let mut child = Command::new(RACKET)
		.args([HOST_SCRIPT, &port.to_string(), &(port + 1).to_string()])
		.stdout(std::process::Stdio::piped())
		.stderr(std::process::Stdio::piped())
		.kill_on_drop(true)
		.spawn()?;

	let swiss = helpers::read_swiss(&mut child).await?;
	println!("rust-goblins-handoff: alice published introducer swiss={swiss} on {HOST}:{port}");

	// The `Session` is `!Send`, so it lives on a `LocalSet`.
	let local = tokio::task::LocalSet::new();
	let result = local.run_until(converse(swiss, port)).await;
	let _ = child.kill().await;
	result
}

async fn converse(swiss: String, port: u16) -> Result<(), Fail> {
	// `connect` completes the keyed handshake; the host's retained identity is
	// the recipient key the gift Alice deposits will name.
	let conn = connect(&tcp_locator(HOST, port), None, None).await?;
	println!("rust-goblins-handoff: session open (recipient -> alice)");

	let introducer = conn.fetch(&swiss).await?;
	println!("rust-goblins-handoff: enlivened alice's introducer, asking for the greeter");

	// The introduction: Alice returns Bob's greeter as a handoff give. The
	// binding redeems it transparently, so this resolves to an ordinary capability.
	let granted = conn.send(&introducer, "get-greeter", &[]).await?;
	let greeter = Ref::try_from(&granted)
		.map_err(|_| format!("introduction did not redeem to a capability: {granted:?}"))?;
	println!("rust-goblins-handoff: introduction redeemed, got the greeter as an ordinary ref");

	// Call the greeter. The send routes straight to Bob (the exporter); the reply
	// must echo the name we sent, so the handoff proves data integrity.
	let reply = conn
		.send(&greeter, "", &[Argument::String("pancake-carol".into())])
		.await?;
	match &reply {
		Argument::String(text) if text.contains("pancake-carol") => {
			println!("rust-goblins-handoff: greeter replied: {text}");
		}
		other => {
			return Err(format!("greeter reply did not carry the name back: {other:?}").into())
		}
	}

	println!(
        "rust-goblins-handoff OK: the Rust binding redeemed a three-party handoff from live Goblins \
         and called the exporter directly"
    );
	conn.close();
	Ok(())
}
