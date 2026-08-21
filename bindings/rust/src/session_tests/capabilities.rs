//! Promise pipeline, Host-owned spawn, and forwarding-proxy scenarios.

use super::support::*;

// Promise pipelining (ADR-0007), the questioner's half: `send` returns a
// `RemotePromise` that is itself a `send` target, so a create -> assign ->
// complete -> status chain is issued against the *unresolved* create answer,
// none of the four waits for create's reply. The board returns a freshly
// spawned task; the partner's engine queues the pipelined calls on the create
// answer and drains them onto the task once create resolves. A status of
// `done` proves the chain crossed the wire without round-tripping per link.
#[tokio::test]
async fn promise_pipelining_drives_a_dependent_chain() {
	let local = LocalSet::new();
	local
		.run_until(async {
			let server = listen("127.0.0.1:0").await.unwrap();
			let addr = std::net::SocketAddr::from(([127, 0, 0, 1], server.port().unwrap()));
			let (ready_tx, ready_rx) = oneshot::channel::<()>();
			let host = tokio::task::spawn_local(async move {
				let session = server.accept().await.unwrap();
				let factory = Session::view(Rc::clone(&session.shared));
				session
					.publish("root", move |verb, _args| {
						if verb != "create" {
							return Err(format!("no such method: {verb}"));
						}
						let done = Cell::new(false);
						let task = factory
							.spawn(move |task_verb, _args| match task_verb {
								"assign" => Ok(Argument::String("assigned".into())),
								"complete" => {
									done.set(true);
									Ok(Argument::String("done".into()))
								}
								"status" => Ok(Argument::String(if done.get() { "done" } else { "open" }.into())),
								other => Err(format!("no such method: {other}")),
							})
							.map_err(|error| error.to_string())?;
						Ok((&task).into())
					})
					.unwrap();
				ready_tx.send(()).unwrap();
				session.serve().await.unwrap();
			});

			let session = connect(
				&crate::tcp::locator(&addr.ip().to_string(), addr.port()),
				ConnectOptions::default(),
			)
			.await
			.unwrap();
			ready_rx.await.unwrap();
			let root = session.fetch("root").await.unwrap();
			// The four verbs leave together: none awaits create's reply, and
			// assign / complete / status target the create answer directly.
			let task = session.send(&root, "create", &[Argument::String("benchmark".into())]);
			session.send(&task, "assign", &[Argument::String("alice".into())]);
			session.send(&task, "complete", &[]);
			let status = session.send(&task, "status", &[]).await.unwrap();
			assert_eq!(status, Argument::String("done".into()));
			session.close(crate::PendingWork::Cancel).await.unwrap();
			host.await.unwrap();
		})
		.await;
}

// A hosted actor belongs to the Host, not to the Port that first projected it.
// Close that originating Port, invoke the actor through a sibling Port, and
// have its synchronous callback use the stale Session handle to spawn a child.
// The active Host turn must select turn-spawn; consulting the dead Session
// would reject before the child could ride the reply.
#[tokio::test]
async fn turn_spawn_uses_the_host_after_the_originating_port_closes() {
	let local = LocalSet::new();
	local
		.run_until(async {
			let server = listen("127.0.0.1:0").await.unwrap();
			let addr = std::net::SocketAddr::from(([127, 0, 0, 1], server.port().unwrap()));
			let (ready_tx, ready_rx) = oneshot::channel::<()>();
			let hosted = tokio::task::spawn_local(async move {
				let origin = server.accept().await.unwrap();
				let stale_origin = Session::view(Rc::clone(&origin.shared));
				let root = origin
					.spawn(move |verb, _args| {
						if verb != "create" {
							return Err(format!("no such method: {verb}"));
						}
						let child = stale_origin
							.spawn(|child_verb, _args| {
								if child_verb == "ping" {
									Ok(Argument::Symbol("alive".into()))
								} else {
									Err(format!("no such method: {child_verb}"))
								}
							})
							.map_err(|error| error.to_string())?;
						Ok((&child).into())
					})
					.unwrap();
				let sibling = server.accept().await.unwrap();
				sibling
					.publish("introducer", move |verb, _args| {
						if verb == "get" {
							Ok((&root).into())
						} else {
							Err(format!("no such method: {verb}"))
						}
					})
					.unwrap();
				origin.close(crate::PendingWork::Cancel).await.unwrap();
				ready_tx.send(()).unwrap();
				sibling.serve().await.unwrap();
			});

			let origin_client = connect(
				&crate::tcp::locator(&addr.ip().to_string(), addr.port()),
				ConnectOptions::default(),
			)
			.await
			.unwrap();
			let sibling_client = connect(
				&crate::tcp::locator(&addr.ip().to_string(), addr.port()),
				ConnectOptions::default(),
			)
			.await
			.unwrap();
			ready_rx.await.unwrap();
			let introducer = sibling_client.fetch("introducer").await.unwrap();
			let root = Ref::try_from(&sibling_client.send(&introducer, "get", &[]).await.unwrap())
				.expect("the sibling introduces the Host-owned root");
			let child = Ref::try_from(&sibling_client.send(&root, "create", &[]).await.unwrap())
				.expect("create returns the turn-spawned child");
			assert_eq!(
				sibling_client.send(&child, "ping", &[]).await.unwrap(),
				Argument::Symbol("alive".into())
			);
			sibling_client.close(crate::PendingWork::Cancel).await.unwrap();
			origin_client.close(crate::PendingWork::Cancel).await.unwrap();
			hosted.await.unwrap();
		})
		.await;
}

