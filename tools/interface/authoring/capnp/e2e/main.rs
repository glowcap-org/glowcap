//! One frontend integration call; shared runtime qualification is not repeated.
#[path = "../../../../../test/interface/rust/pair.rs"]
mod pair;
#[allow(dead_code)]
mod generated {
	include!(env!("CAPNP_AUTHORING_RS"));
}
use glowcap::{Argument, Host, HostOptions, HostProfile};
use std::{cell::Cell, rc::Rc, time::Duration};

#[tokio::main(flavor = "current_thread")]
async fn main() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(20), scenario())
				.await
				.expect("Cap'n Proto frontend integration exceeded 20 seconds");
		})
		.await;
}
async fn scenario() {
	let options = HostOptions::with_profile(HostProfile::Interop);
	let host = Host::with_options(options).unwrap();
	let count = Rc::new(Cell::new(0));
	let observed = count.clone();
	host.publish("reader", move || {
		let observed = observed.clone();
		Box::new(move |verb, arguments| {
			assert_eq!(verb, Some("read"));
			assert!(arguments.is_empty());
			observed.set(observed.get() + 1);
			Ok(Argument::String("authored Cap'n Proto reader".into()))
		})
	})
	.unwrap();
	let pair = pair::Pair::open(&host, options).await;
	assert_eq!(pair.accepted.profile().unwrap().codec, options.codec);
	let reader = pair.client.fetch("reader").await.unwrap();
	let reply = generated::authoring_read(&pair.client, &reader).await.unwrap();
	assert_eq!(reply, "authored Cap'n Proto reader");
	assert_eq!(count.get(), 1);
	pair.close().await;
}
