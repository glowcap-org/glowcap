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
						"keep" => {
							*kept.borrow_mut() = args.first().cloned();
							Ok(Argument::String("kept".into()))
						}
						"kept" => kept.borrow().clone().ok_or_else(|| "nothing kept".to_string()),
						"make" => {
							let greeter = factory
								.spawn(|greeter_verb, _args| match greeter_verb {
									"greet" => Ok(Argument::String("hello from the greeter".into())),
									other => Err(format!("no such method: {other}")),
								})
								.map_err(|error| error.to_string())?;
							Ok((&greeter).into())
						}
						"use" => args.first().cloned().ok_or_else(|| "use needs a target".to_string()),
						"use_first" => match args.first() {
							Some(Argument::List(items)) => {
								items.first().cloned().ok_or_else(|| "empty list".to_string())
							}
							_ => Err("use_first needs a list".to_string()),
						},
						other => Err(format!("no such method: {other}")),
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
