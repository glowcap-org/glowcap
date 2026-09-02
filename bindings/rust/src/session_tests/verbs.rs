//! Application verb, refusal, ordering, and codec-value scenarios.

use super::support::*;

// Sturdyref enliven (ADR-0012): the client brings a durable `(peer, swissnum)`
// to life as a live `Ref` through the dedup cache, calls it, then enlivens the
// same swissnum again and gets the cached capability with no new wire fetch.
// The swissnum keys the bootstrap fetch, so a host publish under that name
// answers it.
#[tokio::test]
async fn enliven_round_trips_then_caches() {
	let local = LocalSet::new();
	local
		.run_until(async {
			let server = listen("127.0.0.1:0").await.unwrap();
			let addr = std::net::SocketAddr::from(([127, 0, 0, 1], server.port().unwrap()));

			let (ready_tx, ready_rx) = oneshot::channel::<()>();
			let host = tokio::task::spawn_local(async move {
				let session = server.accept().await.unwrap();
				session
					.publish("greeter", |verb, _args| {
						if verb != "hello" {
							return Err(format!("no such method: {verb}"));
						}
						Ok(Argument::Symbol("alive".into()))
					})
					.unwrap();
				ready_tx.send(()).unwrap();
				session.serve().await.unwrap();
			});

			let locator = crate::tcp::locator(&addr.ip().to_string(), addr.port());
			let session = connect(&locator, ConnectOptions::default()).await.unwrap();
			ready_rx.await.unwrap();

			let mismatch = session
				.enliven("ocapn://127.0.0.1%3A1.tcp/s/Z3JlZXRlcg")
				.await
				.unwrap_err();
			assert_eq!(
				mismatch.kind(),
				ErrorKind::InvalidArgument,
				"mismatch detail: {mismatch:?}"
			);
			// The complete sturdyref must name this selected session's peer.
			let locator_uri = crate::uri::format_locator_uri(&locator).unwrap();
			let sturdyref = format!("{locator_uri}/s/Z3JlZXRlcg");
			let cap = session.enliven(&sturdyref).await.unwrap();
			let reply = session.send(&cap, "hello", &[]).await.unwrap();
			assert_eq!(reply, Argument::Symbol("alive".into()));

			// A repeat enliven hits the dedup cache: the same live capability.
			let again = session.enliven(&sturdyref).await.unwrap();
			assert_eq!(again, cap);
			let reply2 = session.send(&again, "hello", &[]).await.unwrap();
			assert_eq!(reply2, Argument::Symbol("alive".into()));

			let session_host = session.host();
			let fetched = session_host.fetch_at(&locator, "greeter").await.unwrap();
			assert_eq!(
				session.send(&fetched, "hello", &[]).await.unwrap(),
				Argument::Symbol("alive".into())
			);
			let host_cap = session_host
				.enliven_for_version(&sturdyref, crate::CaptpVersion::V1_0)
				.await
				.unwrap();
			let host_reply = session.send(&host_cap, "hello", &[]).await.unwrap();
			assert_eq!(host_reply, Argument::Symbol("alive".into()));
			let wrong_version = session_host
				.enliven_for_version(&sturdyref, crate::CaptpVersion::Next)
				.await
				.unwrap_err();
			assert_eq!(wrong_version.kind(), ErrorKind::Broken);

			// Listen (CapTP `op:listen`): a held capability's resolution comes
			// back through the vow — a listen on an already-settled capability
			// answers at once.
			let observation = session.listen(&cap);
			let refused = session.send(&observation, "hello", &[]).await.unwrap_err();
			assert_eq!(refused.kind(), ErrorKind::InvalidArgument);
			let settled = observation.await.unwrap();
			assert!(matches!(settled, Argument::Reference(_)));

			session.close(crate::PendingWork::Cancel).await.unwrap();
			host.await.unwrap();
		})
		.await;
}

