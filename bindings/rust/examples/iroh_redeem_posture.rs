//! Hermetic proof that a recipient's **configured redeem posture** governs how a
//! *hint-less* iroh handoff give is dialed (ADR-0009), the Rust sibling of the
//! Python/Racket `iroh_redeem_posture` clients.
//!
//! A give whose exporter location names the exporter by **node id alone** (no
//! `direct-addresses`) cannot be dialed `Direct` — the recipient must resolve the
//! id. Which discovery posture it resolves under is owned by the iroh provider
//! installed on the recipient Host. This gate installs `LocalDiscovery` — an
//! in-process address book, no network — and proves the hint-less redeem dials
//! by id through it and withdraws the gift.
//!
//! It is a *discriminating* proof: with the default `Discovery`, the hint-less
//! redeem would reach for n0's public relays + DNS and fail with no internet; the
//! redeem succeeds here only because `dial_exporter` honors the configured
//! posture. Deterministic and flake-free — three `LocalDiscovery` endpoints in
//! one process sharing one address book.
//!
//! Topology:
//!   Exporter  binds a `LocalDiscovery` endpoint, publishes a Host-published
//!             `greeter`.
//!   Gifter    binds its own endpoint, dials the exporter by id (one node
//!             identity), fetches the greeter, and records the exporter's
//!             **id-only** location as the give's exporter location — a hint-less
//!             give.
//!   Recipient installs a `LocalDiscovery` provider, dials the gifter, asks for
//!             the greeter, redeems
//!             the hint-less give by resolving the exporter's id through the book,
//!             and calls it — the reply must echo its name.
//!
//! Needs `cargo` plus the iroh ABI companion library (`zig build iroh-abi`); run
//! via `zig build rust-iroh-redeem-posture`.

use std::rc::Rc;

use glowcap_rust_dogfood::iroh::Reachability;
use glowcap_rust_dogfood::{Argument, ConnectOptions, PendingWork, Ref, Runtime, RuntimeConfig, iroh};

#[path = "../../../interop/_common/rust/helpers.rs"]
mod helpers;

type Fail = helpers::Fail;

const NAME: &str = "rust-redeem-posture-carol";

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Fail> {
	helpers::ignore_port_args()?;
	// The `Session`/`Server` drivers are `!Send`, so they live on a LocalSet.
	let local = tokio::task::LocalSet::new();
	local.run_until(run()).await
}

async fn run() -> Result<(), Fail> {
	// ── Exporter: a Host-published greeter on its own local-discovery endpoint ─────
	let exporter = Rc::new(
		iroh::listen(
			iroh::Config::new(Reachability::LocalDiscovery),
			iroh::ListenOptions::default(),
		)
		.await?,
	);
	exporter.host().publish("greeter", || Box::new(greeter))?;
	let exporter_id = exporter.node_id().to_string();
	helpers::serve_iroh_sessions(Rc::clone(&exporter));
	println!("rust-iroh-redeem-posture: exporter published greeter on {exporter_id}");

	// ── Gifter: dials the exporter by id, re-gifts the greeter under a hint-less give
	let gifter = Rc::new(
		iroh::listen(
			iroh::Config::new(Reachability::LocalDiscovery),
			iroh::ListenOptions::default(),
		)
		.await?,
	);
	let gifter_host = gifter.host();
	let gifter_id = gifter.node_id().to_string();
	let exporter_locator = glowcap_rust_dogfood::iroh::locator(&exporter_id, None);
	let gifter_runtime = Runtime::open(
		RuntimeConfig::providers([iroh::provider(iroh::Config::new(Reachability::LocalDiscovery))])
			.adopt_host(&gifter_host),
	)
	.await?;
	let to_exporter = gifter_runtime
		.connect(&exporter_locator, ConnectOptions::default())
		.await?;
	let greeter_ref = to_exporter.fetch("greeter").await?;
	// Record the exporter's location by **node id alone** — no direct-addresses.
	// This is what forces the recipient down the configured-posture redeem path
	// instead of a Direct dial.
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
	println!("rust-iroh-redeem-posture: gifter published introducer on {gifter_id}");

	// ── Recipient: configures its redeem posture, then redeems the hint-less give ─
	let gifter_locator = glowcap_rust_dogfood::iroh::locator(&gifter_id, None);
	let recipient_runtime = Runtime::open(RuntimeConfig::providers([iroh::provider(iroh::Config::new(
		Reachability::LocalDiscovery,
	))]))
	.await?;
	let recipient = recipient_runtime
		.connect(&gifter_locator, ConnectOptions::default())
		.await?;
	// The provider installed by connect remains on the shared Host, so the
	// transparent redeem uses the same LocalDiscovery authority.
	let introducer = recipient.fetch("introducer").await?;
	let granted = recipient.send(&introducer, "get-greeter", &[]).await?;
	let greeter =
		Ref::try_from(&granted).map_err(|_| format!("introduction did not redeem to a capability: {granted:?}"))?;
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
		other => return Err(format!("greeter reply did not carry the name back: {other:?}").into()),
	}

	println!(
		"rust-iroh-redeem-posture OK: a hint-less iroh give was redeemed by id through the \
		 recipient's configured LocalDiscovery posture (default Discovery would need the network)"
	);

	recipient.close(PendingWork::Cancel).await?;
	to_exporter.close(PendingWork::Cancel).await?;
	Ok(())
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
