//! Independent public observation shapes and the actual Tasks Watcher.
use crate::{interface, pair::Pair, task_board::Board};
use glowcap::{Argument, Host, HostOptions, HostProfile, ListenerIdentity, PendingWork, Runtime, RuntimeConfig, tcp};
use std::{
	cell::{Cell, RefCell},
	rc::Rc,
};

fn observation(tag: &str) -> Argument {
	Argument::Tagged {
		tag: tag.into(),
		value: vec![
			Argument::Bytes(vec![7; 56]),
			Argument::Void,
			Argument::Boolean(false),
			Argument::Boolean(true),
			Argument::List(vec![]),
		],
	}
}

pub async fn run() {
	for profile in [HostProfile::Interop, HostProfile::Glowcap] {
		let options = HostOptions::with_profile(profile);
		let host = Host::with_options(options).unwrap();
		let reply = Rc::new(RefCell::new(observation("wrong:observation")));
		let current = reply.clone();
		let seen = Rc::new(RefCell::new(Vec::<Vec<Argument>>::new()));
		let captured = seen.clone();
		let receiver = host
			.spawn(move |verb, args| {
				assert_eq!(verb, Some("poll"));
				captured.borrow_mut().push(args.to_vec());
				Ok(current.borrow().clone())
			})
			.unwrap();
		let cancellations = Rc::new(Cell::new(0));
		let cancel_fails = Rc::new(Cell::new(false));
		let counted = cancellations.clone();
		let failing = cancel_fails.clone();
		let canceller = host
			.spawn(move |verb, args| {
				assert_eq!(verb, Some("cancel"));
				assert!(args.is_empty());
				counted.set(counted.get() + 1);
				if failing.get() {
					Err("independent cancellation failure".into())
				} else {
					Ok(Argument::Boolean(true))
				}
			})
			.unwrap();
		let list = host.spawn(|_, _| Ok(Argument::Void)).unwrap();
		host.publish("watch-board", move || {
			let (receiver, canceller, list) = (receiver.clone(), canceller.clone(), list.clone());
			Box::new(move |verb, args| match verb {
				Some("list") => Ok((&list).into()),
				Some("mutation-sequence") => Ok(1i64.into()),
				Some("mutate") => {
					assert_eq!(args, &[1i64.into(), "observe".into()]);
					Ok(Argument::List(vec![(&receiver).into(), (&canceller).into()]))
				}
				_ => panic!("unexpected board method"),
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
		let locator = server.locator().unwrap();
		let client_host = Host::with_options(options).unwrap();
		let runtime =
			Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]).adopt_host(&client_host))
				.await
				.unwrap();
		let (board, serving) = tokio::join!(Board::join_with_runtime(runtime, &locator, "watch-board"), async {
			let accepted = server.accept().await.unwrap();
			assert_eq!(accepted.profile().unwrap().codec, options.codec);
			assert_eq!(accepted.profile().unwrap().captp_version, options.captp_version);
			{
				let serving = tokio::task::spawn_local(accepted.serve());
				(accepted, serving)
			}
		});
		let (_accepted, serving) = serving;
		let board = board.unwrap();
		let primary = board
			.watch()
			.await
			.err()
			.expect("Watcher accepted wrong observation tag");
		assert!(primary.starts_with("poll:"));
		assert_eq!(
			cancellations.get(),
			1,
			"failed initial poll did not cancel exactly once"
		);
		*reply.borrow_mut() = observation("access:observation");
		let mut watcher = board.watch().await.unwrap();
		assert_eq!(cancellations.get(), 1, "live watcher was cancelled");
		let valid = observation("access:observation");
		let mut malformed = vec![observation("wrong:observation")];
		for length in [4, 6] {
			let mut value = valid.clone();
			if let Argument::Tagged { value: fields, .. } = &mut value {
				fields.resize(length, Argument::Void);
			}
			malformed.push(value);
		}
		for length in [55, 57] {
			let mut value = valid.clone();
			if let Argument::Tagged { value: fields, .. } = &mut value {
				fields[0] = Argument::Bytes(vec![8; length]);
			}
			malformed.push(value);
		}
		for field in [0, 2, 3, 4] {
			let mut value = valid.clone();
			if let Argument::Tagged { value: fields, .. } = &mut value {
				fields[0] = Argument::Bytes(vec![8; 56]);
				fields[field] = Argument::String("wrong field".into());
			}
			malformed.push(value);
		}
		let mut nonsymbol = valid.clone();
		if let Argument::Tagged { value: fields, .. } = &mut nonsymbol {
			fields[4] = Argument::List(vec!["string is not symbol".into()]);
		}
		malformed.push(nonsymbol);
		for value in malformed {
			*reply.borrow_mut() = value;
			assert!(watcher.changed().await.is_err(), "invalid observation accepted");
			assert_eq!(
				seen.borrow().last().unwrap(),
				&[Argument::Bytes(vec![7; 56])],
				"failed reply changed cursor"
			);
		}
		*reply.borrow_mut() = valid.clone();
		if let Argument::Tagged { value: fields, .. } = &mut *reply.borrow_mut() {
			fields[0] = Argument::Bytes(vec![9; 56]);
			fields[4] = Argument::List(vec![Argument::Symbol("future-notice".into()); 2]);
		}
		assert!(watcher.changed().await.unwrap());
		assert_eq!(seen.borrow().last().unwrap(), &[Argument::Bytes(vec![7; 56])]);
		assert!(watcher.changed().await.unwrap());
		assert_eq!(seen.borrow().last().unwrap(), &[Argument::Bytes(vec![9; 56])]);
		assert_eq!(cancellations.get(), 1, "retryable poll failure cancelled live watcher");
		watcher.stop().await.unwrap();
		assert_eq!(cancellations.get(), 2, "explicit stop did not cancel exactly once");
		*reply.borrow_mut() = observation("wrong:observation");
		cancel_fails.set(true);
		let failure = board.watch().await.err().expect("invalid initial poll accepted");
		assert!(failure.starts_with(&primary), "cleanup replaced primary poll error");
		assert!(
			failure.contains("independent cancellation failure"),
			"cleanup context lost"
		);
		assert_eq!(cancellations.get(), 3, "failed cancellation was retried or omitted");
		cancel_fails.set(false);
		board.leave().await.unwrap();
		server.close().await.unwrap();
		// Reuse the same schema through a direct generated observation. A
		// nested opaque value is not a decoder traversal invitation.
		let reference = host.spawn(|_, _| Ok("description reference".into())).unwrap();
		let mut description = Argument::Reference(reference);
		for _ in 0..8 {
			description = Argument::List(vec![description]);
		}
		*reply.borrow_mut() = valid;
		if let Argument::Tagged { value: fields, .. } = &mut *reply.borrow_mut() {
			fields[1] = description;
			fields[4] = Argument::List(vec![Argument::Symbol("future-notice".into()); 2]);
		}
		let observed = reply.clone();
		host.publish("observation", move || {
			let reply = observed.clone();
			Box::new(move |_, _| Ok(reply.borrow().clone()))
		})
		.unwrap();
		let pair = Pair::open(&host, options).await;
		let target = pair.client.fetch("observation").await.unwrap();
		let interface::LoamObservation(cursor, description, reset, changed, notices) =
			interface::receiver_poll(&pair.client, &target, None)
				.unwrap()
				.await
				.unwrap();
		assert_eq!(cursor, vec![7; 56]);
		assert!(!reset && changed);
		assert_eq!(notices, ["future-notice", "future-notice"]);
		let mut leaf = &description;
		for _ in 0..8 {
			leaf = &leaf.as_list().unwrap()[0];
		}
		let reference = glowcap::Ref::try_from(leaf).unwrap();
		assert_eq!(
			pair.client.send(&reference, "read", &[]).await.unwrap().as_str(),
			Some("description reference")
		);
		*reply.borrow_mut() = observation("wrong:observation");
		let typed = interface::receiver_poll(&pair.client, &target, None).unwrap();
		let retained = typed.raw().retain().unwrap();
		let raw = pair.client.listen(&retained);
		assert!(matches!(typed.await, Err(interface::Error::InvalidReply)));
		assert!(matches!(raw.await.unwrap(), Argument::Tagged { tag, .. } if tag == "wrong:observation"));
		drop(retained);
		pair.close().await;
		host.close(PendingWork::Cancel).await.unwrap();
		serving.await.unwrap().unwrap();
	}
}