// A broken `send` carries the partner's reason, not just a code: the partner
// publishes a behavior that refuses `do` with its own words, and the client
// must read them back off the error. The refusal crosses the C boundary as a
// turn break, so the words survive the trampoline.
#[tokio::test]
async fn send_surfaces_the_partner_break_reason() {
	let local = LocalSet::new();
	local
		.run_until(async {
			let server = listen("127.0.0.1:0").await.unwrap();
			let addr = std::net::SocketAddr::from(([127, 0, 0, 1], server.port().unwrap()));

			let (ready_tx, ready_rx) = oneshot::channel::<()>();
			let host = tokio::task::spawn_local(async move {
				let session = server.accept().await.unwrap();
				session
					.publish("svc", |verb, _args| {
						Err(match verb {
							"do" => "nope: revoked".to_string(),
							other => format!("no such method: {other}"),
						})
					})
					.unwrap();
				ready_tx.send(()).unwrap();
				session.serve().await.unwrap();
			});

			let stream = tokio::net::TcpStream::connect(addr).await.unwrap();
			let peer = stream.peer_addr().unwrap();
			let designator = crate::tcp::address_designator(&peer.ip().to_string(), peer.port());
			let captp = Host::new_host();
			let session = Session::establish_dialed_locator(
				captp.shared(),
				&crate::Locator::bare(crate::abi_constants::TRANSPORT_TCP, &designator),
				stream,
				Some(HANDSHAKE_TIMEOUT),
				None,
			)
			.await
			.unwrap();
			ready_rx.await.unwrap();
			let cap = session.fetch("svc").await.unwrap();
			let err = session.send(&cap, "do", &[]).await.unwrap_err();
			assert_eq!(err.message(), Some("nope: revoked"));
			// A break is GLOWCAP_ERR_BROKEN, not a transport or value error.
			assert_eq!(err.code(), crate::sys::ERR_BROKEN);
			session.close(crate::PendingWork::Cancel).await.unwrap();
			host.await.unwrap();
		})
		.await;
}

