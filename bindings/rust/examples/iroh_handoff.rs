//! Live three-party handoff over iroh, all in the Rust binding (ADR-0039), the
//! Rust sibling of the Deno `zig build demo-rooms-dm-iroh` proof and the iroh
//! companion of `rust-goblins-gift`/`rust-goblins-handoff`. It proves both halves
//! of an iroh handoff through the binding's own surface: the gifter mints a
//! `desc:handoff-give` whose exporter location names an iroh endpoint by a
//! `direct-addresses` dial hint, and the recipient redeems it transparently by
//! dialing that endpoint directly over encrypted QUIC.
//!
//! Topology: three iroh endpoints (separate identities) in one process, the
//! relay-less `Direct` posture on loopback, so the gate is deterministic and
//! flake-free (no discovery service, no network):
//!   Exporter  binds an iroh endpoint and publishes a Host-published `greeter`.
//!   Gifter    binds its own endpoint, dials the exporter (sharing one node
//!             identity), fetches the greeter, records the exporter's dialable
//!             URI as the give's exporter location, and publishes an `introducer`
//!             that returns the greeter.
//!   Recipient binds its own endpoint, dials the gifter, asks the introducer for
//!             the greeter, transparently redeems the give by dialing the
//!             exporter directly, and calls it: the reply must echo its name.
//!
//! Returning the exporter's greeter (home = gifter-to-exporter) on the recipient's
//! connection trips the transparent gifter. The recipient's `send` resolves to an
//! ordinary capability whose calls route straight to the exporter. The proof is
//! the greeter's reply carrying the name the recipient sent.
//!
//! Needs `cargo` plus the iroh ABI companion library (`zig build iroh-abi`). Run
//! via `zig build rust-iroh-handoff`.

use std::rc::Rc;
use std::time::Duration;

use glowcap_rust_dogfood::iroh::Reachability;
use glowcap_rust_dogfood::{Argument, ConnectOptions, PendingWork, Ref, Runtime, RuntimeConfig, iroh};

#[path = "../../../interop/_common/rust/helpers.rs"]
mod helpers;

type Fail = helpers::Fail;

const NAME: &str = "rust-iroh-carol";

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Fail> {
	helpers::ignore_port_args()?;
	// The `Session`/`Server` drivers are `!Send`, so they live on a LocalSet.
	let local = tokio::task::LocalSet::new();
	local.run_until(run()).await
}

