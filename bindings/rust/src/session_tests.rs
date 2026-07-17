use super::*;
use crate::connect;
use crate::listen::{listen, listen_with_host};
use crate::sys;
use crate::sys::driver as ffi;
use crate::AbortDomain;
use crate::Codec;
use crate::Host;
use crate::Reference;
use std::cell::Cell;
use std::sync::atomic::{AtomicUsize, Ordering};
use tokio::sync::oneshot;
use tokio::task::LocalSet;

// The callback latch crosses the binding: the public surface keeps a sync
// behavior away from every driving verb (they are all async), so this test
// reaches through the crate's own FFI mirror to prove the C tier refuses a
// mid-turn driving verb, the refusal surfaces as the behavior's own break,
// and the connection survives the refused turn.
#[tokio::test]
async fn a_mid_turn_driving_verb_breaks_its_own_answer() {
	let local = LocalSet::new();
	local
		.run_until(async {
			let server = listen("127.0.0.1:0").await.unwrap();
			let addr = server.local_addr().unwrap();

			let (ready_tx, ready_rx) = oneshot::channel::<()>();
			let host = tokio::task::spawn_local(async move {
				let conn = server.accept().await.unwrap();
				let raw = conn.shared.ptr.get();
				conn.publish("svc", move |verb, _args| {
					if verb == "reenter" {
						// A driving verb inside the turn: the latch refuses
						// it, and the error's words become the broken answer.
						let mut vow: u64 = 0;
						let rc = unsafe {
							ffi::pancake_host_session_fetch(raw, "nested".as_ptr(), 6, &mut vow)
						};
						if rc == sys::OK {
							return Err("a mid-turn fetch was NOT refused".to_string());
						}
						return Err(format!("mid-turn driving verb refused with rc {rc}"));
					}
					Ok(Argument::String("pong".into()))
				})
				.await
				.unwrap();
				ready_tx.send(()).unwrap();
				conn.serve().await;
			});

			let conn = connect(
				&crate::tcp_locator(&addr.ip().to_string(), addr.port()),
				None,
				None,
			)
			.await
			.unwrap();
			ready_rx.await.unwrap();
			let cap = conn.fetch("svc").await.unwrap();
			let broke = conn.send(&cap, "reenter", &[]).await.unwrap_err();
			assert!(
				broke.message().unwrap_or("").contains("refused"),
				"the refusal reaches the answer: {broke:?}"
			);
			// The turn unwound cleanly: the same session still answers.
			let pong = conn.send(&cap, "ping", &[]).await.unwrap();
			assert_eq!(pong, Argument::String("pong".into()));
			conn.close();
			host.await.unwrap();
		})
		.await;
}

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
			let addr = server.local_addr().unwrap();

			let (ready_tx, ready_rx) = oneshot::channel::<()>();
			let host = tokio::task::spawn_local(async move {
				let conn = server.accept().await.unwrap();
				conn.publish("greeter", |verb, _args| {
					if verb != "hello" {
						return Err(format!("no such method: {verb}"));
					}
					Ok(Argument::Symbol("alive".into()))
				})
				.await
				.unwrap();
				ready_tx.send(()).unwrap();
				conn.serve().await;
			});

			let conn = connect(
				&crate::tcp_locator(&addr.ip().to_string(), addr.port()),
				None,
				None,
			)
			.await
			.unwrap();
			ready_rx.await.unwrap();

			// The connection is already open; enliven keys on the sturdyref's
			// swissnum, carried by the URI as `/s/greeter`.
			let sturdyref = "ocapn://greeter-host.tcp/s/greeter";
			let cap = conn.enliven(sturdyref).await.unwrap();
			let reply = conn.send(&cap, "hello", &[]).await.unwrap();
			assert_eq!(reply, Argument::Symbol("alive".into()));

			// A repeat enliven hits the dedup cache: the same live capability.
			let again = conn.enliven(sturdyref).await.unwrap();
			assert_eq!(again.reference(), cap.reference());
			let reply2 = conn.send(&again, "hello", &[]).await.unwrap();
			assert_eq!(reply2, Argument::Symbol("alive".into()));

			conn.close();
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
			let addr = server.local_addr().unwrap();

			let (ready_tx, ready_rx) = oneshot::channel::<()>();
			let host = tokio::task::spawn_local(async move {
				let conn = server.accept().await.unwrap();
				conn.publish("svc", |verb, _args| {
					Err(match verb {
						"do" => "nope: revoked".to_string(),
						other => format!("no such method: {other}"),
					})
				})
				.await
				.unwrap();
				ready_tx.send(()).unwrap();
				conn.serve().await;
			});

			let conn = connect(
				&crate::tcp_locator(&addr.ip().to_string(), addr.port()),
				None,
				None,
			)
			.await
			.unwrap();
			ready_rx.await.unwrap();
			let cap = conn.fetch("svc").await.unwrap();
			let err = conn.send(&cap, "do", &[]).await.unwrap_err();
			assert_eq!(err.message(), Some("nope: revoked"));
			// A break is PANCAKE_ERR_BROKEN, not a transport or value error.
			assert_eq!(err.code(), crate::sys::ERR_BROKEN);
			conn.close();
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
			let addr = server.local_addr().unwrap();

			let (ready_tx, ready_rx) = oneshot::channel::<()>();
			let host = tokio::task::spawn_local(async move {
				let conn = server.accept().await.unwrap();
				conn.publish("svc", |verb, _args| {
					if verb == "explode" {
						panic!("Revoked by panic");
					}
					Ok(Argument::Symbol("calm".into()))
				})
				.await
				.unwrap();
				ready_tx.send(()).unwrap();
				conn.serve().await;
			});

			let conn = connect(
				&crate::tcp_locator(&addr.ip().to_string(), addr.port()),
				None,
				None,
			)
			.await
			.unwrap();
			ready_rx.await.unwrap();
			let cap = conn.fetch("svc").await.unwrap();
			let err = conn.send(&cap, "explode", &[]).await.unwrap_err();
			assert_eq!(err.code(), crate::sys::ERR_BROKEN);
			assert!(
				err.message()
					.is_some_and(|m| m.contains("Revoked by panic")),
				"the panic's words must survive the boundary: {err:?}"
			);
			// The process — and the connection — survived the panic.
			let reply = conn.send(&cap, "still-there", &[]).await.unwrap();
			assert_eq!(reply, Argument::Symbol("calm".into()));
			conn.close();
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
			let addr = server.local_addr().unwrap();

			let (ready_tx, ready_rx) = oneshot::channel::<()>();
			let host = tokio::task::spawn_local(async move {
				let conn = server.accept().await.unwrap();
				let mut count: i64 = 0;
				conn.publish("counter", move |verb, _args| match verb {
					"bump" => {
						count += 1;
						Ok(Argument::Void)
					}
					"get" => Ok(Argument::Integer(count)),
					other => Err(format!("no such method: {other}")),
				})
				.await
				.unwrap();
				ready_tx.send(()).unwrap();
				conn.serve().await;
			});

			let conn = connect(
				&crate::tcp_locator(&addr.ip().to_string(), addr.port()),
				None,
				None,
			)
			.await
			.unwrap();
			ready_rx.await.unwrap();
			let cap = conn.fetch("counter").await.unwrap();
			conn.tell(&cap, "bump", &[]).unwrap();
			conn.tell(&cap, "bump", &[]).unwrap();
			let got = conn.send(&cap, "get", &[]).await.unwrap();
			assert_eq!(got, Argument::Integer(2));
			conn.close();
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
					Ok(a) => crate::uri::socket_addr_designator(&a.ip().to_string(), a.port()),
					Err(_) => crate::uri::socket_addr_designator("127.0.0.1", 0),
				};
				let captp = Host::new_host();
				let conn = Session::establish_accepted(
					captp.shared(),
					crate::abi_constants::TRANSPORT_TCP,
					"",
					stream,
					&designator,
				)
				.await
				.unwrap();
				conn.publish("svc", move |verb, _args| {
					if verb == "hang" {
						// The socket dies before the reply can flush: the
						// client observes a disconnect, not an answer.
						let _ = dup.shutdown(std::net::Shutdown::Both);
					}
					Ok(Argument::Void)
				})
				.await
				.unwrap();
				conn.serve().await;
			});

			let conn = connect(
				&crate::tcp_locator(&addr.ip().to_string(), addr.port()),
				None,
				None,
			)
			.await
			.unwrap();
			let cap = conn.fetch("svc").await.unwrap();
			let err = conn.send(&cap, "hang", &[]).await.unwrap_err();
			assert_eq!(err.code(), crate::sys::ERR_CLOSED);
			assert_eq!(err.message(), Some("session closed"));
			conn.close();
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
			let addr = server.local_addr().unwrap();

			let (ready_tx, ready_rx) = oneshot::channel::<()>();
			let host = tokio::task::spawn_local(async move {
				let conn = server.accept().await.unwrap();
				conn.publish("svc", |_verb, _args| Ok(Argument::Void))
					.await
					.unwrap();
				ready_tx.send(()).unwrap();
				conn.serve().await;
			});

			let conn = connect(
				&crate::tcp_locator(&addr.ip().to_string(), addr.port()),
				None,
				None,
			)
			.await
			.unwrap();
			ready_rx.await.unwrap();
			let err = conn.fetch("not-a-capability").await.unwrap_err();
			assert_eq!(err.code(), crate::sys::ERR_BROKEN);
			assert_eq!(err.message(), Some("unknown swissnum"));
			conn.close();
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
			let addr = server.local_addr().unwrap();
			let (ready_tx, ready_rx) = oneshot::channel::<()>();
			let host = tokio::task::spawn_local(async move {
				let conn = server.accept().await.unwrap();
				conn.publish("svc", |verb, _args| {
					if verb != "ping" {
						return Err(format!("no such method: {verb}"));
					}
					Ok(Argument::String("pong".into()))
				})
				.await
				.unwrap();
				ready_tx.send(()).unwrap();
				conn.serve().await;
			});

			let conn = connect(
				&crate::tcp_locator(&addr.ip().to_string(), addr.port()),
				None,
				None,
			)
			.await
			.unwrap();
			ready_rx.await.unwrap();

			// An inadmissible target: import 999 was never granted by the
			// partner, so the session refuses the deliver locally.
			let bogus = Ref::try_from(&Argument::Reference(Reference::far(999))).unwrap();
			let err = conn.send(&bogus, "ping", &[]).await.unwrap_err();
			assert_eq!(err.code(), crate::sys::ERR_SESSION);

			// The connection survived the refusal: the next verbs still work.
			let cap = conn.fetch("svc").await.unwrap();
			let reply = conn.send(&cap, "ping", &[]).await.unwrap();
			assert_eq!(reply, Argument::String("pong".into()));
			conn.close();
			host.await.unwrap();
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
			let addr = server.local_addr().unwrap();
			let host = tokio::task::spawn_local(async move {
				let conn = server.accept().await.unwrap();
				conn.serve().await; // ends when the client closes
			});

			let conn = connect(
				&crate::tcp_locator(&addr.ip().to_string(), addr.port()),
				None,
				None,
			)
			.await
			.unwrap();
			let me = conn
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
				.await
				.unwrap();
			let reply = conn
				.send(&me, "greet", &[Argument::String("self".into())])
				.await
				.unwrap();
			assert_eq!(reply, Argument::String("hi self".into()));
			conn.close();
			host.await.unwrap();
		})
		.await;
}

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
			let addr = server.local_addr().unwrap();
			let (ready_tx, ready_rx) = oneshot::channel::<()>();
			let host = tokio::task::spawn_local(async move {
				let conn = server.accept().await.unwrap();
				// The task the board hands out: `complete` flips done and
				// `status` reports it. Pre-spawned because a behavior runs
				// synchronously and cannot itself await a spawn.
				let done = Cell::new(false);
				let task = conn
					.spawn(move |verb: &str, _args: &[Argument]| match verb {
						"assign" => Ok(Argument::String("assigned".into())),
						"complete" => {
							done.set(true);
							Ok(Argument::String("done".into()))
						}
						"status" => Ok(Argument::String(
							if done.get() { "done" } else { "open" }.into(),
						)),
						other => Err(format!("no such method: {other}")),
					})
					.await
					.unwrap();
				conn.publish("root", move |verb, _args| {
					if verb != "create" {
						return Err(format!("no such method: {verb}"));
					}
					Ok((&task).into())
				})
				.await
				.unwrap();
				ready_tx.send(()).unwrap();
				conn.serve().await;
			});

			let conn = connect(
				&crate::tcp_locator(&addr.ip().to_string(), addr.port()),
				None,
				None,
			)
			.await
			.unwrap();
			ready_rx.await.unwrap();
			let root = conn.fetch("root").await.unwrap();
			// The four verbs leave together: none awaits create's reply, and
			// assign / complete / status target the create answer directly.
			let task = conn.send(&root, "create", &[Argument::String("benchmark".into())]);
			conn.send(&task, "assign", &[Argument::String("alice".into())]);
			conn.send(&task, "complete", &[]);
			let status = conn.send(&task, "status", &[]).await.unwrap();
			assert_eq!(status, Argument::String("done".into()));
			conn.close();
			host.await.unwrap();
		})
		.await;
}

