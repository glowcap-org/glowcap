//! Per-binding noise-relay managed-listen proof, Rust half:
//! `relay::noise::listen` registers a fresh durable key at the reference
//! relay and serves accepted Noise_XK-sealed sessions. Run by `harness.ts`
//! (via `zig build rust-noise-relay-listen`), which appends
//! `<relayUrl> <registerUrl>` and dials the printed locator.

use pancake_rust_dogfood::{relay, Argument};
use tokio::task::LocalSet;

fn greeter(verb: &str, args: &[Argument]) -> Result<Argument, String> {
	if verb != "greet" {
		return Err("no such method".into());
	}
	let Some(Argument::String(name)) = args.first() else {
		return Err("bad invocation".into());
	};
	Ok(Argument::String(format!("Hello, {name}").into()))
}

async fn scene(relay_url: String, register_url: String) -> Result<(), String> {
	let server = relay::noise::listen(&relay_url, &register_url, relay::ListenOptions::default())
		.await
		.map_err(|e| e.to_string())?;
	server
		.host()
		.publish_giftable("greeter", || Box::new(greeter))
		.map_err(|e| e.to_string())?;
	println!("RELAY-LISTENER-READY {}", server.uri().map_err(|e| e.to_string())?);
	// Admission is loop-owned, but serving is an explicit application choice:
	// start each accepted session's inbound delivery and retain its handle so
	// the harness's dial stays live until it kills this process.
	let mut sessions = Vec::new();
	loop {
		let session = server.accept().await.map_err(|e| e.to_string())?;
		let serving = session.serve();
		tokio::task::spawn_local(async move {
			if let Err(error) = serving.await {
				eprintln!("noise-relay accepted session failed: {error}");
			}
		});
		sessions.push(session);
	}
}

fn main() {
	let args: Vec<String> = std::env::args().collect();
	if args.len() < 3 {
		eprintln!("usage: noise_relay_listen <relayUrl> <registerUrl>");
		std::process::exit(2);
	}
	let register_url = args[args.len() - 1].clone();
	let relay_url = args[args.len() - 2].clone();

	let rt = tokio::runtime::Builder::new_current_thread()
		.enable_all()
		.build()
		.unwrap();
	let local = LocalSet::new();
	local.block_on(&rt, async {
		scene(relay_url, register_url).await.expect("noise-relay listen");
	});
}
