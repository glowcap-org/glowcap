//! Per-binding keyed-tcp restart proof (ADR-0075): happy path, key-squatter
//! refusal, and same-seed-fresh-port restart — the Rust sibling of
//! `test/driver/keyed_tcp_restart_test.zig`.
//!
//! Run via `zig build rust-keyed-tcp-restart` (needs cargo).

use std::rc::Rc;

use pancake_rust_dogfood::{
	connect, keyed_tcp_locator, listen_keyed_tcp, Argument, KeyedTcpServer, Session,
};
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

/// Dial, wait until the host has published, then fetch/call. `connect` must run
/// concurrently with `accept` so the listener unblocks; the oneshot orders
/// publish ahead of fetch.
async fn call_greeter(uri: &str, published: oneshot::Receiver<()>) -> Result<(), String> {
	let session = connect(uri, None, None).await.map_err(|e| e.to_string())?;
	let _ = published.await;
	let greeter = session.fetch("greeter").await.map_err(|e| e.to_string())?;
	let reply = session
		.send(&greeter, "greet", &[])
		.await
		.map_err(|e| e.to_string())?;
	match reply {
		Argument::String(s) if s == GREETING => Ok(()),
		other => Err(format!("unexpected greeting: {other:?}")),
	}
}

async fn host_one(server: Rc<KeyedTcpServer>, published: oneshot::Sender<()>) {
	match server.accept().await {
		Ok(session) => {
			if session.publish("greeter", greeter).is_ok() {
				let _ = published.send(());
			}
			let _served: Session = session;
			std::future::pending::<()>().await;
		}
		Err(_) => {}
	}
}

async fn scene_happy() -> Result<(), String> {
	let server = Rc::new(
		listen_keyed_tcp("127.0.0.1", 0, Some(SEED_HAPPY))
			.await
			.map_err(|e| e.to_string())?,
	);
	let (published_tx, published_rx) = oneshot::channel::<()>();
	let host = {
		let server = Rc::clone(&server);
		tokio::task::spawn_local(async move { host_one(server, published_tx).await })
	};
	let uri = server.uri().map_err(|e| e.to_string())?;
	call_greeter(&uri, published_rx).await?;
	drop(host);
	println!("rust-keyed-tcp-restart: happy path ok");
	Ok(())
}

async fn scene_squatter() -> Result<(), String> {
	let honest = listen_keyed_tcp("127.0.0.1", 0, Some(SEED_HONEST))
		.await
		.map_err(|e| e.to_string())?;
	let designator = honest.designator().to_string();
	drop(honest);

	let squatter = Rc::new(
		listen_keyed_tcp("127.0.0.1", 0, Some(SEED_SQUATTER))
			.await
			.map_err(|e| e.to_string())?,
	);
	let host = {
		let squatter = Rc::clone(&squatter);
		tokio::task::spawn_local(async move {
			let _ = squatter.accept().await;
		})
	};
	let addr = squatter.local_addr().map_err(|e| e.to_string())?;
	let uri = keyed_tcp_locator(&designator, &addr.ip().to_string(), addr.port());
	match connect(&uri, None, None).await {
		Ok(_session) => return Err("squatter dial should have been refused".into()),
		Err(e) => println!("rust-keyed-tcp-restart: squatter refused ({e})"),
	}
	drop(host);
	println!("rust-keyed-tcp-restart: squatter refusal ok");
	Ok(())
}

async fn scene_restart() -> Result<(), String> {
	let first = Rc::new(
		listen_keyed_tcp("127.0.0.1", 0, Some(SEED_RESTART))
			.await
			.map_err(|e| e.to_string())?,
	);
	let designator = first.designator().to_string();
	let (published_tx, published_rx) = oneshot::channel::<()>();
	let host = {
		let first = Rc::clone(&first);
		tokio::task::spawn_local(async move { host_one(first, published_tx).await })
	};
	call_greeter(&first.uri().map_err(|e| e.to_string())?, published_rx).await?;
	drop(host);
	drop(first);

	let second = Rc::new(
		listen_keyed_tcp("127.0.0.1", 0, Some(SEED_RESTART))
			.await
			.map_err(|e| e.to_string())?,
	);
	if second.designator() != designator {
		return Err(format!(
			"restart designator drifted: {designator} vs {}",
			second.designator()
		));
	}
	let (published_tx, published_rx) = oneshot::channel::<()>();
	let host = {
		let second = Rc::clone(&second);
		tokio::task::spawn_local(async move { host_one(second, published_tx).await })
	};
	let addr = second.local_addr().map_err(|e| e.to_string())?;
	call_greeter(
		&keyed_tcp_locator(&designator, &addr.ip().to_string(), addr.port()),
		published_rx,
	)
	.await?;
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
