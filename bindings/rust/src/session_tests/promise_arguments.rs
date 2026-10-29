//! A promise as a send and tell argument (ADR-0068).

use std::cell::RefCell;

use super::support::*;

// A promise is a send and tell argument (ADR-0068): the unawaited `make`
// answer crosses as a capability for the pending answer in a tell the board
// keeps and in a send it hands back, the same promise crosses settled as its
// value nested in a list, and greeting through each proves all three reached
// the greeter. A promise another Host returned is refused before any frame
// moves, and the refusal leaves that promise usable.
#[tokio::test]
async fn promise_argument_passes_as_a_capability() {
	let local = LocalSet::new();
	local
		.run_until(async {
			let serve_board = |server: tcp::Server| async move {
				let session = server.accept().await.unwrap();
				let factory = Session::view(Rc::clone(&session.shared));
				let kept: Rc<RefCell<Option<Argument>>> = Rc::new(RefCell::new(None));
				session
					.publish("root", move |verb, args| match verb {
						Some("keep") => {
							*kept.borrow_mut() = args.first().cloned();
							Ok(Argument::String("kept".into()))
						}
						Some("kept") => kept.borrow().clone().ok_or_else(|| "nothing kept".to_string()),
						Some("make") => {
							let greeter = factory
								.spawn(|greeter_verb, _args| match greeter_verb {
									Some("greet") => Ok(Argument::String("hello from the greeter".into())),
									other => Err(format!("no such method: {other:?}")),
								})
								.map_err(|error| error.to_string())?;
							Ok((&greeter).into())
						}
						Some("use") => args.first().cloned().ok_or_else(|| "use needs a target".to_string()),
						Some("data") => Ok(Argument::String("retained data".into())),
						Some("break") => Err("retained refusal".into()),
						Some("use_first") => match args.first() {
							Some(Argument::List(items)) => {
								items.first().cloned().ok_or_else(|| "empty list".to_string())
							}
							_ => Err("use_first needs a list".to_string()),
						},
						other => Err(format!("no such method: {other:?}")),
					})
					.unwrap();
				session.serve().await.unwrap();
			};
			let server = listen("127.0.0.1:0").await.unwrap();
			let addr = std::net::SocketAddr::from(([127, 0, 0, 1], server.port().unwrap()));
			let host = tokio::task::spawn_local(serve_board(server));
			let session = connect(
				&crate::tcp::locator(&addr.ip().to_string(), addr.port()),
				ConnectOptions::default(),
			)
			.await
			.unwrap();
			let root = session.fetch("root").await.unwrap();
			let greeter = session.send(&root, "make", &[]);
			session.tell(&root, "keep", &[(&greeter).into()]).unwrap();
			let used = session.send(&root, "use", &[(&greeter).into()]).await.unwrap();
			let kept = session.send(&root, "kept", &[]).await.unwrap();
			// `make` answered before `use` on one session, so the promise is
			// settled when it passes again: the Host carries it as its value.
			let used_first = session
				.send(&root, "use_first", &[Argument::List(vec![(&greeter).into()])])
				.await
				.unwrap();
			let (Argument::Reference(used), Argument::Reference(used_first), Argument::Reference(kept)) =
				(used, used_first, kept)
			else {
				panic!("a passed promise returns as a capability");
			};
			assert_eq!(
				session.send(&used, "greet", &[]).await.unwrap(),
				Argument::String("hello from the greeter".into())
			);
			assert_eq!(
				session.send(&kept, "greet", &[]).await.unwrap(),
				Argument::String("hello from the greeter".into())
			);
			assert_eq!(
				session.send(&used_first, "greet", &[]).await.unwrap(),
				Argument::String("hello from the greeter".into())
			);

			// Retaining an answer owns a capability occurrence, not the call's
			// observation. Awaiting the original and releasing one occurrence
			// leave the other usable, and its final drop gives the retain back.
			let pending = session.send(&root, "make", &[]);
			let first = pending.retain().unwrap();
			let second = pending.retain().unwrap();
			assert_eq!(first, second);
			let stale = Ref::bare_id(first.id());
			drop(pending.await.unwrap());
			drop(first);
			session.shared.drain_gc().unwrap();
			assert_eq!(
				session.send(&second, "greet", &[]).await.unwrap().as_str(),
				Some("hello from the greeter")
			);
			drop(second);
			session.shared.drain_gc().unwrap();
			let refused = session.send(&stale, "greet", &[]);
			assert!(refused.vow().is_none(), "released occurrence was admitted");
			let failure = refused.retain().unwrap_err();
			assert_eq!(
				refused.await.unwrap_err(),
				failure,
				"retain replaced the original refusal"
			);
			let observer = session.listen(&root);
			assert_eq!(observer.retain().unwrap_err().kind(), ErrorKind::InvalidArgument);
			drop(observer);
			retained_outcomes(&session, &root).await;

			let second_server = listen("127.0.0.1:0").await.unwrap();
			let second_addr = std::net::SocketAddr::from(([127, 0, 0, 1], second_server.port().unwrap()));
			let second_host = tokio::task::spawn_local(serve_board(second_server));
			let second = connect(
				&crate::tcp::locator(&second_addr.ip().to_string(), second_addr.port()),
				ConnectOptions::default(),
			)
			.await
			.unwrap();
			let second_root = second.fetch("root").await.unwrap();
			let foreign = second.send(&second_root, "make", &[]);
			let error = session.send(&root, "use", &[(&foreign).into()]).await.unwrap_err();
			assert_eq!(error.kind(), ErrorKind::InvalidArgument);
			assert_eq!(
				second.send(&foreign, "greet", &[]).await.unwrap(),
				Argument::String("hello from the greeter".into())
			);
			second.close(crate::PendingWork::Cancel).await.unwrap();
			second_host.await.unwrap();
			session.close(crate::PendingWork::Cancel).await.unwrap();
			host.await.unwrap();
		})
		.await;
}

// Retention preserves the answer's outcome, not a promise that it will be an
// object. Cover minting both before and after settlement, and independently
// dropping or observing the original. A later call is the settlement barrier.
async fn retained_outcomes(session: &Session, root: &Ref) {
	for settled in [false, true] {
		for observe in [false, true] {
			for verb in ["data", "break"] {
				let pending = session.send(root, verb, &[]);
				if settled {
					session.send(root, "data", &[]).await.unwrap();
				}
				let retained = pending.retain().unwrap();
				let original = if observe {
					Some(pending.await)
				} else {
					drop(pending);
					None
				};
				session.shared.drain_gc().unwrap();
				let result = session.listen(&retained).await;
				if let Some(original) = original {
					assert_eq!(result, original);
				}
				if verb == "data" {
					assert_eq!(result.unwrap().as_str(), Some("retained data"));
				} else {
					let failure = result.unwrap_err();
					assert_eq!(failure.kind(), ErrorKind::Broken);
					assert_eq!(failure.message(), Some("retained refusal"));
				}
				let stale = Ref::bare_id(retained.id());
				drop(retained);
				session.shared.drain_gc().unwrap();
				assert!(session.send(&stale, "probe", &[]).vow().is_none());
				// The release failure above must not be a dead-session false positive.
				assert_eq!(
					session.send(root, "data", &[]).await.unwrap().as_str(),
					Some("retained data")
				);
			}
		}
	}
}
