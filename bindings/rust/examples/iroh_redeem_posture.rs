//! Hermetic proof that a recipient's **configured redeem posture** governs how a
//! *hint-less* iroh handoff give is dialed (ADR-0009), the Rust sibling of the
//! Python/Racket `iroh_redeem_posture` clients.
//!
//! A give whose exporter location names the exporter by **node id alone** (no
//! `direct-addresses`) cannot be dialed `Direct` — the recipient must resolve the
//! id. Which discovery posture it resolves under is the recipient node's
//! `set_redeem_reachability` knob: `Discovery` (n0 relays + DNS/pkarr) by default,
//! lowerable for a deployment policy. This gate sets that knob to
//! `LocalDiscovery` — an in-process address book, no network — and proves the
//! hint-less redeem dials by id through it and withdraws the gift.
//!
//! It is a *discriminating* proof: with the default `Discovery`, the hint-less
//! redeem would reach for n0's public relays + DNS and fail with no internet; the
//! redeem succeeds here only because `dial_exporter` honors the configured
//! posture. Deterministic and flake-free — three `LocalDiscovery` endpoints in
//! one process sharing one address book.
//!
//! Topology:
//!   Exporter  binds a `LocalDiscovery` endpoint, publishes a host-giftable
//!             `greeter`.
//!   Gifter    binds its own endpoint, dials the exporter by id (one node
//!             identity), fetches the greeter, and records the exporter's
//!             **id-only** location as the give's exporter location — a hint-less
//!             give.
//!   Recipient binds its own endpoint, sets its redeem posture to
//!             `LocalDiscovery`, dials the gifter, asks for the greeter, redeems
//!             the hint-less give by resolving the exporter's id through the book,
//!             and calls it — the reply must echo its name.
//!
//! Needs `cargo` plus the iroh ABI companion library (`zig build iroh-abi`); run
//! via `zig build rust-iroh-redeem-posture`.

use std::rc::Rc;

use pancake_rust_dogfood::{
	connect, encode_peer_locator, format_peer_uri, listen_iroh, Argument, Reachability, Ref,
	Session, TRANSPORT_IROH,
};

#[path = "../../../interop/_common/rust/helpers.rs"]
mod helpers;

type Fail = helpers::Fail;

const NAME: &str = "rust-redeem-posture-carol";

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Fail> {
	helpers::ignore_port_args()?;
	// The `Session`/`IrohServer` drivers are `!Send`, so they live on a LocalSet.
	let local = tokio::task::LocalSet::new();
	local.run_until(run()).await
}

async fn run() -> Result<(), Fail> {
	// ── Exporter: a node-giftable greeter on its own local-discovery endpoint ─────
	let exporter = Rc::new(listen_iroh(Reachability::LocalDiscovery)?);
	exporter
		.host()
		.publish_giftable("greeter", || Box::new(greeter));
	let exporter_id = exporter.node_id().to_string();
	accept_loop(Rc::clone(&exporter));
	println!("rust-iroh-redeem-posture: exporter published greeter on {exporter_id}");

	// ── Gifter: dials the exporter by id, re-gifts the greeter under a hint-less give
	let gifter = Rc::new(listen_iroh(Reachability::LocalDiscovery)?);
	let gifter_host = gifter.host();
	let gifter_id = gifter.node_id().to_string();
	let exporter_uri = format_peer_uri(TRANSPORT_IROH, &exporter_id, &Default::default())?;
	let to_exporter = connect(
		&exporter_uri,
		Some(Reachability::LocalDiscovery),
		Some(gifter_host.clone()),
	)
	.await?;
	let greeter_ref = to_exporter.fetch("greeter").await?;
	// Record the exporter's location by **node id alone** — no direct-addresses.
	// This is what forces the recipient down the configured-posture redeem path
	// instead of a Direct dial.
	to_exporter.set_exporter_locator(encode_peer_locator(
		pancake_rust_dogfood::TRANSPORT_IROH,
		&exporter_id,
		"",
	)?)?;
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
	println!("rust-iroh-redeem-posture: gifter published introducer on {gifter_id}");

	// ── Recipient: configures its redeem posture, then redeems the hint-less give ─
	let gifter_uri = format_peer_uri(TRANSPORT_IROH, &gifter_id, &Default::default())?;
	let recipient = connect(&gifter_uri, Some(Reachability::LocalDiscovery), None).await?;
	// The knob under test: without it, the hint-less redeem defaults to Discovery
	// (n0 relays + DNS) and would fail with no network. The node is shared, so
	// this reaches the connection that performs the redeem.
	recipient
		.host()
		.set_redeem_reachability(Reachability::LocalDiscovery);
	let introducer = recipient.fetch("introducer").await?;
	let granted = recipient.send(&introducer, "get-greeter", &[]).await?;
	let greeter = Ref::try_from(&granted)
		.map_err(|_| format!("introduction did not redeem to a capability: {granted:?}"))?;
	println!(
		"rust-iroh-redeem-posture: recipient redeemed the hint-less give under its configured \
		 LocalDiscovery posture, got the greeter as an ordinary ref"
	);

	let reply = recipient
		.send(&greeter, "greet", &[Argument::String(NAME.into())])
		.await?;
	match &reply {
		Argument::String(text) if text.contains(NAME) => {
			println!("rust-iroh-redeem-posture: greeter replied: {text}");
		}
		other => {
			return Err(format!("greeter reply did not carry the name back: {other:?}").into())
		}
	}

	println!(
		"rust-iroh-redeem-posture OK: a hint-less iroh give was redeemed by id through the \
		 recipient's configured LocalDiscovery posture (default Discovery would need the network)"
	);

	recipient.close();
	to_exporter.close();
	Ok(())
}

// Serve every connection a server accepts for the life of the run: the loop holds
// its own `Rc` to the server and parks on `accept().await`, so it is cancelled
// with the enclosing `LocalSet` rather than awaited.
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
		Ok(format!("hello {name} over a configured-posture redeem").into())
	} else {
		Err(format!("no such method: {verb}"))
	}
}