// The local-turn latch (the wire path's `TurnGuard`, mirrored for locally-run
// behaviors): a behavior that drops its own captured `Session` mid-turn
// takes `Drop`'s `close_transport`, whose immediate-release arm would free
// the `Box<ActorCell>` whose behavior frame is still on the stack — a
// use-after-free. `run_hosted`'s marker parks the release instead and drains
// it once the turn unwinds, so the send settles, the parked release runs,
// and the connection is released after the turn.
#[tokio::test]
async fn a_behavior_closing_its_own_connection_mid_local_send_parks_the_release() {
	let local = LocalSet::new();
	local
		.run_until(async {
			let server = listen("127.0.0.1:0").await.unwrap();
			let addr = server.local_addr().unwrap();
			let host = tokio::task::spawn_local(async move {
				let conn = server.accept().await.unwrap();
				conn.serve().await; // ends when the client closes
			});

			let conn = connect(
				&crate::tcp_locator(&addr.ip().to_string(), addr.port()),
				None,
				None,
			)
			.await
			.unwrap();
			// A second handle over the same session, moved into the
			// behavior so its `Drop` (which closes the shared transport)
			// fires inside the behavior's own turn.
			let captured = Cell::new(Some(Session {
				shared: Rc::clone(&conn.shared),
			}));
			let me = conn
				.spawn(move |verb, _args| {
					if verb == "die" {
						drop(captured.take());
						return Ok(Argument::Symbol("closing".into()));
					}
					Ok(Argument::Void)
				})
				.await
				.unwrap();
			let reply = conn.send(&me, "die", &[]).await.unwrap();
			assert_eq!(reply, Argument::Symbol("closing".into()));
			// The turn unwound: the parked release ran (nothing left parked)
			// and the connection is released, so the next verb is refused
			// closed rather than crashing.
			assert_eq!(crate::host::pending_release_count(), 0);
			assert!(conn.shared.released.get());
			let err = conn.send(&me, "die", &[]).await.unwrap_err();
			assert_eq!(err.kind(), crate::ErrorKind::Closed);
			host.await.unwrap();
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
			let server = listen("127.0.0.1:0").await.unwrap();
			let addr = server.local_addr().unwrap();
			let (ready_tx, ready_rx) = oneshot::channel::<()>();
			let host = tokio::task::spawn_local(async move {
				let conn = server.accept().await.unwrap();
				conn.publish("root", |verb, args| {
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
				.await
				.unwrap();
				ready_tx.send(()).unwrap();
				conn.serve().await;
			});

			let conn = connect(
				&crate::tcp_locator(&addr.ip().to_string(), addr.port()),
				None,
				None,
			)
			.await
			.unwrap();
			ready_rx.await.unwrap();
			let root = conn.fetch("root").await.unwrap();
			// Neither projection awaits a prior reply: they ride the
			// unresolved make answer and the whole chain leaves on one flush.
			let made = conn.send(&root, "make", &[Argument::String("alice".into())]);
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
			conn.close();
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
			let addr = server.local_addr().unwrap();
			let (tool_ready_tx, tool_ready_rx) = oneshot::channel::<()>();
			let (proxy_ready_tx, proxy_ready_rx) = oneshot::channel::<()>();

			let host = tokio::task::spawn_local(async move {
				let conn = server.accept().await.unwrap();
				// Wait for the client to publish its tool, then fetch it: a far
				// reference this host wraps.
				tool_ready_rx.await.unwrap();
				let tool = conn.fetch("tool").await.unwrap();

				let care = conn.caretaker(&tool).await.unwrap();
				let proxy = care.proxy.clone();
				let readonly = conn.attenuate(&tool, &["get"]).await.unwrap();

				conn.publish("root", move |verb, _args| match verb {
					"proxy" => Ok((&proxy).into()),
					"readonly" => Ok((&readonly).into()),
					"revoke" => {
						care.revoke();
						Ok(Argument::Void)
					}
					other => Err(format!("no such method: {other}")),
				})
				.await
				.unwrap();
				proxy_ready_tx.send(()).unwrap();
				conn.serve().await;
			});

			let conn = connect(
				&crate::tcp_locator(&addr.ip().to_string(), addr.port()),
				None,
				None,
			)
			.await
			.unwrap();
			// The tool the host will wrap: `add` increments, `get` reads.
			conn.publish("tool", |verb, args| match verb {
				"add" => {
					let n = args.first().and_then(|a| a.as_i64()).unwrap_or(0);
					Ok(Argument::Integer(n + 1))
				}
				"get" => Ok(Argument::Integer(7)),
				other => Err(format!("no such method: {other}")),
			})
			.await
			.unwrap();
			tool_ready_tx.send(()).unwrap();
			proxy_ready_rx.await.unwrap();

			let root = conn.fetch("root").await.unwrap();

			// Live caretaker: a call forwards across the host to the far tool.
			let proxy = Ref::try_from(&conn.send(&root, "proxy", &[]).await.unwrap()).unwrap();
			let reply = conn
				.send(&proxy, "add", &[Argument::Integer(41)])
				.await
				.unwrap();
			assert_eq!(reply, Argument::Integer(42));

			// Attenuator: the allow-listed verb forwards; any other breaks.
			let readonly =
				Ref::try_from(&conn.send(&root, "readonly", &[]).await.unwrap()).unwrap();
			let got = conn.send(&readonly, "get", &[]).await.unwrap();
			assert_eq!(got, Argument::Integer(7));
			let denied = conn
				.send(&readonly, "add", &[Argument::Integer(1)])
				.await
				.unwrap_err();
			assert!(denied.to_string().contains("Attenuated"), "{denied}");

			// Revoke: every later call through the proxy breaks.
			conn.send(&root, "revoke", &[]).await.unwrap();
			let severed = conn
				.send(&proxy, "add", &[Argument::Integer(1)])
				.await
				.unwrap_err();
			assert!(severed.to_string().contains("Revoked"), "{severed}");

			conn.close();
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
			let addr = server.local_addr().unwrap();
			let host = tokio::task::spawn_local(async move {
				let conn = server.accept().await.unwrap();
				conn.publish("tool", |verb, _args| match verb {
					"ping" => Ok(Argument::Integer(99)),
					other => Err(format!("no such method: {other}")),
				})
				.await
				.unwrap();
				conn.serve().await;
			});

			let conn = connect(
				&crate::tcp_locator(&addr.ip().to_string(), addr.port()),
				None,
				None,
			)
			.await
			.unwrap();

			// A caretaker over a local tool, called locally by its own host.
			let local_tool = conn
				.spawn(|verb, args| match verb {
					"double" => {
						let n = args.first().and_then(|a| a.as_i64()).unwrap_or(0);
						Ok(Argument::Integer(n * 2))
					}
					other => Err(format!("no such method: {other}")),
				})
				.await
				.unwrap();
			let care_local = conn.caretaker(&local_tool).await.unwrap();
			let doubled = conn
				.send(&care_local.proxy, "double", &[Argument::Integer(21)])
				.await
				.unwrap();
			assert_eq!(doubled, Argument::Integer(42));

			// A caretaker over a far tool, called locally: the proxy forwards
			// across the wire and the local send still settles on the reply.
			let far = conn.fetch("tool").await.unwrap();
			let care_far = conn.caretaker(&far).await.unwrap();
			let pong = conn.send(&care_far.proxy, "ping", &[]).await.unwrap();
			assert_eq!(pong, Argument::Integer(99));

			// Revoke severs the local call exactly as it severs a partner's.
			care_local.revoke();
			let severed = conn
				.send(&care_local.proxy, "double", &[Argument::Integer(1)])
				.await
				.unwrap_err();
			assert!(severed.to_string().contains("Revoked"), "{severed}");

			conn.close();
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
			let server = listen_with_host("127.0.0.1:0", Host::with_codec(Codec::Capnp))
				.await
				.unwrap();
			let addr = server.local_addr().unwrap();
			let (ready_tx, ready_rx) = oneshot::channel::<()>();
			let host = tokio::task::spawn_local(async move {
				let conn = server.accept().await.unwrap();
				conn.publish("echo", |_verb, args| Ok(Argument::List(args.to_vec())))
					.await
					.unwrap();
				ready_tx.send(()).unwrap();
				conn.serve().await;
			});

			let conn = connect(
				&crate::tcp_locator(&addr.ip().to_string(), addr.port()),
				None,
				Some(Host::with_codec(Codec::Capnp)),
			)
			.await
			.unwrap();
			ready_rx.await.unwrap();
			let echo = conn.fetch("echo").await.unwrap();
			// 2^80: past int64, so it must ride the ARG_BIG_INTEGER arm.
			let big = Argument::BigInteger {
				negative: false,
				digits: "1208925819614629174706176".to_string(),
			};
			let args = vec![
				big.clone(),
				Argument::Keyword("prio".into()),
				Argument::Bytes(b"hi".to_vec()),
			];
			let reply = conn.send(&echo, "roundtrip", &args).await.unwrap();
			assert_eq!(reply, Argument::List(args));
			conn.close();
			host.await.unwrap();
		})
		.await;
}

// A byte stream wrapper that watches inbound bytes for a needle — the
// observer half of the wire-observing scenarios, standing where the old raw
// peer partner scripts stood.
struct Scanning<S> {
	inner: S,
	needle: &'static [u8],
	seen: Rc<Cell<bool>>,
	tail: Vec<u8>,
}

impl<S> Scanning<S> {
	fn new(inner: S, needle: &'static [u8], seen: Rc<Cell<bool>>) -> Scanning<S> {
		Scanning {
			inner,
			needle,
			seen,
			tail: Vec::new(),
		}
	}

	fn scan(&mut self, fresh: &[u8]) {
		self.tail.extend_from_slice(fresh);
		if self
			.tail
			.windows(self.needle.len())
			.any(|window| window == self.needle)
		{
			self.seen.set(true);
		}
		// Keep only enough tail to catch a needle across chunk boundaries.
		let keep = self.needle.len().saturating_sub(1);
		if self.tail.len() > keep {
			self.tail.drain(..self.tail.len() - keep);
		}
	}
}

impl<S: AsyncRead + Unpin> AsyncRead for Scanning<S> {
	fn poll_read(
		mut self: std::pin::Pin<&mut Self>,
		cx: &mut std::task::Context<'_>,
		buf: &mut tokio::io::ReadBuf<'_>,
	) -> std::task::Poll<std::io::Result<()>> {
		let before = buf.filled().len();
		let poll = std::pin::Pin::new(&mut self.inner).poll_read(cx, buf);
		if let std::task::Poll::Ready(Ok(())) = &poll {
			let fresh = buf.filled()[before..].to_vec();
			self.scan(&fresh);
		}
		poll
	}
}

impl<S: AsyncWrite + Unpin> AsyncWrite for Scanning<S> {
	fn poll_write(
		mut self: std::pin::Pin<&mut Self>,
		cx: &mut std::task::Context<'_>,
		src: &[u8],
	) -> std::task::Poll<std::io::Result<usize>> {
		std::pin::Pin::new(&mut self.inner).poll_write(cx, src)
	}

	fn poll_flush(
		mut self: std::pin::Pin<&mut Self>,
		cx: &mut std::task::Context<'_>,
	) -> std::task::Poll<std::io::Result<()>> {
		std::pin::Pin::new(&mut self.inner).poll_flush(cx)
	}

	fn poll_shutdown(
		mut self: std::pin::Pin<&mut Self>,
		cx: &mut std::task::Context<'_>,
	) -> std::task::Poll<std::io::Result<()>> {
		std::pin::Pin::new(&mut self.inner).poll_shutdown(cx)
	}
}

async fn wait_for(flag: &Rc<Cell<bool>>, what: &str) {
	for _ in 0..2000 {
		if flag.get() {
			return;
		}
		tokio::time::sleep(std::time::Duration::from_millis(5)).await;
	}
	panic!("timed out waiting for {what}");
}

// Distributed GC (ADR-0063), opt-in: a client that enables GC and fetches a
// capability releases its import — a single `op:gc-exports`, routed through
// the host by its node-unique token — when the last `Ref` to it drops, so
// the partner can release the matching export. The partner observes the
// release frame on its own wire through a scanning transport.
#[tokio::test]
async fn dropping_a_fetched_cap_releases_its_import_when_gc_is_on() {
	let local = LocalSet::new();
	local
		.run_until(async {
			let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
			let addr = listener.local_addr().unwrap();
			let seen = Rc::new(Cell::new(false));

			let seen_by_host = Rc::clone(&seen);
			let host = tokio::task::spawn_local(async move {
				let (stream, _) = listener.accept().await.unwrap();
				let designator = match stream.local_addr() {
					Ok(a) => crate::uri::socket_addr_designator(&a.ip().to_string(), a.port()),
					Err(_) => crate::uri::socket_addr_designator("127.0.0.1", 0),
				};
				let stream = Scanning::new(stream, b"op:gc-export", seen_by_host);
				let captp = Host::new_host();
				let conn = Session::establish_accepted(
					captp.shared(),
					crate::abi_constants::TRANSPORT_TCP,
					"",
					stream,
					&designator,
				)
				.await
				.unwrap();
				conn.publish("svc", |_verb, _args| Ok(Argument::Void))
					.await
					.unwrap();
				conn.serve().await;
			});

			let conn = connect(
				&crate::tcp_locator(&addr.ip().to_string(), addr.port()),
				None,
				None,
			)
			.await
			.unwrap()
			.with_gc();
			let cap = conn.fetch("svc").await.unwrap();
			// Dropping the only handle parks the token; the serve task drains
			// it into one `pancake_host_gc_release`, which rides the wire as
			// op:gc-exports.
			drop(cap);
			wait_for(&seen, "the partner to observe op:gc-exports").await;
			conn.close();
			host.await.unwrap();
		})
		.await;
}

// The feed-failure choreography (the embedder contract): a garbage frame
// makes the partner's feed refuse, and the partner still drains its
// outbound so the typed `op:abort` the core projected reaches this side —
// observed here on the client's own wire through a scanning transport.
#[tokio::test]
async fn a_refused_feed_writes_the_typed_abort_for_the_partner() {
	let local = LocalSet::new();
	local
		.run_until(async {
			let server = listen("127.0.0.1:0").await.unwrap();
			let addr = server.local_addr().unwrap();
			let (ready_tx, ready_rx) = oneshot::channel::<()>();
			let host = tokio::task::spawn_local(async move {
				let conn = server.accept().await.unwrap();
				conn.publish("svc", |_verb, _args| Ok(Argument::Void))
					.await
					.unwrap();
				ready_tx.send(()).unwrap();
				conn.serve().await;
			});

			// Dial by hand so the inbound bytes pass through the scanner and
			// a dup'd fd can inject garbage after the session opens.
			let stream = tokio::net::TcpStream::connect(addr).await.unwrap();
			let peer = stream.peer_addr().unwrap();
			let std_stream = stream.into_std().unwrap();
			let dup = std_stream.try_clone().unwrap();
			let stream = tokio::net::TcpStream::from_std(std_stream).unwrap();
			let seen = Rc::new(Cell::new(false));
			let stream = Scanning::new(stream, b"op:abort", Rc::clone(&seen));
			let captp = Host::new_host();
			let designator =
				crate::uri::socket_addr_designator(&peer.ip().to_string(), peer.port());
			let conn = Session::establish_dialed_locator(
				captp.shared(),
				crate::abi_constants::TRANSPORT_TCP,
				&designator,
				stream,
			)
			.await
			.unwrap();
			ready_rx.await.unwrap();
			let _cap = conn.fetch("svc").await.unwrap();

			// Inject bytes no codec accepts, straight onto the socket.
			use std::io::Write;
			(&dup).write_all(b"this is not a syrup frame").unwrap();

			// The server's refused feed leaves a typed op:abort on its
			// outbound queue and writes it before releasing; it lands here.
			wait_for(&seen, "the typed op:abort from the partner").await;
			conn.close();
			host.await.unwrap();
		})
		.await;
}

// The local half of the same choreography: the side whose OWN feed refuses
// surfaces the typed cause on the error — `Error::abort()` populated with
// the refusing layer and the projected kind — not just the flat code the
// wire-observing sibling above watches from the partner's side. Split from
// that test because the refusal must reach a caller: the serve loop's feed
// error has none, so this feeds the garbage through the pump directly.
#[tokio::test]
async fn a_refused_feed_surfaces_the_typed_abort_locally() {
	let local = LocalSet::new();
	local
		.run_until(async {
			let server = listen("127.0.0.1:0").await.unwrap();
			let addr = server.local_addr().unwrap();
			let host = tokio::task::spawn_local(async move {
				let conn = server.accept().await.unwrap();
				conn.serve().await; // ends when the client tears down
			});

			let conn = connect(
				&crate::tcp_locator(&addr.ip().to_string(), addr.port()),
				None,
				None,
			)
			.await
			.unwrap();
			// Bytes no codec accepts, fed straight into this side's pump: the
			// core refuses the frame and projects a typed op:abort.
			let err = crate::pump::feed(&conn.shared, b"this is not a syrup frame")
				.await
				.unwrap_err();
			let abort = err.abort().expect("the refusal carries its typed cause");
			assert_eq!(abort.domain, AbortDomain::Codec);
			assert!(
				abort.kind.as_deref().is_some_and(|kind| !kind.is_empty()),
				"the projected abort kind is populated: {abort:?}"
			);
			conn.close();
			host.await.unwrap();
		})
		.await;
}

// A node whose host allocates through a caller-supplied context routes its
// bytes through that allocator, and releasing the host (and its
// connections) before the context keeps the drop order honest.
#[tokio::test]
async fn drives_a_host_in_a_context_with_a_custom_allocator() {
	use std::sync::Arc;

	struct Counting {
		allocs: Arc<AtomicUsize>,
	}
	impl crate::ContextAllocator for Counting {
		fn alloc(&self, size: usize, alignment: usize) -> *mut u8 {
			self.allocs.fetch_add(1, Ordering::Relaxed);
			let layout = std::alloc::Layout::from_size_align(size, alignment).unwrap();
			unsafe { std::alloc::alloc(layout) }
		}
		unsafe fn free(&self, ptr: *mut u8, size: usize, alignment: usize) {
			let layout = std::alloc::Layout::from_size_align(size, alignment).unwrap();
			std::alloc::dealloc(ptr, layout);
		}
	}

	let allocs = Arc::new(AtomicUsize::new(0));
	// Declared before the LocalSet so it drops last: every host byte is
	// freed through the allocator before the context goes away.
	let ctx = crate::Context::with_allocator(Box::new(Counting {
		allocs: allocs.clone(),
	}))
	.unwrap();
	let local = LocalSet::new();
	local
		.run_until(async {
			let captp = Host::new_in(&ctx, Codec::Syrup).unwrap();
			let server = listen_with_host("127.0.0.1:0", captp).await.unwrap();
			let addr = server.local_addr().unwrap();
			let (ready_tx, ready_rx) = oneshot::channel::<()>();
			let host = tokio::task::spawn_local(async move {
				let conn = server.accept().await.unwrap();
				conn.publish("svc", |_verb, _args| Ok(Argument::Symbol("alive".into())))
					.await
					.unwrap();
				ready_tx.send(()).unwrap();
				conn.serve().await;
			});

			let conn = connect(
				&crate::tcp_locator(&addr.ip().to_string(), addr.port()),
				None,
				None,
			)
			.await
			.unwrap();
			ready_rx.await.unwrap();
			let cap = conn.fetch("svc").await.unwrap();
			let reply = conn.send(&cap, "ping", &[]).await.unwrap();
			assert_eq!(reply, Argument::Symbol("alive".into()));
			conn.close();
			host.await.unwrap();
		})
		.await;
	// The context-backed host actually serviced the conversation.
	assert!(allocs.load(Ordering::Relaxed) > 0);
	drop(local); // every task (and its node Rc) unwinds before the context
}
