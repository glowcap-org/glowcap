//! Redeeming, resolver deferral, and live trace scenarios.

use super::support::*;

// Proving the `Some(via)` arm needs a real three-party handoff (a gifter
// introducing a third-party exporter, then a redeem dial), exactly what the
// live `rust-goblins-handoff` / `rust-iroh-handoff` steps drive; it cannot be
// staged on one loopback pair.
#[tokio::test]
async fn send_redeeming_matches_send_and_reports_no_exporter_without_a_handoff() {
	let local = LocalSet::new();
	local
		.run_until(async {
			let server = listen("127.0.0.1:0").await.unwrap();
			let addr = std::net::SocketAddr::from(([127, 0, 0, 1], server.port().unwrap()));

			let (ready_tx, ready_rx) = oneshot::channel::<()>();
			let host = tokio::task::spawn_local(async move {
				let session = server.accept().await.unwrap();
				let target = session
					.spawn(|_verb, _args| Ok(Argument::Symbol("reached".into())))
					.unwrap();
				session
					.publish("svc", move |verb, _args| match verb {
						"grab" => Ok((&target).into()),
						_ => Ok(Argument::String("plain".into())),
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
			let svc = session.fetch("svc").await.unwrap();

			// A plain value: the reply is the send's own, and no route.
			let flat = session.send_redeeming(&svc, "say", &[]).await.unwrap();
			assert_eq!(flat.reply, Argument::String("plain".into()));
			assert!(flat.via.is_none());

			// A far capability the partner published on this session: a live
			// route the host knows, but not one a redeem dialed.
			let handed = session.send_redeeming(&svc, "grab", &[]).await.unwrap();
			let member = Ref::try_from(&handed.reply).expect("grab answers with a capability");
			assert_ne!(member.id(), 0);
			assert!(handed.via.is_none());

			// The lifted capability is live, so the reply survived the extra
			// question intact.
			let reached = session.send(&member, "poke", &[]).await.unwrap();
			assert_eq!(reached, Argument::Symbol("reached".into()));

			session.close(crate::PendingWork::Cancel).await.unwrap();
			host.await.unwrap();
		})
		.await;
}

// `via` is a Host-retained view. Dropping the Rust value must not close the
// exporter session or invalidate capabilities that remain Host-scoped.

// Off-turn settlement: a behavior atomically defers onto a resolver vow
// (`Host::defer_turn`) and returns; the caller's reply arrives only
// when the parked resolver settles later — after real awaited work — as its
// own top-level event. A successful settle consumes the native authority, so
// the broken arm exercises a second call's fresh resolver.
#[tokio::test]
async fn an_async_worker_defers_its_answer_onto_a_resolver_vow() {
	let local = LocalSet::new();
	local
		.run_until(async {
			let captp = Host::new_host();
			let (resolver_tx, mut resolver_rx) = tokio::sync::mpsc::unbounded_channel();
			let behavior_host = captp.clone();
			captp
				.publish_giftable("worker", move || {
					let host = behavior_host.clone();
					let resolver_tx = resolver_tx.clone();
					Box::new(move |_verb, _args| {
						let resolver = host.defer_turn().map_err(|e| e.to_string())?;
						resolver_tx
							.send(resolver)
							.map_err(|_| "resolver observer closed".to_string())?;
						Ok(Argument::Void)
					})
				})
				.unwrap();
			let server = listen_with_host("127.0.0.1:0", captp).await.unwrap();
			let addr = std::net::SocketAddr::from(([127, 0, 0, 1], server.port().unwrap()));
			let host = tokio::task::spawn_local(async move {
				let session = server.accept().await.unwrap();
				session.serve().await.unwrap();
			});

			let session = connect(
				&crate::tcp::locator(&addr.ip().to_string(), addr.port()),
				ConnectOptions::default(),
			)
			.await
			.unwrap();
			let worker = session.fetch("worker").await.unwrap();

			let fulfilled = async {
				let mut resolver = resolver_rx
					.recv()
					.await
					.expect("the behavior parks one resolver per call");
				resolver.fulfill(&Argument::String("computed off-turn".into())).unwrap();
			};
			let (reply, ()) = tokio::join!(session.send(&worker, "work", &[]), fulfilled);
			assert_eq!(reply.unwrap(), Argument::String("computed off-turn".into()));

			let broken_arm = async {
				let mut resolver = resolver_rx
					.recv()
					.await
					.expect("the behavior parks one resolver per call");
				resolver.break_with("worker gave up").unwrap();
			};
			let (broken, ()) = tokio::join!(session.send(&worker, "work", &[]), broken_arm);
			let error = broken.unwrap_err();
			assert_eq!(error.kind(), ErrorKind::Broken);
			assert!(
				error.message().unwrap_or("").contains("worker gave up"),
				"break carries the worker's words, got {:?}",
				error.message()
			);

			let refused_then_broken = async {
				let mut resolver = resolver_rx
					.recv()
					.await
					.expect("the behavior parks one resolver per call");
				assert!(resolver.fulfill(&Argument::Reference(worker.clone())).is_err());
				resolver.break_with("plain-data fallback").unwrap();
			};
			let (broken, ()) = tokio::join!(session.send(&worker, "work", &[]), refused_then_broken,);
			let error = broken.unwrap_err();
			assert!(error.message().unwrap_or("").contains("plain-data fallback"));

			session.close(crate::PendingWork::Cancel).await.unwrap();
			host.await.unwrap();
		})
		.await;
}

// The same off-turn deferral with the worker hosted on a native-loop server
// (ADR-0112): the behavior fires inside a `glowcap_driver_step`, so
// `defer_turn` must find the turn latched to the loop's adopted Host (the
// step's deliver bracket), and the top-level resolver settle must reach the
// wire through a loop step rather than a byte-fed drain.
#[tokio::test]
async fn a_loop_hosted_worker_defers_its_answer_onto_a_resolver_vow() {
	let local = LocalSet::new();
	local
		.run_until(async {
			let server = listen("127.0.0.1:0").await.unwrap();
			let addr = std::net::SocketAddr::from(([127, 0, 0, 1], server.port().unwrap()));
			let captp = server.host();
			let (resolver_tx, mut resolver_rx) = tokio::sync::mpsc::unbounded_channel();
			let behavior_host = captp.clone();
			captp
				.publish_giftable("worker", move || {
					let host = behavior_host.clone();
					let resolver_tx = resolver_tx.clone();
					Box::new(move |_verb, _args| {
						let resolver = host.defer_turn().map_err(|e| e.to_string())?;
						resolver_tx
							.send(resolver)
							.map_err(|_| "resolver observer closed".to_string())?;
						Ok(Argument::Void)
					})
				})
				.unwrap();
			let hosted = tokio::task::spawn_local(async move {
				let session = server.accept().await.unwrap();
				session.serve().await.unwrap();
			});

			let session = connect(
				&crate::tcp::locator(&addr.ip().to_string(), addr.port()),
				ConnectOptions::default(),
			)
			.await
			.unwrap();
			let worker = session.fetch("worker").await.unwrap();

			let fulfilled = async {
				let mut resolver = resolver_rx.recv().await.expect("the behavior parks its resolver");
				resolver.fulfill(&Argument::String("computed off-turn".into())).unwrap();
			};
			let (reply, ()) = tokio::join!(session.send(&worker, "work", &[]), fulfilled);
			assert_eq!(reply.unwrap(), Argument::String("computed off-turn".into()));

			session.close(crate::PendingWork::Cancel).await.unwrap();
			hosted.await.unwrap();
		})
		.await;
}

/// Test-side base64 decode (RFC 4648, padded) — the veneer encodes, this
/// proves the round trip without pulling a crate into the dogfood.
fn b64_decode(s: &str) -> Vec<u8> {
	const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
	let value = |ch: u8| ALPHABET.iter().position(|a| *a == ch).unwrap() as u32;
	let mut out = Vec::new();
	for chunk in s.trim_end_matches('=').as_bytes().chunks(4) {
		let mut n = 0u32;
		for (i, &ch) in chunk.iter().enumerate() {
			n |= value(ch) << (18 - 6 * i);
		}
		out.push((n >> 16) as u8);
		if chunk.len() > 2 {
			out.push((n >> 8) as u8);
		}
		if chunk.len() > 3 {
			out.push(n as u8);
		}
	}
	out
}

// The live trace: the veneer stamps and forwards the native tap's facts, one
// flat record per fact — session-opened with the codec the handshake actually
// negotiated, the same verb outbound at the client and inbound at the server,
// and session-closed. Endpoint labeling belongs to the consumer, so the
// records carry only the session and direction.
#[tokio::test]
async fn the_live_trace_produces_the_timeline_schema() {
	use std::cell::RefCell;
	use std::rc::Rc;

	let local = LocalSet::new();
	local
		.run_until(async {
			let events: Rc<RefCell<Vec<crate::TraceEvent>>> = Rc::new(RefCell::new(Vec::new()));
			let sink_events = Rc::clone(&events);
			let uninstall = crate::enable_trace(
				Box::new(move |ev| {
					sink_events.borrow_mut().push(ev.clone());
					panic!("trace sink failure must stay observer-only");
				}),
				Some("smoke"),
			);

			let captp = Host::new_host();
			captp
				.publish_giftable("greeter", move || {
					Box::new(move |verb, _args| Ok(Argument::String(format!("hello {verb}"))))
				})
				.unwrap();
			let server = listen_with_host("127.0.0.1:0", captp).await.unwrap();
			let addr = std::net::SocketAddr::from(([127, 0, 0, 1], server.port().unwrap()));
			let host = tokio::task::spawn_local(async move {
				let session = server.accept().await.unwrap();
				session.serve().await.unwrap();
			});

			let session = connect(
				&crate::tcp::locator(&addr.ip().to_string(), addr.port()),
				ConnectOptions::default(),
			)
			.await
			.unwrap();
			let client_host = session.host();
			let greeter = session.fetch("greeter").await.unwrap();
			let reply = session.send(&greeter, "trace-me", &[]).await.unwrap();
			assert_eq!(reply, Argument::String("hello trace-me".into()));
			// The annotation channel: named for the same session row the
			// tap names.
			crate::annotate_session(&session, "greeter-server");
			session.close(crate::PendingWork::Cancel).await.unwrap();
			host.await.unwrap();
			uninstall();
			let diagnostics = client_host.take_failures().unwrap();
			assert!(diagnostics.iter().any(|failure| {
				failure.operation == "trace.sink"
					&& failure.scope_id > 0
					&& failure.primary_message == "trace sink failure must stay observer-only"
			}));

			let events = events.borrow();
			let opened: Vec<_> = events
				.iter()
				.filter(|ev| ev.kind == crate::TraceKind::SessionOpened)
				.collect();
			assert!(opened.len() >= 2, "both hosts' opens reached the one sink");
			assert!(
				opened
					.iter()
					.all(|ev| ev.codec == Some("syrup") && ev.a_label.as_deref() == Some("smoke")),
				"opens carry the negotiated codec and the application's display label",
			);
			// A producer states what it RUNS, because this schema is not
			// glowcap's alone and a consumer must not read an implementation off
			// the fact that a record arrived.
			assert!(
				opened.iter().all(|ev| ev.a_profile == Some("glowcap")),
				"an open states the implementation this producer runs",
			);
			// Identity and label are two facts. `a` is the host's own key
			// designator — the name a partner knows it by, and so the only name
			// two producers can agree on — and the label never stands in for it.
			assert!(
				opened.iter().all(|ev| {
					ev.a.as_deref()
						.is_some_and(|a| a.len() == 64 && a.chars().all(|c| c.is_ascii_hexdigit()))
				}),
				"an open's `a` endpoint is the reporting host's key designator",
			);
			// The OCapN Session ID is what lets a consumer merging two producers'
			// feeds tell one session watched twice from two unrelated ones: both
			// peers of this session derive it, so the two opens agree on it.
			let session_ids: Vec<_> = opened.iter().filter_map(|ev| ev.session_id.clone()).collect();
			assert_eq!(session_ids.len(), opened.len(), "every open named its OCapN Session ID",);
			assert!(
				session_ids.windows(2).all(|w| w[0] == w[1]),
				"both peers of one session report the same OCapN Session ID",
			);
			// A designator does not name a location on its own, so every open
			// carries the transport beside it.
			assert!(
				opened.iter().all(|ev| ev.transport.is_some()),
				"an open reported a designator with no transport",
			);
			let outbound = events
				.iter()
				.find(|ev| {
					ev.kind == crate::TraceKind::MessageDecoded && ev.op.as_deref() == Some("trace-me") && ev.outbound
				})
				.expect("the client's send traced outbound");
			let inbound = events
				.iter()
				.find(|ev| {
					ev.kind == crate::TraceKind::MessageDecoded && ev.op.as_deref() == Some("trace-me") && !ev.outbound
				})
				.expect("the server's deliver traced inbound");
			assert_ne!(outbound.session, inbound.session, "each host names its own session row",);
			// Payload: both fact sites sit at the wire boundary (inbound
			// dispatch, the outbound drain), so both records carry the whole
			// (sub-cap) frame with its true length and the verb inside it.
			for rec in [&inbound, &outbound] {
				let frame = b64_decode(rec.bytes_b64.as_deref().expect("the record carries its frame"));
				assert_eq!(rec.len, Some(frame.len()), "true length rides beside the frame");
				assert!(
					frame.windows(8).any(|w| w == b"trace-me"),
					"the frame bytes contain the delivered verb",
				);
			}
			assert!(
				events.iter().any(|ev| ev.kind == crate::TraceKind::SessionClosed),
				"the close reached the sink",
			);
			let meta = events
				.iter()
				.find(|ev| ev.kind == crate::TraceKind::SessionMeta)
				.expect("the annotation reached the sink");
			assert_eq!(
				meta.meta.as_ref().map(|m| m.label.as_str()),
				Some("greeter-server"),
				"the annotation carries its label",
			);
			assert_eq!(
				meta.session_id, outbound.session_id,
				"the annotation names the same session row the tap names",
			);
			let mut last = 0u64;
			for ev in events.iter() {
				assert!(ev.sim_t_ns >= last, "sim_t_ns is monotone");
				last = ev.sim_t_ns;
			}
		})
		.await;
}
