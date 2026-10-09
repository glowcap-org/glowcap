//! Real shared binding execution under a browser-driven LocalSet. The byte
//! channel is deterministic; browser sockets are a separate integration seam.
#[path = "browser_archive.rs"]
mod browser_archive;
#[path = "browser_channels.rs"]
mod browser_channels;
#[path = "browser_ice.rs"]
mod browser_ice;
#[path = "browser_relay.rs"]
mod browser_relay;
#[path = "browser_signaling.rs"]
mod browser_signaling;
#[path = "browser_storage.rs"]
mod browser_storage;
#[path = "packet_channel.rs"]
mod packet_channel;

use glowcap::{Argument, Host, HostOptions, Locator, PendingWork, Session};
use rooms_browser::platform::Platform;
use rooms_glowcap::client::{Client, directory::Directory};
use std::{cell::Cell, rc::Rc, time::Duration};
use wasm_bindgen::prelude::*;

#[wasm_bindgen]
pub async fn rooms_browser_host_contract() -> Result<(), JsValue> {
	install_panic_hook();
	// LocalSet is polled by wasm-bindgen's browser executor. It retains Tokio's
	// task cancellation and join semantics without a native runtime or reactor.
	tokio::task::LocalSet::new()
		.run_until(async { run().await.map_err(|error| JsValue::from_str(&error)) })
		.await
}

pub(crate) fn install_panic_hook() {
	std::panic::set_hook(Box::new(|panic| report_panic(&panic.to_string())));
}

#[wasm_bindgen]
extern "C" {
	#[wasm_bindgen(js_namespace = console, js_name = error)]
	fn report_panic(message: &str);
}

async fn run() -> Result<(), String> {
	crate::content_policy::run();
	packet_channel::run().await;
	let caller = Host::with_options(HostOptions::default()).map_err(message)?;
	let server = Host::with_options(HostOptions::default()).map_err(message)?;
	assert_ne!(
		caller.designator().map_err(message)?,
		server.designator().map_err(message)?
	);
	server
		.publish(rooms_application::directory::NAME, || {
			Box::new(|verb, args| match (verb, args) {
				(rooms_application::directory::LIST, []) => Ok(Argument::List(Vec::new())),
				(rooms_application::directory::creation::LOCATION, []) => {
					Ok(Argument::String("ocapn://127.0.0.1:9000?transport=tcp".into()))
				}
				_ => Err("unexpected directory call".into()),
			})
		})
		.map_err(message)?;
	server
		.publish("echo", || Box::new(|_, args| Ok(Argument::List(args.to_vec()))))
		.map_err(message)?;
	let (left, right) = tokio::io::duplex(4096);
	let locator = Locator::bare("tcp", "127.0.0.1:9000");
	let budget = Some(Duration::from_secs(2));
	let (dialed, accepted) = tokio::join!(
		Session::dial_over(&caller, &locator, left, budget),
		Session::accept_over(&server, "tcp", "127.0.0.1:9000", "127.0.0.1:9000", right, budget),
	);
	let dialed = dialed.map_err(message)?;
	let accepted = accepted.map_err(message)?;
	let client = Client::new(dialed, Platform::new().unwrap());
	let directory = Directory::fetch(client.clone()).await.map_err(message)?;
	assert!(directory.list().await.map_err(message)?.is_empty());
	assert_eq!(
		directory.advertised_location().await.map_err(message)?,
		"ocapn://127.0.0.1:9000?transport=tcp"
	);
	let echo = client.session().fetch("echo").await.map_err(message)?;
	let seen = Rc::new(Cell::new(0));
	let captured = Rc::clone(&seen);
	let callback = client
		.session()
		.spawn_owned(move |_, _| {
			captured.set(captured.get() + 1);
			Ok(Argument::String("callback".into()))
		})
		.map_err(message)?;
	let payload = vec![
		Argument::Integer(i64::MIN),
		Argument::Bytes(vec![0xab; 131_072]),
		Argument::String("multiple rooms: café / garden".into()),
		Argument::Reference(callback.clone()),
	];
	let reply = client
		.session()
		.send(&echo, "roundtrip", &payload)
		.await
		.map_err(message)?;
	let Argument::List(reply) = reply else {
		return Err("echo did not return its argument list".into());
	};
	assert_eq!(&reply[..3], &payload[..3]);
	let Argument::Reference(returned) = &reply[3] else {
		return Err("callback lost its capability kind".into());
	};
	assert_eq!(
		client.session().send(returned, "call", &[]).await.map_err(message)?,
		Argument::String("callback".into())
	);
	assert_eq!(seen.get(), 1);
	browser_archive::exercise(&client, &accepted, &locator).await;

	// A retained remote resolver holds pending work while finite close expires.
	let (tx, mut rx) = tokio::sync::mpsc::channel(1);
	let deferred_host = server.clone();
	server
		.publish("pending", move || {
			Box::new(move |_, _| {
				tx.try_send(deferred_host.defer_turn().map_err(message)?)
					.map_err(message)?;
				Ok(Argument::Void)
			})
		})
		.map_err(message)?;
	let pending = client.session().fetch("pending").await.map_err(message)?;
	let awaiting = client.session().borrowed();
	let task = tokio::task::spawn_local(async move { awaiting.send(&pending, "wait", &[]).await });
	let resolver = rx.recv().await.ok_or("pending call did not reach its behavior")?;
	let result = client
		.session()
		.close(PendingWork::Finish {
			grace: Some(Duration::from_millis(20)),
		})
		.await;
	assert!(result.is_err_and(|error| error.kind() == glowcap::ErrorKind::TimedOut));
	assert!(task.await.map_err(message)?.is_err());
	drop(resolver);
	drop((reply, payload, callback, echo, directory, client));
	caller.close(PendingWork::Cancel).await.map_err(message)?;
	let _ = accepted.close(PendingWork::Cancel).await;
	drop(accepted);
	server.close(PendingWork::Cancel).await.map_err(message)?;

	// Both establishment directions bound a silent byte-channel partner using
	// real browser timers. The unused halves remain live until refusal arrives.
	for dial in [true, false] {
		let host = Host::with_options(Default::default()).map_err(message)?;
		let (wire, silent) = tokio::io::duplex(4096);
		let budget = Some(Duration::from_millis(20));
		let result = if dial {
			Session::dial_over(&host, &locator, wire, budget).await
		} else {
			Session::accept_over(&host, "tcp", "127.0.0.1:9000", "127.0.0.1:9000", wire, budget).await
		};
		assert!(result.is_err_and(|error| error.kind() == glowcap::ErrorKind::TimedOut));
		drop(silent);
		host.close(PendingWork::Cancel).await.map_err(message)?;
	}
	Ok(())
}

fn message(error: impl core::fmt::Display) -> String {
	error.to_string()
}
