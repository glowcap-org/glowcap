//! Live real-internet iroh reachability proof in the Rust binding — the binding
//! sibling of the Zig `iroh-reachability` driver. Two iroh endpoints in one
//! process reach each other by node id ALONE over n0's public relays and
//! DNS/pkarr discovery: no direct-address hints, no in-process address book.
//!
//! Both endpoints bind with the `Discovery` posture. The server publishes its
//! node info to pkarr on bind; the client dials the server by its 64-hex node id
//! with an empty hint set, so a session that opens proves the dial was resolved
//! over real discovery infrastructure and carried over a real relay / hole-
//! punched path — not hinted, not loopback-booked. The client's dial rides the
//! `connect_iroh` `Discovery` retry that settles while the publish propagates.
//!
//! Not a hermetic gate. This step touches public n0 infrastructure
//! (`*.relay.iroh.network`, `dns.iroh.link`), and discovery-propagation timing
//! makes it unsuitable for `zig build check`. It runs only as the opt-in
//! `zig build rust-iroh-reachability`, the same cargo-linking posture as
//! `rust-iroh-loop`, so it can never make `check` flaky.
//!
//! Needs `cargo` plus the iroh ABI companion library (`zig build iroh-abi`) and
//! a live internet connection; run via `zig build rust-iroh-reachability`.

use std::rc::Rc;

use pancake_rust_dogfood::{Argument, Connection, Reachability};

type Fail = Box<dyn std::error::Error>;

const NAME: &str = "rust-iroh-world";

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Fail> {
	for arg in std::env::args().skip(1) {
		// The gate takes no arguments; accept and ignore a `--port=` for parity
		// with the other binding gates' build wiring.
		if !arg.starts_with("--port=") {
			return Err(format!("unknown argument '{arg}'").into());
		}
	}
	// The `Connection`/`IrohServer` drivers are `!Send`, so they live on a LocalSet.
	let local = tokio::task::LocalSet::new();
	local.run_until(run()).await
}

async fn run() -> Result<(), Fail> {
	// ── Server: a giftable greeter, dialable by node id alone over discovery ──────
	let server = Rc::new(pancake_rust_dogfood::listen_iroh(Reachability::Discovery)?);
	server
		.node()
		.publish_giftable("greeter", || Box::new(greeter));
	let server_id = server.node_id().to_string();
	accept_loop(Rc::clone(&server));
	println!(
		"rust-iroh-reachability: server published greeter on {server_id} \
		 (pkarr-published; no direct addrs shared)"
	);

	// ── Client: dial by node id ALONE — empty hints — over real n0 discovery ──────
	let client = Connection::connect_iroh(&server_id, "", Reachability::Discovery).await?;
	println!("rust-iroh-reachability: client dialed by node id alone and opened the keyed session");

	let greeter_ref = client.fetch("greeter").await?;
	let reply = client
		.send(&greeter_ref, "greet", &[Argument::String(NAME.into())])
		.await?;
	match &reply {
		Argument::String(text) if text.contains(NAME) => {
			println!("rust-iroh-reachability: greeter replied: {text}");
		}
		other => {
			return Err(format!("greeter reply did not carry the name back: {other:?}").into())
		}
	}

	println!(
		"rust-iroh-reachability OK: the Rust binding reached a peer by node id alone over \
		 n0 relays + DNS/pkarr discovery, no direct-address hints"
	);

	// Teardown: close the dialing connection; the server accept loop is parked on
	// `accept().await` and is cancelled when this function returns and the
	// enclosing `LocalSet` is dropped.
	client.close();
	Ok(())
}

// Serve every connection the server accepts for the life of the run: the loop
// holds its own `Rc` to the server and parks on `accept().await`, so it is
// cancelled with the enclosing `LocalSet` rather than awaited.
fn accept_loop(server: Rc<pancake_rust_dogfood::IrohServer>) {
	tokio::task::spawn_local(async move {
		let mut held: Vec<Connection> = Vec::new();
		while let Ok(conn) = server.accept().await {
			held.push(conn);
		}
	});
}

// The published actor: answer `greet` by echoing the caller's name.
fn greeter(verb: &str, args: &[Argument]) -> Result<Argument, String> {
	if verb == "greet" {
		let name = args.first().and_then(Argument::as_str).unwrap_or("");
		Ok(format!("hello {name} over iroh discovery").into())
	} else {
		Err(format!("no such method: {verb}"))
	}
}
