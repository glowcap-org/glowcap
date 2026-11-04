//! A rejected sequence reply must release its capability before session close.
//! Syrup's GC message observes the actual generated consumer, not actor lifetime.
use crate::{interface, pair::Pair};
use glowcap::{Argument, Host, HostOptions, HostProfile, tcp};
use std::{cell::Cell, rc::Rc};
use tokio::{
	io::{AsyncReadExt, AsyncWriteExt},
	net::{TcpListener, TcpStream},
};

pub async fn run() {
	for automatic in [true, false] {
		let options = HostOptions::with_profile(HostProfile::Interop);
		let host = Host::with_options(options).unwrap();
		let child = host.spawn(|_, _| Ok(Argument::Void)).unwrap();
		host.publish("sequence", move || {
			let child = child.clone();
			Box::new(move |verb, _| match verb {
				Some("mutation-sequence") => Ok((&child).into()),
				Some("barrier") => Ok(Argument::Void),
				_ => panic!("invalid sequence admitted a mutation"),
			})
		})
		.unwrap();
		let client = Host::with_options(options).unwrap();
		client.set_release_on_drop(automatic).unwrap();
		let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
		let port = listener.local_addr().unwrap().port();
		let releases = Rc::new(Cell::new(0));
		let seen = releases.clone();
		let mut proxy = None;
		let pair = Pair::open_routed(&host, &client, |locator| {
			proxy = Some(tokio::task::spawn_local(async move {
				let (mut incoming, _) = listener.accept().await.unwrap();
				let mut outgoing = TcpStream::connect(&locator.designator).await.unwrap();
				let (mut from_client, mut to_client) = incoming.split();
				let (mut from_server, mut to_server) = outgoing.split();
				let forward = async {
					let mut buffer = [0; 4096];
					let mut tail = Vec::new();
					// This fixture's data contains no message names.
					let needle = b"op:gc-exports";
					loop {
						let n = from_client.read(&mut buffer).await?;
						if n == 0 {
							return to_server.shutdown().await;
						}
						tail.extend_from_slice(&buffer[..n]);
						seen.set(seen.get() + tail.windows(needle.len()).filter(|w| *w == needle).count());
						let keep = tail.len().min(needle.len() - 1);
						tail.drain(..tail.len() - keep);
						to_server.write_all(&buffer[..n]).await?;
					}
				};
				tokio::try_join!(forward, tokio::io::copy(&mut from_server, &mut to_client)).unwrap();
			}));
			tcp::locator("127.0.0.1", port)
		})
		.await;
		let target = pair.client.fetch("sequence").await.unwrap();
		let preparation = interface::prepare_add(pair.client.clone(), target.clone(), "task").unwrap();
		assert!(matches!(preparation.await, Err(interface::Error::InvalidSequence)));
		pair.client.send(&target, "barrier", &[]).await.unwrap();
		assert_eq!(releases.get(), 1, "sequence reply leaked with automatic={automatic}");
		pair.client.release(target).unwrap();
		pair.close().await;
		proxy.unwrap().await.unwrap();
	}
}

#[cfg(test)]
#[tokio::test]
async fn rejected_sequence_reply_releases_capability() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(std::time::Duration::from_secs(10), run())
				.await
				.unwrap();
		})
		.await;
}
