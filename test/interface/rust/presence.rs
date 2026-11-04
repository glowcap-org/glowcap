//! Raw arguments distinguish omission from wire void on both negotiated profiles.
use crate::{callbacks, expected, pair::Pair};
use glowcap::{Argument, Host, HostOptions, HostProfile, Ref, Resolver};
use std::{cell::RefCell, rc::Rc};

#[derive(Default)]
struct State {
	calls: Vec<(String, usize)>,
	resolver: Option<Resolver>,
	outcome: u8,
}

pub async fn run() {
	for profile in [HostProfile::Interop, HostProfile::Glowcap] {
		scenario(profile).await;
	}
}

async fn scenario(profile: HostProfile) {
	let options = HostOptions::with_profile(profile);
	let host = Host::with_options(options).unwrap();
	let local_reader = host.spawn(|_, _| Ok(Argument::Void)).unwrap();
	let state = Rc::new(RefCell::new(State::default()));
	let captured = state.clone();
	let owner = host.clone();
	let published_reader = local_reader.clone();
	host.publish("presence", move || {
		let state = captured.clone();
		let owner = owner.clone();
		let reader = published_reader.clone();
		Box::new(move |verb, args| {
			let verb = verb.unwrap();
			if verb == "pending" {
				state.borrow_mut().resolver = Some(owner.defer_turn().unwrap());
				return Ok(Argument::Void);
			}
			if verb == "reader" {
				return Ok((&reader).into());
			}
			let case = match verb {
				"required" => "void",
				"optional" | "notify" | "value" => match args.len() {
					0 => "absent",
					1 if matches!(args[0], Argument::Void) => "void",
					_ => "one",
				},
				"suffix" => {
					if args.len() == 1 {
						"one"
					} else {
						"text-void"
					}
				}
				"pair" => match args.len() {
					0 => "absent",
					1 => "one",
					_ => "two",
				},
				"references" => {
					assert!(args.len() <= 2);
					for argument in args {
						let _ = Ref::try_from(argument).unwrap();
					}
					if args.len() == 2 {
						assert!(state.borrow().resolver.is_some(), "pending argument was awaited");
					}
					state.borrow_mut().calls.push((verb.into(), args.len()));
					return Ok(Argument::Void);
				}
				_ => panic!("unexpected presence method"),
			};
			assert_eq!(args, expected::presence_arguments(case));
			if verb == "notify" {
				assert!(owner.defer_turn_if_answer().unwrap().is_none());
			}
			let mut state = state.borrow_mut();
			state.calls.push((verb.into(), args.len()));
			match state.outcome {
				1 => Ok(Argument::String("wrong void result".into())),
				2 => Err("presence refusal".into()),
				_ => Ok(Argument::Void),
			}
		})
	})
	.unwrap();
	let pair = Pair::open(&host, options).await;
	let target = pair.client.fetch("presence").await.unwrap();
	let client = &pair.client;

	let unobserved = callbacks::presence_optional(client, &target, None).unwrap();
	let _raw_handle = unobserved.raw();
	callbacks::presence_required(client, &target, ()).await.unwrap();
	assert_eq!(
		state.borrow().calls[0],
		("optional".into(), 0),
		"optional send was lazy"
	);
	unobserved.await.unwrap();
	callbacks::presence_optional(client, &target, Some(()))
		.unwrap()
		.await
		.unwrap();
	assert_eq!(state.borrow().calls.last().unwrap().1, 1);
	callbacks::presence_suffix(client, &target, "first", None)
		.unwrap()
		.await
		.unwrap();
	assert_eq!(state.borrow().calls.last().unwrap().1, 1);
	callbacks::presence_suffix(client, &target, "first", Some(()))
		.unwrap()
		.await
		.unwrap();
	assert_eq!(state.borrow().calls.last().unwrap().1, 2);
	callbacks::presence_pair(client, &target, None, None)
		.unwrap()
		.await
		.unwrap();
	callbacks::presence_pair(client, &target, Some("first"), None)
		.unwrap()
		.await
		.unwrap();
	callbacks::presence_pair(client, &target, Some("first"), Some("second"))
		.unwrap()
		.await
		.unwrap();
	let before = state.borrow().calls.len();
	assert!(matches!(
		callbacks::presence_pair(client, &target, None, Some("second")),
		Err(callbacks::Error::InvalidArgument)
	));
	callbacks::presence_required(client, &target, ()).await.unwrap();
	assert_eq!(state.borrow().calls.len(), before + 1, "a hole admitted a call");

	for (value, arity) in [(None, 0), (Some(Argument::Void), 1), (Some("first".into()), 1)] {
		callbacks::presence_value(client, &target, value)
			.unwrap()
			.await
			.unwrap();
		assert_eq!(state.borrow().calls.last().unwrap().1, arity);
	}
	callbacks::presence_notify(client, &target, None).unwrap();
	callbacks::presence_notify(client, &target, Some(())).unwrap();
	callbacks::presence_required(client, &target, ()).await.unwrap();

	assert_eq!(
		state
			.borrow()
			.calls
			.iter()
			.filter(|(verb, _)| verb == "notify")
			.map(|(_, count)| *count)
			.collect::<Vec<_>>(),
		[0, 1]
	);
	let reader = Ref::try_from(&client.send(&target, "reader", &[]).await.unwrap()).unwrap();
	callbacks::presence_references(client, &target, None, None)
		.unwrap()
		.await
		.unwrap();
	assert_eq!(state.borrow().calls.last().unwrap().1, 0);
	callbacks::presence_references(client, &target, Some((&reader).into()), None)
		.unwrap()
		.await
		.unwrap();
	assert_eq!(state.borrow().calls.last().unwrap().1, 1);
	let pending = client.send(&target, "pending", &[]);
	callbacks::presence_references(client, &target, Some((&pending).into()), None)
		.unwrap()
		.await
		.unwrap();
	assert_eq!(state.borrow().calls.last().unwrap().1, 1);
	assert!(
		state.borrow().resolver.is_some(),
		"plain interface argument was awaited"
	);
	let before = state.borrow().calls.len();
	assert!(matches!(
		callbacks::presence_references(client, &target, None, Some((&pending).into())),
		Err(callbacks::Error::InvalidArgument)
	));
	callbacks::presence_references(client, &target, Some((&reader).into()), Some((&pending).into()))
		.unwrap()
		.await
		.unwrap();
	assert_eq!(state.borrow().calls.len(), before + 1);
	assert_eq!(state.borrow().calls.last().unwrap().1, 2);
	let mut resolver = state.borrow_mut().resolver.take().unwrap();
	resolver.fulfill_value(&Argument::from(&local_reader)).unwrap();
	let _ = pending.await.unwrap();

	state.borrow_mut().outcome = 1;
	assert!(matches!(
		callbacks::presence_required(client, &target, ()).await,
		Err(callbacks::Error::InvalidReply)
	));
	state.borrow_mut().outcome = 2;
	match callbacks::presence_optional(client, &target, None).unwrap().await {
		Err(callbacks::Error::Runtime(error)) => assert!(error.to_string().contains("presence refusal")),
		_ => panic!("optional call lost runtime failure"),
	}
	state.borrow_mut().outcome = 0;
	callbacks::presence_required(client, &target, ()).await.unwrap();
	pair.close().await;
}
