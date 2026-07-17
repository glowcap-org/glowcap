//! Live three-party handoff over iroh, all in the Rust binding (ADR-0009), the
//! Rust sibling of the Deno `zig build demo-rooms-dm-iroh` proof and the iroh
//! companion of `rust-goblins-gift`/`rust-goblins-handoff`. It proves both halves
//! of an iroh handoff through the binding's own surface: the gifter mints a
//! `desc:handoff-give` whose exporter location names an iroh endpoint by a
//! `direct-addresses` dial hint, and the recipient redeems it transparently by
//! dialing that endpoint directly over encrypted QUIC.
//!
//! Topology — three iroh endpoints (separate identities) in one process, the
//! relay-less `Direct` posture on loopback, so the gate is deterministic and
//! flake-free (no discovery service, no network):
//!   Exporter  binds an iroh endpoint and publishes a host-giftable `greeter`.
//!   Gifter    binds its own endpoint, dials the exporter (sharing one node
//!             identity), fetches the greeter, records the exporter's dialable
//!             URI as the give's exporter location, and publishes an `introducer`
//!             that returns the greeter.
//!   Recipient binds its own endpoint, dials the gifter, asks the introducer for
//!             the greeter, transparently redeems the give by dialing the
//!             exporter directly, and calls it — the reply must echo its name.
//!
//! Returning the exporter's greeter (home = gifter-to-exporter) on the recipient's
//! connection trips the transparent gifter; the recipient's `send` resolves to an
//! ordinary capability whose calls route straight to the exporter. The proof is
//! the greeter's reply carrying the name the recipient sent.
//!
//! Needs `cargo` plus the iroh ABI companion library (`zig build iroh-abi`); run
//! via `zig build rust-iroh-handoff`.

use std::collections::BTreeMap;
use std::rc::Rc;
use std::time::Duration;

use pancake_rust_dogfood::{
	connect, encode_peer_locator, format_peer_uri, listen_iroh, Argument, Reachability, Ref,
	Session, HINT_DIRECT_ADDRESSES, TRANSPORT_IROH,
};

#[path = "../../../interop/_common/rust/helpers.rs"]
mod helpers;

type Fail = helpers::Fail;

const NAME: &str = "rust-iroh-carol";

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Fail> {
	helpers::ignore_port_args()?;
	// The `Session`/`IrohServer` drivers are `!Send`, so they live on a LocalSet.
	let local = tokio::task::LocalSet::new();
	local.run_until(run()).await
}

async fn run() -> Result<(), Fail> {
	// ── Exporter: a node-giftable greeter on its own endpoint ────────────────────
	let exporter = Rc::new(listen_iroh(Reachability::Direct)?);
	exporter
		.host()
		.publish_giftable("greeter", || Box::new(greeter));
	let (exporter_id, exporter_addrs) = dialable(&exporter).await?;
	accept_loop(Rc::clone(&exporter));
	println!("rust-iroh-handoff: exporter published greeter on {exporter_id}");

	// ── Gifter: dials the exporter under one identity, re-gifts the greeter ───────
	let gifter = Rc::new(listen_iroh(Reachability::Direct)?);
	let gifter_host = gifter.host();
	// Wait for the gifter endpoint's direct addresses so its `uri()` is dialable
	// under the relay-less Direct posture.
	let (gifter_id, _) = dialable(&gifter).await?;
	let mut hints = BTreeMap::new();
	hints.insert(HINT_DIRECT_ADDRESSES.to_string(), exporter_addrs.clone());
	let exporter_uri = format_peer_uri(TRANSPORT_IROH, &exporter_id, &hints)?;
	let to_exporter = connect(
		&exporter_uri,
		Some(Reachability::Direct),
		Some(gifter_host.clone()),
	)
	.await?;
	let greeter_ref = to_exporter.fetch("greeter").await?;
	// The exporter's own signed session record names it by node id alone — not
	// dialable under the relay-less Direct posture — so record its full dialable
	// location (id + direct-addresses) as the give's exporter location.
	to_exporter.set_exporter_locator(encode_peer_locator(
		pancake_rust_dogfood::TRANSPORT_IROH,
		&exporter_id,
		&exporter_addrs,
	)?);
	gifter_host.publish_giftable("introducer", move || {
		let greeter = greeter_ref.clone();
		Box::new(move |verb: &str, _args: &[Argument]| {
			if verb == "get-greeter" {
				Ok(Argument::from(&greeter))
			} else {
				Err(format!("introducer: no such verb {verb:?}"))
			}
		})
	});
	accept_loop(Rc::clone(&gifter));
	println!("rust-iroh-handoff: gifter published introducer on {gifter_id}");

	// ── Recipient: dials the gifter, redeems the give by dialing the exporter ─────
	let recipient = connect(&gifter.uri()?, Some(Reachability::Direct), None).await?;
	let introducer = recipient.fetch("introducer").await?;
	let granted = recipient.send(&introducer, "get-greeter", &[]).await?;
	let greeter = Ref::try_from(&granted)
		.map_err(|_| format!("introduction did not redeem to a capability: {granted:?}"))?;
	println!("rust-iroh-handoff: recipient redeemed the give, got the greeter as an ordinary ref");

	let reply = recipient
		.send(&greeter, "greet", &[Argument::String(NAME.into())])
		.await?;
	match &reply {
		Argument::String(text) if text.contains(NAME) => {
			println!("rust-iroh-handoff: greeter replied: {text}");
		}
		other => {
			return Err(format!("greeter reply did not carry the name back: {other:?}").into())
		}
	}

	println!(
		"rust-iroh-handoff OK: the Rust binding minted an iroh handoff give and redeemed it \
		 by dialing the exporter directly over encrypted QUIC"
	);

	// Teardown: close the dialing connections; the exporter/gifter accept loops
	// are still parked on `accept().await` and are cancelled when this function
	// returns and the enclosing `LocalSet` is dropped.
	recipient.close();
	to_exporter.close();
	Ok(())
}

// Serve every connection a server accepts for the life of the run: the loop
// holds its own `Rc` to the server and parks on `accept().await`, so it is
// cancelled with the enclosing `LocalSet` rather than awaited.
fn accept_loop(server: Rc<pancake_rust_dogfood::IrohServer>) {
	tokio::task::spawn_local(async move {
		let mut held: Vec<Session> = Vec::new();
		while let Ok(session) = server.accept().await {
			held.push(session);
		}
	});
}

// The published actor: answer `greet` by echoing the caller's name.
fn greeter(verb: &str, args: &[Argument]) -> Result<Argument, String> {
	if verb == "greet" {
		let name = args.first().and_then(Argument::as_str).unwrap_or("");
		Ok(format!("hello {name} over iroh handoff").into())
	} else {
		Err(format!("no such method: {verb}"))
	}
}

// An iroh endpoint reports its direct addresses asynchronously after bind, so
// wait for at least one before reading the dialable id+addresses, a give with no
// direct-addresses hint is not dialable under the relay-less Direct posture.
async fn dialable(server: &pancake_rust_dogfood::IrohServer) -> Result<(String, String), Fail> {
	for _ in 0..1000 {
		let addrs = server.direct_addresses()?;
		if !addrs.is_empty() {
			return Ok((server.node_id().to_string(), addrs));
		}
		tokio::time::sleep(Duration::from_millis(20)).await;
	}
	Err("timed out waiting for an endpoint's direct addresses".into())
}
