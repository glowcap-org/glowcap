//! Per-binding keyed-tcp restart proof (ADR-0075): happy path, key-squatter
//! refusal, and same-seed-fresh-port restart — the Rust sibling of
//! `test/driver/keyed_tcp_restart_test.zig`.
//!
//! Run via `zig build rust-keyed-tcp-restart` (needs cargo).

use std::rc::Rc;

use glowcap_rust_dogfood::{tcp, Argument, ConnectOptions, Locator, Runtime, RuntimeConfig};
use tokio::sync::oneshot;
use tokio::task::LocalSet;

const GREETING: &str = "hello from the keyed listener";
const SEED_HAPPY: [u8; 32] = [0x71; 32];
const SEED_HONEST: [u8; 32] = [0x72; 32];
const SEED_SQUATTER: [u8; 32] = [0x73; 32];
const SEED_RESTART: [u8; 32] = [0x74; 32];

fn greeter(verb: &str, _args: &[Argument]) -> Result<Argument, String> {
	if verb == "greet" {
		Ok(GREETING.into())
	} else {
		Err(format!("no such method: {verb}"))
	}
}

async fn listen(seed: [u8; 32]) -> Result<tcp::Server, String> {
	tcp::keyed::listen(
		"127.0.0.1",
		0,
		tcp::ListenOptions {
			identity: tcp::ListenerIdentity::Seed(seed),
			..tcp::ListenOptions::default()
		},
	)
	.await
	.map_err(|e| e.to_string())
}

/// Dial, wait until the host has published, then fetch/call. `connect` must run
/// concurrently with `accept` so the listener unblocks; the oneshot orders
/// publish ahead of fetch.
async fn call_greeter(partner: &Locator, published: oneshot::Receiver<()>) -> Result<(), String> {
	let runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
		.await
		.map_err(|e| e.to_string())?;
	let session = runtime
		.connect(partner, ConnectOptions::default())
		.await
		.map_err(|e| e.to_string())?;
	let _ = published.await;
	let greeter = session.fetch("greeter").await.map_err(|e| e.to_string())?;
	let reply = session.send(&greeter, "greet", &[]).await.map_err(|e| e.to_string())?;
	match reply {
		Argument::String(s) if s == GREETING => Ok(()),
		other => Err(format!("unexpected greeting: {other:?}")),
	}
}

async fn host_one(server: Rc<tcp::Server>, published: oneshot::Sender<()>) {
	match server.accept().await {
		Ok(session) => {
			if session.publish("greeter", greeter).is_ok() {
				let _ = published.send(());
			}
			// An accepted session answers only while it is served. Parking the
			// task here instead leaves the greeter published and unreachable,
			// and the dialing half waits on a fetch nobody will answer.
			let _ = session.serve().await;
		}
		Err(_) => {}
	}
}

async fn scene_happy() -> Result<(), String> {
	let server = Rc::new(listen(SEED_HAPPY).await?);
	let (published_tx, published_rx) = oneshot::channel::<()>();
	let host = {
		let server = Rc::clone(&server);
		tokio::task::spawn_local(async move { host_one(server, published_tx).await })
	};
	let partner = server.locator().map_err(|e| e.to_string())?;
	call_greeter(&partner, published_rx).await?;
	drop(host);
	println!("rust-keyed-tcp-restart: happy path ok");
	Ok(())
}

async fn scene_squatter() -> Result<(), String> {
	let honest = listen(SEED_HONEST).await?;
	let designator = honest.locator().map_err(|e| e.to_string())?.designator;
	drop(honest);

	let squatter = Rc::new(listen(SEED_SQUATTER).await?);
	let host = {
		let squatter = Rc::clone(&squatter);
		tokio::task::spawn_local(async move {
			let _ = squatter.accept().await;
		})
	};
	let partner = tcp::keyed::locator(&designator, "127.0.0.1", squatter.port().map_err(|e| e.to_string())?);
	let runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
		.await
		.map_err(|e| e.to_string())?;
	match runtime.connect(&partner, ConnectOptions::default()).await {
		Ok(_session) => return Err("squatter dial should have been refused".into()),
		Err(e) => println!("rust-keyed-tcp-restart: squatter refused ({e})"),
	}
	drop(host);
	println!("rust-keyed-tcp-restart: squatter refusal ok");
	Ok(())
}

async fn scene_restart() -> Result<(), String> {
	let first = Rc::new(listen(SEED_RESTART).await?);
	let designator = first.locator().map_err(|e| e.to_string())?.designator;
	let (published_tx, published_rx) = oneshot::channel::<()>();
	let host = {
		let first = Rc::clone(&first);
		tokio::task::spawn_local(async move { host_one(first, published_tx).await })
	};
	call_greeter(&first.locator().map_err(|e| e.to_string())?, published_rx).await?;
	drop(host);
	drop(first);

	let second = Rc::new(listen(SEED_RESTART).await?);
	let second_designator = second.locator().map_err(|e| e.to_string())?.designator;
	if second_designator != designator {
		return Err(format!(
			"restart designator drifted: {designator} vs {second_designator}",
		));
	}
	let (published_tx, published_rx) = oneshot::channel::<()>();
	let host = {
		let second = Rc::clone(&second);
		tokio::task::spawn_local(async move { host_one(second, published_tx).await })
	};
	call_greeter(&second.locator().map_err(|e| e.to_string())?, published_rx).await?;
	drop(host);
	println!("rust-keyed-tcp-restart: restart ok");
	Ok(())
}

fn main() {
	let rt = tokio::runtime::Builder::new_current_thread()
		.enable_all()
		.build()
		.unwrap();
	let local = LocalSet::new();
	local.block_on(&rt, async {
		scene_happy().await.expect("happy");
		scene_squatter().await.expect("squatter");
		scene_restart().await.expect("restart");
		println!("rust-keyed-tcp-restart: all scenes ok");
	});
}
