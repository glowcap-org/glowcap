//! Retained pending arguments against a raw receipt actor. The sequence reply
//! stays parked while the original handle is dropped or observed independently.
use crate::{callbacks, expected, pair::Pair};
use glowcap::{Argument, CaptpVersion, Codec, Host, HostOptions, Ref, Resolver};
use std::{
	cell::{Cell, RefCell},
	rc::Rc,
};

#[derive(Default)]
struct State {
	source: Option<Resolver>,
	sequence: Option<Resolver>,
	queries: usize,
	deliveries: usize,
	effects: usize,
	arguments: Vec<Argument>,
}
#[derive(Clone, Copy, Debug)]
enum Outcome {
	Data,
	Capability,
	Broken,
}

struct Reclaimed(Rc<Cell<usize>>);
impl Drop for Reclaimed {
	fn drop(&mut self) {
		self.0.set(self.0.get() + 1);
	}
}

fn publish(host: &Host, state: &Rc<RefCell<State>>) {
	let owner = host.clone();
	let captured = state.clone();
	host.publish("prepared", move || {
		let state = captured.clone();
		let owner = owner.clone();
		Box::new(move |verb, args| {
			match verb {
				Some("source") => {
					assert!(args.is_empty());
					let resolver = owner.defer_turn().unwrap();
					assert!(state.borrow_mut().source.replace(resolver).is_none());
				}
				Some("mutation-sequence") => {
					assert!(args.is_empty());
					let resolver = owner.defer_turn().unwrap();
					let mut state = state.borrow_mut();
					state.queries += 1;
					assert!(state.sequence.replace(resolver).is_none());
				}
				Some(expected::PREPARED_VERB) => {
					assert_eq!(args.len(), 3);
					assert_eq!(args[0].as_i64(), Some(expected::PREPARED_SEQUENCE));
					assert_eq!(args[1].as_str(), Some(expected::PREPARED_OPERATION));
					let argument = args[2].clone();
					let mut state = state.borrow_mut();
					state.deliveries += 1;
					if state.arguments.is_empty() {
						state.effects += 1;
					}
					state.arguments.push(argument);
				}
				Some("barrier") => assert!(args.is_empty()),
				_ => return Err("unknown prepared-fixture method".into()),
			}
			Ok(Argument::Void)
		})
	})
	.unwrap();
}

async fn barrier(pair: &Pair, root: &Ref) {
	assert!(matches!(
		pair.client.send(root, "barrier", &[]).await.unwrap(),
		Argument::Void
	));
}

fn settle(host: &Host, state: &Rc<RefCell<State>>, outcome: Outcome, reclaimed: &Rc<Cell<usize>>) {
	let mut resolver = state.borrow_mut().source.take().unwrap();
	match outcome {
		Outcome::Data => resolver.fulfill(&Argument::String("held data".into())).unwrap(),
		Outcome::Broken => resolver.break_with("held refusal").unwrap(),
		Outcome::Capability => {
			let watch = Reclaimed(reclaimed.clone());
			let reader = host
				.spawn(move |verb, args| {
					let _keep = &watch;
					assert_eq!(verb, Some("read"));
					assert!(args.is_empty());
					Ok(Argument::String("held reader".into()))
				})
				.unwrap();
			resolver.fulfill_value(&(&reader).into()).unwrap();
		}
	}
}

fn check(result: glowcap::Result<Argument>, outcome: Outcome) -> Option<Ref> {
	match outcome {
		Outcome::Data => assert_eq!(result.unwrap().as_str(), Some("held data")),
		Outcome::Capability => return Some(Ref::try_from(&result.unwrap()).unwrap()),
		Outcome::Broken => assert_eq!(result.unwrap_err().message(), Some("held refusal")),
	}
	None
}

pub async fn run() {
	for (codec, version) in [(Codec::Syrup, CaptpVersion::V1_0), (Codec::Capnp, CaptpVersion::Next)] {
		for outcome in [Outcome::Data, Outcome::Capability, Outcome::Broken] {
			for settled in [false, true] {
				for observe in [false, true] {
					scenario(codec, version, outcome, settled, observe).await;
				}
			}
		}
		abandon(codec, version, false).await;
		abandon(codec, version, true).await;
	}
}

