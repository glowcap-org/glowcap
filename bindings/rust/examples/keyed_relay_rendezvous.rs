//! Per-binding keyed-relay rendezvous proof: the Rust binding cold-dials a
//! non-listening peer by its key designator through the reference relay's
//! rendezvous bridge (ADR-0088). The core classifies the locator as the
//! rendezvous dial shape; the binding opens the WebSocket leg the host's
//! `set_rendezvous_url` mapping names and runs the keyed handshake end to end.
//!
//! Run via `zig build rust-keyed-relay-rendezvous` (the harness passes
//! `<relay-port> <designator>` after `--`).

use pancake_rust_dogfood::{connect, Argument, Codec, Host};
use tokio::task::LocalSet;

async fn scene(relay_port: String, designator: String) -> Result<(), String> {
	let host = Host::with_codec(Codec::Syrup);
	host.set_rendezvous_url(move |id| format!("ws://127.0.0.1:{relay_port}/relay?rendezvous={id}"))
		.map_err(|e| e.to_string())?;
	let session = connect(
		&format!("ocapn://{designator}.keyed-relay"),
		None,
		Some(host),
	)
	.await
	.map_err(|e| e.to_string())?;
	let greeter = session.fetch("greeter").await.map_err(|e| e.to_string())?;
	let reply = session
		.send(&greeter, "greet", &[Argument::from("rust")])
		.await
		.map_err(|e| e.to_string())?;
	let expected = "hello rust, cold-dialed by rendezvous";
	match reply {
		Argument::String(s) if s == expected => {}
		other => return Err(format!("unexpected greeting: {other:?}")),
	}
	session.close();
	Ok(())
}

fn main() {
	// The harness appends the two; a pinned -Dport flag may sit before them.
	let args: Vec<String> = std::env::args().collect();
	if args.len() < 3 {
		eprintln!("usage: keyed_relay_rendezvous <relay-port> <designator>");
		std::process::exit(2);
	}
	let relay_port = args[args.len() - 2].clone();
	let designator = args[args.len() - 1].clone();

	let rt = tokio::runtime::Builder::new_current_thread()
		.enable_all()
		.build()
		.unwrap();
	let local = LocalSet::new();
	local.block_on(&rt, async {
		scene(relay_port, designator)
			.await
			.expect("rendezvous dial");
		println!(
			"PASS: the Rust binding cold-dialed a registered peer by rendezvous — the core \
			 classified the keyed-relay locator, the host's configured relay mapping opened \
			 the bridge, and the keyed session answered"
		);
	});
}