async fn run() -> Result<(), Fail> {
	// ── Exporter: a Host-published greeter on its own endpoint ────────────────────
	let exporter =
		Rc::new(iroh::listen(iroh::Config::new(Reachability::Direct), iroh::ListenOptions::default()).await?);
	exporter.host().publish("greeter", || Box::new(greeter()))?;
	let (exporter_id, exporter_addrs) = dialable(&exporter).await?;
	helpers::serve_iroh_sessions(Rc::clone(&exporter));
	println!("rust-iroh-handoff: exporter published greeter on {exporter_id}");

	// ── Gifter: dials the exporter under one identity, re-gifts the greeter ───────
	let gifter = Rc::new(iroh::listen(iroh::Config::new(Reachability::Direct), iroh::ListenOptions::default()).await?);
	let gifter_host = gifter.host();
	// Wait for the gifter endpoint's direct addresses so its `uri()` is dialable
	// under the relay-less Direct posture.
	let (gifter_id, _) = dialable(&gifter).await?;
	let exporter_locator = glowcap_rust_dogfood::iroh::locator(&exporter_id, Some(&exporter_addrs));
	let gifter_runtime = Runtime::open(
		RuntimeConfig::providers([iroh::provider(iroh::Config::new(Reachability::Direct))]).adopt_host(&gifter_host),
	)
	.await?;
	let to_exporter = gifter_runtime
		.connect(&exporter_locator, ConnectOptions::default())
		.await?;
	let greeter_ref = to_exporter.fetch("greeter").await?;
	// Mutate the held greeter, then replace the alias with a decoy: the give
	// must retain the exact mutated actor, never whatever the alias resolves
	// to at withdrawal (ADR-0026's exact-object identity, on the binding path).
	let primed = to_exporter
		.send(&greeter_ref, "prime", &[Argument::String("gifter-mark".into())])
		.await?;
	if primed.as_str() != Some("primed") {
		return Err(format!("prime did not land: {primed:?}").into());
	}
	exporter.host().publish("greeter", || {
		Box::new(|_verb: &str, _args: &[Argument]| Ok(Argument::from("decoy")))
	})?;
	// The exporter's own signed session record names it by node id alone, not
	// dialable under the relay-less Direct posture, so record its full dialable
	// location (id + direct-addresses) as the give's exporter location.
	to_exporter.set_exporter_locator(Some(&exporter_locator))?;
	gifter_host.publish("introducer", move || {
		let greeter = greeter_ref.clone();
		Box::new(move |verb: &str, _args: &[Argument]| {
			if verb == "get-greeter" {
				Ok(Argument::from(&greeter))
			} else {
				Err(format!("introducer: no such verb {verb:?}"))
			}
		})
	})?;
	helpers::serve_iroh_sessions(Rc::clone(&gifter));
	println!("rust-iroh-handoff: gifter published introducer on {gifter_id}");

	// ── Recipient: dials the gifter, redeems the give by dialing the exporter ─────
	let recipient_runtime = Runtime::open(RuntimeConfig::providers([iroh::provider(iroh::Config::new(
		Reachability::Direct,
	))]))
	.await?;
	let recipient = recipient_runtime
		.connect(&gifter.locator()?, ConnectOptions::default())
		.await?;
	let introducer = recipient.fetch("introducer").await?;
	let granted = recipient.send(&introducer, "get-greeter", &[]).await?;
	let greeter =
		Ref::try_from(&granted).map_err(|_| format!("introduction did not redeem to a capability: {granted:?}"))?;
	println!("rust-iroh-handoff: recipient redeemed the give, got the greeter as an ordinary ref");

	let reply = recipient
		.send(&greeter, "greet", &[Argument::String(NAME.into())])
		.await?;
	match &reply {
		Argument::String(text) if text.contains(NAME) && text.contains("gifter-mark") => {
			println!("rust-iroh-handoff: greeter replied: {text}");
		}
		other => return Err(format!("greeter reply did not carry the name back: {other:?}").into()),
	}

	println!(
		"rust-iroh-handoff OK: the Rust binding minted an iroh handoff give and redeemed it \
		 by dialing the exporter directly over encrypted QUIC"
	);

	// Teardown: close the dialing connections; the exporter/gifter accept loops
	// are still parked on `accept().await` and are cancelled when this function
	// returns and the enclosing `LocalSet` is dropped.
	recipient.close(PendingWork::Cancel).await?;
	to_exporter.close(PendingWork::Cancel).await?;
	Ok(())
}

// The published actor: `prime` stores a mark, `greet` echoes the caller's
// name with it: so a redeemed call proves the exact mutated actor answered.
fn greeter() -> impl FnMut(&str, &[Argument]) -> Result<Argument, String> {
	let mut mark = String::new();
	move |verb: &str, args: &[Argument]| {
		if verb == "prime" {
			mark = args.first().and_then(Argument::as_str).unwrap_or("").to_string();
			return Ok("primed".into());
		}
		if verb == "greet" {
			let name = args.first().and_then(Argument::as_str).unwrap_or("");
			Ok(format!("hello {name} over iroh handoff, {mark}").into())
		} else {
			Err(format!("no such method: {verb}"))
		}
	}
}

// An iroh endpoint reports its direct addresses asynchronously after bind, so
// wait for at least one before reading the dialable id+addresses, a give with no
// direct-addresses hint is not dialable under the relay-less Direct posture.
async fn dialable(server: &glowcap_rust_dogfood::iroh::Server) -> Result<(String, String), Fail> {
	for _ in 0..1000 {
		if let Some(addrs) = server.direct_addresses()? {
			return Ok((server.node_id().to_string(), addrs));
		}
		tokio::time::sleep(Duration::from_millis(20)).await;
	}
	Err("timed out waiting for an endpoint's direct addresses".into())
}