async fn scenario(codec: Codec, version: CaptpVersion, outcome: Outcome, settled: bool, observe: bool) {
	let host = Host::with_options(HostOptions {
		codec,
		captp_version: version,
		..Default::default()
	})
	.unwrap();
	let state = Rc::new(RefCell::new(State::default()));
	publish(&host, &state);
	let pair = Pair::open(
		&host,
		HostOptions {
			codec,
			captp_version: version,
			..Default::default()
		},
	)
	.await;
	let profile = pair.client.profile().unwrap();
	assert_eq!(profile.codec, codec);
	assert_eq!(profile.captp_version, version);
	let root = pair.client.fetch("prepared").await.unwrap();
	let original = pair.client.send(&root, "source", &[]);
	barrier(&pair, &root).await;
	let reclaimed = Rc::new(Cell::new(0));
	if settled {
		settle(&host, &state, outcome, &reclaimed);
		barrier(&pair, &root).await;
	}
	let preparation = callbacks::prepare_accept(pair.client.clone(), root.clone(), &original).unwrap();
	barrier(&pair, &root).await;
	assert_eq!(state.borrow().queries, 1);
	assert_eq!(state.borrow().deliveries, 0);
	let mut original = Some(original);
	if !observe {
		drop(original.take());
		barrier(&pair, &root).await;
	}
	if !settled && observe {
		settle(&host, &state, outcome, &reclaimed);
	}
	if let Some(original) = original {
		check(original.await, outcome);
	}
	barrier(&pair, &root).await;
	state
		.borrow_mut()
		.sequence
		.take()
		.unwrap()
		.fulfill(&expected::PREPARED_SEQUENCE.into())
		.unwrap();
	let request = preparation.await.unwrap();
	request.submit().await.unwrap();
	request.submit().await.unwrap();
	assert_eq!(state.borrow().deliveries, 2);
	assert_eq!(state.borrow().effects, 1);
	assert_eq!(state.borrow().queries, 1, "replay reacquired its sequence");
	if !settled && !observe {
		settle(&host, &state, outcome, &reclaimed);
	}
	let arguments = std::mem::take(&mut state.borrow_mut().arguments);
	if !settled && !observe {
		assert_eq!(arguments[0], arguments[1], "replay changed pending promise identity");
	}
	let mut authority: Option<Ref> = None;
	let mut observed_promise: Option<Ref> = None;
	for argument in arguments {
		let observed = match argument {
			Argument::Reference(reference) => {
				// Replay of one imported promise has the same settlement. Next
				// permits one settling listener across the wire for that identity.
				if observed_promise.as_ref() == Some(&reference) {
					continue;
				}
				let result = pair.accepted.resolve(&reference).await;
				observed_promise = Some(reference);
				result
			}
			value => Ok(value),
		};
		if let Some(reference) = check(observed, outcome) {
			if let Some(first) = &authority {
				assert_eq!(first, &reference, "replay changed capability authority");
			} else {
				authority = Some(reference);
			}
		}
	}
	drop(observed_promise);
	drop(authority);
	assert_eq!(reclaimed.get(), 0, "prepared request lost its argument");
	drop(request);

	barrier(&pair, &root).await;
	pair.close().await;
	if matches!(outcome, Outcome::Capability) {
		assert_eq!(reclaimed.get(), 1, "Port teardown leaked its exported actor root");
	}
}

async fn abandon(codec: Codec, version: CaptpVersion, invalid_sequence: bool) {
	let host = Host::with_options(HostOptions {
		codec,
		captp_version: version,
		..Default::default()
	})
	.unwrap();
	let state = Rc::new(RefCell::new(State::default()));
	publish(&host, &state);
	let pair = Pair::open(
		&host,
		HostOptions {
			codec,
			captp_version: version,
			..Default::default()
		},
	)
	.await;
	let profile = pair.client.profile().unwrap();
	assert_eq!(profile.codec, codec);
	assert_eq!(profile.captp_version, version);
	let root = pair.client.fetch("prepared").await.unwrap();
	let original = pair.client.send(&root, "source", &[]);
	barrier(&pair, &root).await;
	let foreign_host = Host::with_options(Default::default()).unwrap();
	let foreign_state = Rc::new(RefCell::new(State::default()));
	publish(&foreign_host, &foreign_state);
	let foreign = Pair::open(&foreign_host, Default::default()).await;
	let foreign_root = foreign.client.fetch("prepared").await.unwrap();
	match callbacks::prepare_accept(foreign.client.clone(), foreign_root.clone(), &original) {
		Err(callbacks::Error::Runtime(error)) => assert_eq!(error.kind(), glowcap::ErrorKind::InvalidArgument),
		_ => panic!("foreign argument preparation was admitted"),
	}
	barrier(&foreign, &foreign_root).await;
	assert_eq!(
		foreign_state.borrow().queries,
		0,
		"foreign preparation acquired a sequence"
	);
	foreign.close().await;
	let preparation = callbacks::prepare_accept(pair.client.clone(), root.clone(), &original).unwrap();
	barrier(&pair, &root).await;
	let reclaimed = Rc::new(Cell::new(0));
	settle(&host, &state, Outcome::Capability, &reclaimed);
	drop(original);
	if invalid_sequence {
		state
			.borrow_mut()
			.sequence
			.take()
			.unwrap()
			.fulfill(&0i64.into())
			.unwrap();
		assert!(matches!(preparation.await, Err(callbacks::Error::InvalidSequence)));
	} else {
		drop(preparation);
		state
			.borrow_mut()
			.sequence
			.take()
			.unwrap()
			.fulfill(&1i64.into())
			.unwrap();
	}
	barrier(&pair, &root).await;
	assert_eq!(state.borrow().deliveries, 0);
	pair.close().await;
	assert_eq!(
		reclaimed.get(),
		1,
		"abandoned preparation retained its actor after Port teardown"
	);
}
