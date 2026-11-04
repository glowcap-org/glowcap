//! The actual Tasks read projection meets independently authored raw peer replies.
use crate::{interface, pair::Pair};
use glowcap::{Argument, Host, HostOptions, HostProfile};
use std::{cell::RefCell, rc::Rc};

struct State {
	calls: Vec<(String, Vec<Argument>)>,
	name: Argument,
	count: Argument,
	text: Argument,
	wrong_reference: bool,
	broken: bool,
}

pub async fn run() {
	for profile in [HostProfile::Interop, HostProfile::Glowcap] {
		scenario(profile).await;
	}
}

async fn scenario(profile: HostProfile) {
	let options = HostOptions::with_profile(profile);
	let host = Host::with_options(options).unwrap();
	let reader = host.spawn(|_, _| Ok(Argument::Void)).unwrap();
	let state = Rc::new(RefCell::new(State {
		calls: Vec::new(),
		name: "To do".into(),
		count: 0i64.into(),
		text: "write tests".into(),
		wrong_reference: false,
		broken: false,
	}));
	let captured = state.clone();
	host.publish("reads", move || {
		let state = captured.clone();
		let reader = reader.clone();
		Box::new(move |verb, args| {
			let verb = verb.expect("read method selector");
			let mut state = state.borrow_mut();
			state.calls.push((verb.into(), args.to_vec()));
			if state.broken {
				return Err("unlisted read failure".into());
			}
			match verb {
				"list" | "task" => {
					assert_eq!(args.len(), 1);
					assert!(matches!(args[0], Argument::Integer(0 | i64::MAX)));
					Ok(if state.wrong_reference {
						"wrong reference".into()
					} else {
						(&reader).into()
					})
				}
				"name" | "count" | "text" | "barrier" => {
					assert!(args.is_empty());
					Ok(match verb {
						"name" => state.name.clone(),
						"count" => state.count.clone(),
						"text" => state.text.clone(),
						_ => Argument::Void,
					})
				}
				_ => panic!("unexpected read method"),
			}
		})
	})
	.unwrap();
	let pair = Pair::open(&host, options).await;
	let client = &pair.client;
	let target = client.fetch("reads").await.unwrap();
	let before = state.borrow().calls.len();
	for bad in [-1, i64::MIN] {
		assert!(matches!(
			interface::board_list(client, &target, bad),
			Err(interface::Error::InvalidArgument)
		));
		assert!(matches!(
			interface::list_task(client, &target, bad),
			Err(interface::Error::InvalidArgument)
		));
	}
	client.send(&target, "barrier", &[]).await.unwrap();
	assert_eq!(state.borrow().calls.len(), before + 1, "invalid index sent a message");
	for index in [0, i64::MAX] {
		let board = interface::board_list(client, &target, index).unwrap();
		assert!(matches!(Argument::from(board.raw()), Argument::Promise(_)));
		let _ = board.await.unwrap();
		let _ = interface::list_task(client, &target, index).unwrap().await.unwrap();
		assert_eq!(state.borrow().calls.last().unwrap().1, vec![Argument::Integer(index)]);
	}
	state.borrow_mut().wrong_reference = true;
	assert!(matches!(
		interface::board_list(client, &target, 0).unwrap().await,
		Err(interface::Error::InvalidReply)
	));
	assert!(matches!(
		interface::list_task(client, &target, 0).unwrap().await,
		Err(interface::Error::InvalidReply)
	));
	state.borrow_mut().wrong_reference = false;

	let name = interface::list_name(client, &target);
	let count = interface::list_count(client, &target);
	let text = interface::task_text(client, &target);
	client.send(&target, "barrier", &[]).await.unwrap();
	let verbs: Vec<_> = state
		.borrow()
		.calls
		.iter()
		.rev()
		.take(4)
		.map(|(verb, _)| verb.clone())
		.collect();
	assert_eq!(
		verbs,
		["barrier", "text", "count", "name"],
		"unobserved reads were lazy"
	);
	assert_eq!(name.await.unwrap(), "To do");
	assert_eq!(count.await.unwrap(), 0);
	assert_eq!(text.await.unwrap(), "write tests");
	for (is_name, limit) in [(true, 64usize), (false, 4096usize)] {
		for valid in ["x".to_owned(), "é".repeat(limit / 2)] {
			if is_name {
				state.borrow_mut().name = valid.clone().into();
			} else {
				state.borrow_mut().text = valid.clone().into();
			}
			let pending = if is_name {
				interface::list_name(client, &target)
			} else {
				interface::task_text(client, &target)
			};
			assert_eq!(pending.await.unwrap(), valid);
		}
		for invalid in [
			Argument::String(String::new()),
			"x".repeat(limit + 1).into(),
			"é".repeat(limit / 2 + 1).into(),
			Argument::Bytes(b"valid utf8".to_vec()),
			1i64.into(),
		] {
			if is_name {
				state.borrow_mut().name = invalid;
			} else {
				state.borrow_mut().text = invalid;
			}
			let pending = if is_name {
				interface::list_name(client, &target)
			} else {
				interface::task_text(client, &target)
			};
			assert!(matches!(pending.await, Err(interface::Error::InvalidReply)));
		}
	}
	for value in [0, 256] {
		state.borrow_mut().count = Argument::Integer(value);
		assert_eq!(interface::list_count(client, &target).await.unwrap(), value);
	}
	for invalid in [
		Argument::Integer(-1),
		257i64.into(),
		i64::MIN.into(),
		i64::MAX.into(),
		Argument::Float(1.0),
		Argument::Boolean(true),
		"1".into(),
		Argument::BigInteger {
			negative: false,
			digits: "9223372036854775808".into(),
		},
	] {
		state.borrow_mut().count = invalid;
		assert!(matches!(
			interface::list_count(client, &target).await,
			Err(interface::Error::InvalidReply)
		));
	}
	let original = Argument::BigInteger {
		negative: false,
		digits: "9223372036854775808".into(),
	};
	state.borrow_mut().count = original.clone();
	let typed = interface::list_count(client, &target);
	let retained = typed.raw().retain().unwrap();
	let raw = client.listen(&retained);
	assert!(matches!(typed.await, Err(interface::Error::InvalidReply)));
	assert_eq!(raw.await.unwrap(), original, "typed bounds rewrote raw settlement");
	drop(retained);
	state.borrow_mut().broken = true;
	match interface::list_count(client, &target).await {
		Err(interface::Error::Runtime(error)) => assert_eq!(error.message(), Some("unlisted read failure")),
		_ => panic!("read wrapper changed remote break"),
	}
	state.borrow_mut().broken = false;
	state.borrow_mut().count = 1i64.into();
	assert_eq!(interface::list_count(client, &target).await.unwrap(), 1);
	pair.close().await;
}