// A panicking behavior must never unwind across the extern "C" frame: the
// trampoline catches it, the answer breaks with the panic's own words, and
// the connection survives to serve the next call.
#[tokio::test]
async fn a_panicking_behavior_breaks_its_answer_and_the_process_survives() {
	let local = LocalSet::new();
	local
		.run_until(async {
			let server = listen("127.0.0.1:0").await.unwrap();
			let addr = std::net::SocketAddr::from(([127, 0, 0, 1], server.port().unwrap()));

			let (ready_tx, ready_rx) = oneshot::channel::<()>();
			let host = tokio::task::spawn_local(async move {
				let session = server.accept().await.unwrap();
				session
					.publish("svc", |verb, _args| {
						if verb == "explode" {
							panic!("Revoked by panic");
						}
						Ok(Argument::Symbol("calm".into()))
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
			let cap = session.fetch("svc").await.unwrap();
			let err = session.send(&cap, "explode", &[]).await.unwrap_err();
			assert_eq!(err.code(), crate::sys::ERR_BROKEN);
			assert!(
				err.message().is_some_and(|m| m.contains("Revoked by panic")),
				"the panic's words must survive the boundary: {err:?}"
			);
			// The process — and the connection — survived the panic.
			let reply = session.send(&cap, "still-there", &[]).await.unwrap();
			assert_eq!(reply, Argument::Symbol("calm".into()));
			session.close(crate::PendingWork::Cancel).await.unwrap();
			host.await.unwrap();
		})
		.await;
}

// `tell` is the fire-and-forget eventual-send (Goblins `<-np`): no answer is
// allocated and nothing settles, but the deliver still flushes to the wire
// in order, so a `send` issued after two tells observes their effect. This
// pins the queued-flush semantics: a tell returns once queued on the host,
// and its bytes leave before the ordered send's own deliver.
#[tokio::test]
async fn tell_flushes_in_order_before_a_following_send() {
	let local = LocalSet::new();
	local
		.run_until(async {
			let server = listen("127.0.0.1:0").await.unwrap();
			let addr = std::net::SocketAddr::from(([127, 0, 0, 1], server.port().unwrap()));

			let (ready_tx, ready_rx) = oneshot::channel::<()>();
			let host = tokio::task::spawn_local(async move {
				let session = server.accept().await.unwrap();
				let mut count: i64 = 0;
				session
					.publish("counter", move |verb, _args| match verb {
						"bump" => {
							count += 1;
							Ok(Argument::Void)
						}
						"get" => Ok(Argument::Integer(count)),
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
			let cap = session.fetch("counter").await.unwrap();
			session.tell(&cap, "bump", &[]).unwrap();
			session.tell(&cap, "bump", &[]).unwrap();
			let got = session.send(&cap, "get", &[]).await.unwrap();
			assert_eq!(got, Argument::Integer(2));
			session.close(crate::PendingWork::Cancel).await.unwrap();
			host.await.unwrap();
		})
		.await;
}

// A partner that disconnects mid-question must reject the outstanding send
// with a typed break, never hang it: the serve loop breaks every far vow
// when the stream ends. The partner is a real host whose behavior kills its
// own socket (a dup'd fd shut down inside the turn), so the reply can never
// leave and the client sees only the FIN.
#[tokio::test]
async fn an_outstanding_send_rejects_on_disconnect() {
	let local = LocalSet::new();
	local
		.run_until(async {
			let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
			let addr = listener.local_addr().unwrap();

			let host = tokio::task::spawn_local(async move {
				let (stream, _) = listener.accept().await.unwrap();
				// Dup the fd so the behavior can kill the transport out from
				// under its own host mid-turn.
				let std_stream = stream.into_std().unwrap();
				let dup = std_stream.try_clone().unwrap();
				let stream = tokio::net::TcpStream::from_std(std_stream).unwrap();
				let designator = match stream.local_addr() {
					Ok(a) => crate::tcp::address_designator(&a.ip().to_string(), a.port()),
					Err(_) => crate::tcp::address_designator("127.0.0.1", 0),
				};
				let captp = Host::new_host();
				let session = Session::establish_accepted(
					captp.shared(),
					crate::abi_constants::TRANSPORT_TCP,
					sys::DESIGNATOR_SCHEME_ADDRESS,
					"",
					stream,
					&designator,
					Some(HANDSHAKE_TIMEOUT),
					None,
				)
				.await
				.unwrap();
				session
					.publish("svc", move |verb, _args| {
						if verb == "hang" {
							// The socket dies before the reply can flush: the
							// client observes a disconnect, not an answer.
							let _ = dup.shutdown(std::net::Shutdown::Both);
						}
						Ok(Argument::Void)
					})
					.unwrap();
				session.serve().await.unwrap();
			});

			let session = connect(
				&crate::tcp::locator(&addr.ip().to_string(), addr.port()),
				ConnectOptions::default(),
			)
			.await
			.unwrap();
			let cap = session.fetch("svc").await.unwrap();
			let err = session.send(&cap, "hang", &[]).await.unwrap_err();
			assert_eq!(err.code(), crate::sys::ERR_CLOSED);
			assert_eq!(err.message(), Some("connection closed"));
			session.close(crate::PendingWork::Cancel).await.unwrap();
			host.await.unwrap();
		})
		.await;
}

// A fetch that cannot yield a capability rejects typed — a broken failure,
// never a hang and never a transport error. The engine breaks an unknown
// swissnum's fetch itself, so the failed fetch is observable without a
// doctored partner.
#[tokio::test]
async fn a_failed_fetch_rejects_typed() {
	let local = LocalSet::new();
	local
		.run_until(async {
			let server = listen("127.0.0.1:0").await.unwrap();
			let addr = std::net::SocketAddr::from(([127, 0, 0, 1], server.port().unwrap()));

			let (ready_tx, ready_rx) = oneshot::channel::<()>();
			let host = tokio::task::spawn_local(async move {
				let session = server.accept().await.unwrap();
				session.publish("svc", |_verb, _args| Ok(Argument::Void)).unwrap();
				ready_tx.send(()).unwrap();
				let _ = session.serve().await;
			});

			let session = connect(
				&crate::tcp::locator(&addr.ip().to_string(), addr.port()),
				ConnectOptions::default(),
			)
			.await
			.unwrap();
			ready_rx.await.unwrap();
			let err = session.fetch("not-a-capability").await.unwrap_err();
			assert_eq!(err.code(), crate::sys::ERR_BROKEN);
			assert_eq!(err.message(), Some("unknown swissnum"));
			session.close(crate::PendingWork::Cancel).await.unwrap();
			host.await.unwrap();
		})
		.await;
}

// A failed verb replies its typed refusal and leaves the session alive: a
// send to a never-granted far import is refused with its session code (not
// laundered into IO, not a dead session), and the same session then
// fetches and calls the published capability, proving the pump survived to
// serve the next verb.
#[tokio::test]
async fn a_failed_command_replies_typed_and_the_connection_survives() {
	let local = LocalSet::new();
	local
		.run_until(async {
			let server = listen("127.0.0.1:0").await.unwrap();
			let addr = std::net::SocketAddr::from(([127, 0, 0, 1], server.port().unwrap()));
			let (ready_tx, ready_rx) = oneshot::channel::<()>();
			let host = tokio::task::spawn_local(async move {
				let session = server.accept().await.unwrap();
				session
					.publish("svc", |verb, _args| {
						if verb != "ping" {
							return Err(format!("no such method: {verb}"));
						}
						Ok(Argument::String("pong".into()))
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

			// An inadmissible target: opaque Host id 999 was never minted, so
			// the Host refuses the deliver before selecting a session.
			let bogus = Ref::try_from(&Argument::Reference(Ref::bare_id(999))).unwrap();
			let err = session.send(&bogus, "ping", &[]).await.unwrap_err();
			assert_eq!(err.code(), crate::sys::ERR_NOT_FOUND);

			// The connection survived the refusal: the next verbs still work.
			let cap = session.fetch("svc").await.unwrap();
			let reply = session.send(&cap, "ping", &[]).await.unwrap();
			assert_eq!(reply, Argument::String("pong".into()));
			session.close(crate::PendingWork::Cancel).await.unwrap();
			host.await.unwrap();
		})
		.await;
}

// A local tell returns after admitting its detached behavior task. If that
// behavior tail-forwards to a target the Host refuses, the task has no answer
// channel; retain the exact refusal for the next observable verb instead of
// dropping it or condemning the otherwise-live session.
#[tokio::test]
async fn detached_local_tell_forward_retains_its_exact_refusal() {
	let local = LocalSet::new();
	local
		.run_until(async {
			let host = Host::new_host();
			let shared_host = host.shared();
			let pending = crate::Locator::bare(crate::abi_constants::TRANSPORT_TCP, "127.0.0.1:1");
			let owned = crate::uri::OwnedLocator::new(&pending).unwrap();
			let mut ptr = core::ptr::null_mut();
			crate::host::check_host(unsafe {
				ffi::glowcap_host_session_open_dialed_locator(shared_host.raw(), owned.borrow_view().unwrap(), &mut ptr)
			})
			.unwrap();

			let (stream, _peer) = tokio::io::duplex(1024);
			let shared = SessionShared::new(ptr, shared_host, stream);
			let bogus = Ref::bare_id(999);
			let proxy = shared
				.spawn_actor(Box::new(move |verb, args| crate::trampoline::TurnOutcome::Forward {
					target: bogus.clone(),
					verb: verb.to_string(),
					args: args.to_vec(),
				}))
				.unwrap();

			shared.tell(&proxy, "notify", &[]).unwrap();
			tokio::task::yield_now().await;
			let refusal = shared.tell(&proxy, "later", &[]).unwrap_err();
			assert_eq!(refusal.code(), crate::sys::ERR_NOT_FOUND);
			assert!(refusal.to_string().contains("UnknownCapability"), "{refusal}");

			shared.close_transport();
			tokio::task::yield_now().await;
			host.close(crate::PendingWork::Cancel).await.unwrap();
		})
		.await;
}

// A `send` to a `Ref` this same session spawned resolves in-process, not
// over the wire: the server hosts no such export, so a wire route would never
// reply. The local turn runs on first observation and the reply comes
// straight back.
#[tokio::test]
async fn send_to_a_self_spawned_actor_resolves_in_process() {
	let local = LocalSet::new();
	local
		.run_until(async {
			let server = listen("127.0.0.1:0").await.unwrap();
			let addr = std::net::SocketAddr::from(([127, 0, 0, 1], server.port().unwrap()));
			let host = tokio::task::spawn_local(async move {
				let session = server.accept().await.unwrap();
				session.serve().await.unwrap(); // ends when the client closes
			});

			let session = connect(
				&crate::tcp::locator(&addr.ip().to_string(), addr.port()),
				ConnectOptions::default(),
			)
			.await
			.unwrap();
			let me = session
				.spawn(|verb, args| {
					if verb != "greet" {
						return Err(format!("no such method: {verb}"));
					}
					let who = match args.first() {
						Some(Argument::String(s)) => s.as_str(),
						_ => "?",
					};
					Ok(Argument::String(format!("hi {who}")))
				})
				.unwrap();
			let reply = session
				.send(&me, "greet", &[Argument::String("self".into())])
				.await
				.unwrap();
			assert_eq!(reply, Argument::String("hi self".into()));
			session.close(crate::PendingWork::Cancel).await.unwrap();
			host.await.unwrap();
		})
		.await;
}

// The codec selector end-to-end on the session tier: two Cap'n Proto
// nodes complete the keyed handshake and carry a deliver whose arguments
// round-trip through the capnp codec — a big integer past int64 and a
// Keyword included, so the two rare marshal arms are witnessed alongside
// the codec.
#[tokio::test]
async fn capnp_hosts_handshake_and_round_trip_big_integer_and_keyword() {
	let local = LocalSet::new();
	local
		.run_until(async {
			let next_capnp_host = || {
				Host::with_options(crate::HostOptions {
					codec: Codec::Capnp,
					captp_version: crate::CaptpVersion::Next,
					features: crate::FeatureSet::FULL,
					..Default::default()
				})
				.unwrap()
			};
			let server = listen_with_host("127.0.0.1:0", next_capnp_host()).await.unwrap();
			let addr = std::net::SocketAddr::from(([127, 0, 0, 1], server.port().unwrap()));
			let (ready_tx, ready_rx) = oneshot::channel::<()>();
			let host = tokio::task::spawn_local(async move {
				let session = server.accept().await.unwrap();
				assert_eq!(
					session.profile().unwrap(),
					crate::SessionProfile {
						captp_version: crate::CaptpVersion::Next,
						codec: Codec::Capnp,
						features: crate::FeatureSet::FULL,
					}
				);
				session
					.publish("echo", |_verb, args| Ok(Argument::List(args.to_vec())))
					.unwrap();
				ready_tx.send(()).unwrap();
				session.serve().await.unwrap();
			});

			let session = connect_with_host(
				&crate::tcp::locator(&addr.ip().to_string(), addr.port()),
				next_capnp_host(),
			)
			.await
			.unwrap();
			assert_eq!(
				session.profile().unwrap(),
				crate::SessionProfile {
					captp_version: crate::CaptpVersion::Next,
					codec: Codec::Capnp,
					features: crate::FeatureSet::FULL,
				}
			);
			ready_rx.await.unwrap();
			let echo = session.fetch("echo").await.unwrap();
			// 2^80: past int64, so it must ride the ARG_BIG_INTEGER arm.
			let big = Argument::BigInteger {
				negative: false,
				digits: "1208925819614629174706176".to_string(),
			};
			let args = vec![
				big.clone(),
				Argument::Keyword("prio".into()),
				Argument::Bytes(b"hi".to_vec()),
				Argument::Error("failure is a value".into()),
				Argument::Struct(vec![
					("count".into(), Argument::Integer(7)),
					("name".into(), Argument::String("widget".into())),
				]),
			];
			let reply = session.send(&echo, "roundtrip", &args).await.unwrap();
			assert_eq!(reply, Argument::List(args));
			session.close(crate::PendingWork::Cancel).await.unwrap();
			host.await.unwrap();
		})
		.await;
}