// Pipelined projections (ADR-0050/ADR-0052): `RemotePromise::untag` / `index`
// reach into the value an answer will resolve to *before* it resolves, each
// returning a new pipelinable promise. The board's `make` returns a Tagged
// "task" wrapping one row `["assigned", label, 7]`; untag unwraps to that
// row, index 1 takes the label, a two-hop chain riding the unresolved make
// answer, no extra round trip. The source handle is awaited afterward to
// prove a far reply observed *late* (after a sibling projection already
// pumped the loop) still settles.
#[tokio::test]
async fn pipelined_projections_reach_a_field() {
	let local = LocalSet::new();
	local
		.run_until(async {
			let next_host = || {
				Host::with_options(crate::HostOptions {
					captp_version: crate::CaptpVersion::Next,
					..Default::default()
				})
				.unwrap()
			};
			let server = listen_with_host("127.0.0.1:0", next_host()).await.unwrap();
			let addr = std::net::SocketAddr::from(([127, 0, 0, 1], server.port().unwrap()));
			let (ready_tx, ready_rx) = oneshot::channel::<()>();
			let host = tokio::task::spawn_local(async move {
				let session = server.accept().await.unwrap();
				session
					.publish("root", |verb, args| {
						if verb != "make" {
							return Err(format!("no such method: {verb}"));
						}
						let label = match args.first() {
							Some(Argument::String(s)) => s.clone(),
							_ => "anon".to_string(),
						};
						// A Tagged wrapping a single row: untag unwraps to it.
						Ok(Argument::Tagged {
							tag: "task".into(),
							value: vec![Argument::List(vec![
								Argument::String("assigned".into()),
								Argument::String(label),
								Argument::Integer(7),
							])],
						})
					})
					.unwrap();
				ready_tx.send(()).unwrap();
				session.serve().await.unwrap();
			});

			let session = connect_with_host(&crate::tcp::locator(&addr.ip().to_string(), addr.port()), next_host())
				.await
				.unwrap();
			ready_rx.await.unwrap();
			let root = session.fetch("root").await.unwrap();
			// Neither projection awaits a prior reply: they ride the
			// unresolved make answer and the whole chain leaves on one flush.
			let made = session.send(&root, "make", &[Argument::String("alice".into())]);
			// `get` mints a sibling vow at the answer (Struct fields; bindings
			// cannot publish Struct replies, so we only assert the mint surface).
			let field = made.get("name");
			assert!(
				field.vow().is_some(),
				"RemotePromise::get should mint a pipelinable vow"
			);
			let label = made.untag("task").index(1).await.unwrap();
			assert_eq!(label, Argument::String("alice".into()));
			// The source answer settled while the projection pumped the loop;
			// awaiting it now must still resolve.
			let full = made.await.unwrap();
			assert!(matches!(full, Argument::Tagged { ref tag, .. } if tag == "task"));
			session.close(crate::PendingWork::Cancel).await.unwrap();
			host.await.unwrap();
		})
		.await;
}

