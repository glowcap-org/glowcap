//! Raw peer expectations are generated from messages.syrup independently of
//! contracts.syrup. A bad public reply must preserve the committed effect and
//! exact request, and a remote refusal must retain its original diagnostic.
use super::interface;
use glowcap::{Argument, ConnectOptions, Host, ListenerIdentity, PendingWork, Runtime, RuntimeConfig, tcp};
use std::{cell::RefCell, rc::Rc};
#[path = "../generated/expected.rs"]
mod expected;

#[derive(Default)]
struct State {
	sequence: Option<Argument>,
	broken: bool,
	queries: usize,
	deliveries: usize,
	effects: usize,
}

pub async fn run() {
	let host = Host::with_options(Default::default()).unwrap();
	let state = Rc::new(RefCell::new(State::default()));
	let captured = state.clone();
	host.publish("fixture", move || {
		let state = captured.clone();
		Box::new(move |verb, args| {
			let mut state = state.borrow_mut();
			if verb == "mutation-sequence" {
				assert!(args.is_empty());
				state.queries += 1;
				return Ok(state.sequence.clone().unwrap_or_else(|| 1i64.into()));
			}
			assert_eq!(verb, expected::CREATION_VERB);
			assert_eq!(args, expected::creation_arguments().as_slice());
			state.deliveries += 1;
			state.effects = 1;
			if state.broken {
				Err("independent refusal".into())
			} else {
				Ok(Argument::String("wrong capability result".into()))
			}
		})
	})
	.unwrap();
	let server = tcp::listen(
		"127.0.0.1",
		0,
		tcp::ListenOptions {
			identity: ListenerIdentity::Host(host.clone()),
			..Default::default()
		},
	)
	.await
	.unwrap();
	let runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
		.await
		.unwrap();
	let locator = server.locator().unwrap();
	let (client, accepted) = tokio::join!(runtime.connect(&locator, ConnectOptions::default()), server.accept());
	let client = Rc::new(client.unwrap());
	let accepted = accepted.unwrap();
	let serving = tokio::task::spawn_local(async move { accepted.serve().await });
	let target = client.fetch("fixture").await.unwrap();
	for bad in [
		Argument::String("wrong sequence".into()),
		0i64.into(),
		(-1i64).into(),
		Argument::Float(1.0),
	] {
		state.borrow_mut().sequence = Some(bad);
		let prepared = interface::prepare_add(client.clone(), target.clone(), "write tests").unwrap();
		assert!(matches!(prepared.await, Err(interface::Error::InvalidSequence)));
		assert_eq!(state.borrow().deliveries, 0);
	}
	state.borrow_mut().sequence = None;
	let prepared = interface::prepare_add(client.clone(), target.clone(), "write tests")
		.unwrap()
		.await
		.unwrap();
	assert!(matches!(prepared.submit().await, Err(interface::Error::InvalidReply)));
	assert_eq!(state.borrow().effects, 1);
	assert!(matches!(prepared.submit().await, Err(interface::Error::InvalidReply)));
	assert_eq!(state.borrow().deliveries, 2);
	assert_eq!(state.borrow().queries, 5, "replay must not acquire a sequence");
	state.borrow_mut().broken = true;
	match prepared.submit().await {
		Err(interface::Error::Runtime(error)) => assert!(error.to_string().contains("independent refusal")),
		_ => panic!("remote break must preserve its original failure"),
	}
	assert_eq!(state.borrow().effects, 1);
	drop(prepared);
	client.close(PendingWork::Cancel).await.unwrap();
	server.close().await.unwrap();
	runtime.close(PendingWork::Cancel).await.unwrap();
	host.close(PendingWork::Cancel).await.unwrap();
	serving.await.unwrap().unwrap();
}
