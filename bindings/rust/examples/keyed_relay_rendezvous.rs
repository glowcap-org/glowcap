//! Per-binding keyed-relay rendezvous proof: the Rust binding cold-dials a
//! non-listening peer by its key designator through the reference relay's
//! rendezvous bridge (ADR-0088). The core classifies the locator as the
//! rendezvous dial shape; the binding opens the WebSocket leg the host's
//! advertised locator names while the Host fallback is deliberately dead.
//!
//! Run via `zig build rust-keyed-relay-rendezvous` (the harness passes
//! `<locator>` after `--`).

use pancake_rust_dogfood::{connect, Argument, Codec, Host};
use tokio::task::LocalSet;

async fn scene(locator: String) -> Result<(), String> {
	let host = Host::with_codec(Codec::Syrup);
	host.set_rendezvous_url(move |id| format!("ws://127.0.0.1:1/relay?rendezvous={id}"))
		.map_err(|e| e.to_string())?;
	let session = connect(&locator, None, Some(host))
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
	if args.len() < 2 {
		eprintln!("usage: keyed_relay_rendezvous <locator>");
		std::process::exit(2);
	}
	let locator = args[args.len() - 1].clone();

	let rt = tokio::runtime::Builder::new_current_thread()
		.enable_all()
		.build()
		.unwrap();
	let local = LocalSet::new();
	local.block_on(&rt, async {
		scene(locator).await.expect("rendezvous dial");
		println!(
			"PASS: the Rust binding used the locator's rendezvous-relay route instead of \
			 the dead Host fallback, and the keyed session answered"
		);
	});
}