// Object-capability forwarding proxies over the wire (ADR-0064). The host fetches the
// client's published tool — a *far* reference on the host side — wraps it in a
// caretaker, and hands the proxy back to the client. A call through the proxy
// forwards across the host to the client's tool (the far deferred-answer path)
// and resolves the caller's answer; an attenuator passes only its allow-listed
// verb; and a revoke breaks every later call. The forward target being far is
// the point: it exercises the turn-forward path across the host's routing.
#[tokio::test]
async fn forwarding_proxies_forward_revoke_and_attenuate_over_the_wire() {
	let local = LocalSet::new();
	local
		.run_until(async {
			let server = listen("127.0.0.1:0").await.unwrap();
			let addr = std::net::SocketAddr::from(([127, 0, 0, 1], server.port().unwrap()));
			let (tool_ready_tx, tool_ready_rx) = oneshot::channel::<()>();
			let (proxy_ready_tx, proxy_ready_rx) = oneshot::channel::<()>();

			let host = tokio::task::spawn_local(async move {
				let session = server.accept().await.unwrap();
				// Wait for the client to publish its tool, then fetch it: a far
				// reference this host wraps.
				tool_ready_rx.await.unwrap();
				let tool = session.fetch("tool").await.unwrap();

				let care = session.caretaker(&tool).unwrap();
				let proxy = care.proxy.clone();
				let readonly = session.attenuate(&tool, &["get"]).unwrap();

				session
					.publish("root", move |verb, _args| match verb {
						"proxy" => Ok((&proxy).into()),
						"readonly" => Ok((&readonly).into()),
						"revoke" => {
							care.revoke();
							Ok(Argument::Void)
						}
						other => Err(format!("no such method: {other}")),
					})
					.unwrap();
				proxy_ready_tx.send(()).unwrap();
				session.serve().await.unwrap();
			});

			let session = connect(
				&crate::tcp::locator(&addr.ip().to_string(), addr.port()),
				ConnectOptions::default(),
			)
			.await
			.unwrap();
			// The tool the host will wrap: `add` increments, `get` reads.
			session
				.publish("tool", |verb, args| match verb {
					"add" => {
						let n = args.first().and_then(|a| a.as_i64()).unwrap_or(0);
						Ok(Argument::Integer(n + 1))
					}
					"get" => Ok(Argument::Integer(7)),
					other => Err(format!("no such method: {other}")),
				})
				.unwrap();
			// Publishing is setup, not admission. Resume only after the complete
			// tool surface exists, before the host's fetch can reach it.
			drop(session.serve());
			tool_ready_tx.send(()).unwrap();
			proxy_ready_rx.await.unwrap();

			let root = session.fetch("root").await.unwrap();

			// Live caretaker: a call forwards across the host to the far tool.
			let proxy = Ref::try_from(&session.send(&root, "proxy", &[]).await.unwrap()).unwrap();
			let reply = session.send(&proxy, "add", &[Argument::Integer(41)]).await.unwrap();
			assert_eq!(reply, Argument::Integer(42));

			// Attenuator: the allow-listed verb forwards; any other breaks.
			let readonly = Ref::try_from(&session.send(&root, "readonly", &[]).await.unwrap()).unwrap();
			let got = session.send(&readonly, "get", &[]).await.unwrap();
			assert_eq!(got, Argument::Integer(7));
			let denied = session
				.send(&readonly, "add", &[Argument::Integer(1)])
				.await
				.unwrap_err();
			assert!(denied.to_string().contains("Attenuated"), "{denied}");

			// Revoke: every later call through the proxy breaks.
			session.send(&root, "revoke", &[]).await.unwrap();
			let severed = session.send(&proxy, "add", &[Argument::Integer(1)]).await.unwrap_err();
			assert!(severed.to_string().contains("Revoked"), "{severed}");

			session.close(crate::PendingWork::Cancel).await.unwrap();
			host.await.unwrap();
		})
		.await;
}

// The wart ADR-0064 closes: a caretaker/attenuator proxy is an ordinary
// spawned actor, so its own host calls it locally exactly as a partner calls
// it over the wire. A caretaker over a *local* tool answers a local send; a
// caretaker over a *far* tool forwards across the wire and the local send still
// settles; and a revoke breaks the local call too.
#[tokio::test]
async fn a_forwarding_proxy_answers_its_hosts_own_local_call() {
	let local = LocalSet::new();
	local
		.run_until(async {
			let server = listen("127.0.0.1:0").await.unwrap();
			let addr = std::net::SocketAddr::from(([127, 0, 0, 1], server.port().unwrap()));
			let (ready_tx, ready_rx) = oneshot::channel::<()>();
			let host = tokio::task::spawn_local(async move {
				let session = server.accept().await.unwrap();
				session
					.publish("tool", |verb, _args| match verb {
						"ping" => Ok(Argument::Integer(99)),
						other => Err(format!("no such method: {other}")),
					})
					.unwrap();
				ready_tx.send(()).unwrap();
				session.serve().await.unwrap();
			});

			let session = connect(
				&crate::tcp::locator(&addr.ip().to_string(), addr.port()),
				ConnectOptions::default(),
			)
			.await
			.unwrap();
			ready_rx.await.unwrap();

			// A caretaker over a local tool, called locally by its own host.
			let local_tool = session
				.spawn(|verb, args| match verb {
					"double" => {
						let n = args.first().and_then(|a| a.as_i64()).unwrap_or(0);
						Ok(Argument::Integer(n * 2))
					}
					other => Err(format!("no such method: {other}")),
				})
				.unwrap();
			let care_local = session.caretaker(&local_tool).unwrap();
			let doubled = session
				.send(&care_local.proxy, "double", &[Argument::Integer(21)])
				.await
				.unwrap();
			assert_eq!(doubled, Argument::Integer(42));

			// A caretaker over a far tool, called locally: the proxy forwards
			// across the wire and the local send still settles on the reply.
			let far = session.fetch("tool").await.unwrap();
			let care_far = session.caretaker(&far).unwrap();
			let pong = session.send(&care_far.proxy, "ping", &[]).await.unwrap();
			assert_eq!(pong, Argument::Integer(99));

			// Revoke severs the local call exactly as it severs a partner's.
			care_local.revoke();
			let severed = session
				.send(&care_local.proxy, "double", &[Argument::Integer(1)])
				.await
				.unwrap_err();
			assert!(severed.to_string().contains("Revoked"), "{severed}");

			session.close(crate::PendingWork::Cancel).await.unwrap();
			host.await.unwrap();
		})
		.await;
}
