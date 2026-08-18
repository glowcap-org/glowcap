use super::*;
use crate::sys;
use crate::sys::host as ffi;
use crate::tcp;
use crate::AbortDomain;
use crate::Codec;
use crate::ErrorKind;
use crate::Host;
use crate::Ref;
use crate::{ConnectOptions, RuntimeConfig};
use std::cell::Cell;
use std::sync::atomic::{AtomicUsize, Ordering};
use tokio::sync::oneshot;
use tokio::task::LocalSet;

async fn connect(locator: &crate::Locator, options: ConnectOptions<'_>) -> crate::Result<crate::Session> {
	let runtime = crate::Runtime::open(RuntimeConfig::providers([crate::tcp::provider(Default::default())])).await?;
	runtime.connect(locator, options).await
}

async fn connect_with_host(locator: &crate::Locator, host: Host) -> crate::Result<crate::Session> {
	let runtime =
		crate::Runtime::open(RuntimeConfig::providers([crate::tcp::provider(Default::default())]).adopt_host(&host))
			.await?;
	runtime.connect(locator, ConnectOptions::default()).await
}

async fn connect_with_runtime_options(
	locator: &crate::Locator,
	options: crate::RuntimeConfig,
) -> crate::Result<crate::Session> {
	let runtime = crate::Runtime::open(options).await?;
	runtime.connect(locator, ConnectOptions::default()).await
}

async fn listen(address: &str) -> crate::Result<tcp::Server> {
	let (host, port) = crate::designator_host_port(address)?;
	tcp::listen(&host, port, tcp::ListenOptions::default()).await
}

async fn listen_with_host(address: &str, host: Host) -> crate::Result<tcp::Server> {
	let (bind_host, port) = crate::designator_host_port(address)?;
	tcp::listen(
		&bind_host,
		port,
		tcp::ListenOptions {
			identity: crate::ListenerIdentity::Host(host),
			..tcp::ListenOptions::default()
		},
	)
	.await
}

struct PendingFlushStream {
	flush_polled: Rc<Cell<bool>>,
}

impl AsyncRead for PendingFlushStream {
	fn poll_read(
		self: std::pin::Pin<&mut Self>,
		_cx: &mut std::task::Context<'_>,
		_buf: &mut tokio::io::ReadBuf<'_>,
	) -> std::task::Poll<std::io::Result<()>> {
		std::task::Poll::Pending
	}
}

impl AsyncWrite for PendingFlushStream {
	fn poll_write(
		self: std::pin::Pin<&mut Self>,
		_cx: &mut std::task::Context<'_>,
		src: &[u8],
	) -> std::task::Poll<std::io::Result<usize>> {
		std::task::Poll::Ready(Ok(src.len()))
	}

	fn poll_flush(
		self: std::pin::Pin<&mut Self>,
		_cx: &mut std::task::Context<'_>,
	) -> std::task::Poll<std::io::Result<()>> {
		self.flush_polled.set(true);
		std::task::Poll::Pending
	}

	fn poll_shutdown(
		self: std::pin::Pin<&mut Self>,
		_cx: &mut std::task::Context<'_>,
	) -> std::task::Poll<std::io::Result<()>> {
		std::task::Poll::Ready(Ok(()))
	}
}

#[tokio::test]
async fn cancelling_during_transport_flush_tears_the_stream() {
	let local = LocalSet::new();
	local
		.run_until(async {
			let host = Host::new_host();
			let shared_host = host.shared();
			let pending = crate::Locator::bare(crate::abi_constants::TRANSPORT_TCP, "127.0.0.1:1");
			let owned = crate::uri::OwnedLocator::new(&pending).unwrap();
			let mut ptr = core::ptr::null_mut();
			crate::host::check_host(unsafe {
				ffi::pancake_host_session_open_dialed_locator(shared_host.raw(), owned.borrow_view().unwrap(), &mut ptr)
			})
			.unwrap();

			let flush_polled = Rc::new(Cell::new(false));
			let shared = SessionShared::new(
				ptr,
				shared_host,
				PendingFlushStream {
					flush_polled: Rc::clone(&flush_polled),
				},
			);
			let cancelled = tokio::time::timeout(
				std::time::Duration::from_millis(20),
				crate::pump::flush_outbound(&shared),
			)
			.await;
			assert!(cancelled.is_err(), "the pending transport flush was cancelled");
			assert!(flush_polled.get(), "the frame reached the transport flush");
			assert!(shared.torn.get(), "cancellation marks the byte stream torn");
			let refused = crate::pump::flush_outbound(&shared).await.unwrap_err();
			assert_eq!(refused.kind(), ErrorKind::Closed);
			host.close(crate::PendingWork::Cancel).await.unwrap();
		})
		.await;
}

#[tokio::test]
async fn closing_cancels_a_backpressured_transport_flush() {
	let local = LocalSet::new();
	local
		.run_until(async {
			let host = Host::new_host();
			let shared_host = host.shared();
			let pending = crate::Locator::bare(crate::abi_constants::TRANSPORT_TCP, "127.0.0.1:1");
			let owned = crate::uri::OwnedLocator::new(&pending).unwrap();
			let mut ptr = core::ptr::null_mut();
			crate::host::check_host(unsafe {
				ffi::pancake_host_session_open_dialed_locator(shared_host.raw(), owned.borrow_view().unwrap(), &mut ptr)
			})
			.unwrap();

			let flush_polled = Rc::new(Cell::new(false));
			let shared = SessionShared::new(
				ptr,
				shared_host,
				PendingFlushStream {
					flush_polled: Rc::clone(&flush_polled),
				},
			);
			let flushing = {
				let shared = Rc::clone(&shared);
				tokio::task::spawn_local(async move { crate::pump::flush_outbound(&shared).await })
			};
			while !flush_polled.get() {
				tokio::task::yield_now().await;
			}
			shared.close_transport();
			let result = tokio::time::timeout(std::time::Duration::from_millis(100), flushing)
				.await
				.expect("session close wakes the pending flush")
				.expect("flush task did not panic");
			assert_eq!(result.unwrap_err().kind(), ErrorKind::Closed);
			host.close(crate::PendingWork::Cancel).await.unwrap();
		})
		.await;
}

#[tokio::test]
async fn a_wire_failure_is_the_first_terminal_cause() {
	let local = LocalSet::new();
	local
		.run_until(async {
			let host = Host::new_host();
			let shared_host = host.shared();
			let locator = crate::Locator::bare(crate::abi_constants::TRANSPORT_TCP, "127.0.0.1:1");
			let owned = crate::uri::OwnedLocator::new(&locator).unwrap();
			let mut ptr = core::ptr::null_mut();
			crate::host::check_host(unsafe {
				ffi::pancake_host_session_open_dialed_locator(shared_host.raw(), owned.borrow_view().unwrap(), &mut ptr)
			})
			.unwrap();
			let (stream, _peer) = tokio::io::duplex(64);
			let shared = SessionShared::new(ptr, shared_host, stream);
			let first = crate::Error::with_detail(crate::sys::ERR_IO, "frame write failed".to_string());
			let later = crate::Error::with_detail(crate::sys::ERR_INTERNAL, "close bookkeeping failed".to_string());

			shared.record_wire_failure(first.clone());
			shared.record_wire_failure(later);
			shared.record_close_result(crate::sys::OK);

			assert_eq!(shared.terminal_result().unwrap_err(), first);
			shared.close_transport();
			host.close(crate::PendingWork::Cancel).await.unwrap();
		})
		.await;
}

#[tokio::test]
async fn cancelling_a_session_close_waiter_does_not_stop_the_shared_driver() {
	let local = LocalSet::new();
	local
		.run_until(async {
			let host = Host::new_host();
			let shared_host = host.shared();
			let pending = crate::Locator::bare(crate::abi_constants::TRANSPORT_TCP, "127.0.0.1:1");
			let owned = crate::uri::OwnedLocator::new(&pending).unwrap();
			let mut ptr = core::ptr::null_mut();
			check_host(unsafe {
				ffi::pancake_host_session_open_dialed_locator(shared_host.raw(), owned.borrow_view().unwrap(), &mut ptr)
			})
			.unwrap();

			// The negotiating session is admitted pending work, so FINISH reaches
			// its deadline unless the retained close driver keeps supplying time.
			let (stream, _peer) = tokio::io::duplex(4096);
			let shared = SessionShared::new(ptr, shared_host, stream);
			let session = Rc::new(Session::owning(Rc::clone(&shared)));
			let first = {
				let session = Rc::clone(&session);
				tokio::task::spawn_local(async move {
					session
						.close(crate::PendingWork::Finish {
							grace: Some(Duration::from_millis(20)),
						})
						.await
				})
			};
			tokio::task::yield_now().await;
			assert!(
				shared.close_task.borrow().is_some(),
				"explicit close installed its shared driver"
			);
			first.abort();
			let _ = first.await;

			tokio::time::timeout(Duration::from_millis(500), async {
				while !shared.released.get() {
					tokio::task::yield_now().await;
				}
			})
			.await
			.expect("the shared close driver survived waiter cancellation");
			let error = session
				.close(crate::PendingWork::Finish { grace: None })
				.await
				.expect_err("the shared finite finish reports its timeout");
			assert_eq!(error.kind(), crate::ErrorKind::TimedOut);
			host.close(crate::PendingWork::Cancel).await.unwrap();
		})
		.await;
}

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
			let addr = std::net::SocketAddr::from(([127, 0, 0, 1], server.port().unwrap()));

			let (ready_tx, ready_rx) = oneshot::channel::<()>();
			let host = tokio::task::spawn_local(async move {
				let session = server.accept().await.unwrap();
				let raw = session.shared.ptr.get();
				session
					.publish("svc", move |verb, _args| {
						if verb == "reenter" {
							// A driving verb inside the turn: the latch refuses
							// it, and the error's words become the broken answer.
							let mut vow: u64 = 0;
							let rc = unsafe { ffi::pancake_host_session_fetch(raw, "nested".as_ptr(), 6, &mut vow) };
							if rc == sys::OK {
								return Err("a mid-turn fetch was NOT refused".to_string());
							}
							return Err(format!("mid-turn driving verb refused with rc {rc}"));
						}
						Ok(Argument::String("pong".into()))
					})
					.unwrap();
				ready_tx.send(()).unwrap();
				session.serve().await.unwrap();
			});

			let locator = crate::tcp::locator(&addr.ip().to_string(), addr.port());
			let session = connect(&locator, ConnectOptions::default()).await.unwrap();
			ready_rx.await.unwrap();
			let cap = session.fetch("svc").await.unwrap();
			let broke = session.send(&cap, "reenter", &[]).await.unwrap_err();
			assert!(
				broke.message().unwrap_or("").contains("refused"),
				"the refusal reaches the answer: {broke:?}"
			);
			// The turn unwound cleanly: the same session still answers.
			let pong = session.send(&cap, "ping", &[]).await.unwrap();
			assert_eq!(pong, Argument::String("pong".into()));
			session.close(crate::PendingWork::Cancel).await.unwrap();
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

			// Listen (CapTP `op:listen`): a held capability's resolution comes
			// back through the vow — a listen on an already-settled capability
			// answers at once.
			let settled = session.listen(&cap).await.unwrap();
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
			// A break is PANCAKE_ERR_BROKEN, not a transport or value error.
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
				ffi::pancake_host_session_open_dialed_locator(shared_host.raw(), owned.borrow_view().unwrap(), &mut ptr)
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

// A behavior that drops its own captured `Session` mid-turn requests the
// shared cancel policy without freeing the `Box<ActorCell>` whose behavior
// frame is still on the stack. The core-issued close effect runs after the
// turn, so the send settles before the connection reaches its barrier.
#[tokio::test]
async fn a_behavior_closing_its_own_connection_mid_local_send_parks_the_release() {
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
			let released_in_behavior = Rc::new(Cell::new(false));
			let observed_release = Rc::clone(&released_in_behavior);
			let shared = Rc::clone(&session.shared);
			let observer = Session::view(Rc::clone(&shared));
			// Move the session's only owner into its own behavior so dropping it
			// exercises the last-owner transition inside that callback.
			let captured = Cell::new(Some(session));
			let me = observer
				.spawn(move |verb, _args| {
					if verb == "die" {
						drop(captured.take());
						observed_release.set(shared.released.get());
						return Ok(Argument::Symbol("closing".into()));
					}
					Ok(Argument::Void)
				})
				.unwrap();
			let reply = observer.send(&me, "die", &[]).await.unwrap();
			assert_eq!(reply, Argument::Symbol("closing".into()));
			assert!(
				!released_in_behavior.get(),
				"session released beneath its behavior frame"
			);
			tokio::time::timeout(Duration::from_secs(1), async {
				while !observer.shared.released.get() {
					tokio::task::yield_now().await;
				}
			})
			.await
			.expect("implicit cancel did not reach the session close barrier");
			assert_eq!(crate::host::pending_release_count(), 0);
			let err = observer.send(&me, "die", &[]).await.unwrap_err();
			assert_eq!(err.kind(), crate::ErrorKind::Closed);
			host.await.unwrap();
		})
		.await;
}

// Host close records native intent even when a behavior starts it from inside
// its own callback. The binding schedules only the completion barrier; native
// teardown then closes every sibling session before releasing actor cells.
#[tokio::test]
async fn a_behavior_closing_a_two_session_host_records_native_intent() {
	let local = LocalSet::new();
	local
		.run_until(async {
			let shared_host = Host::new_host();
			let observed_host = shared_host.clone();
			let server = listen_with_host("127.0.0.1:0", shared_host).await.unwrap();
			let addr = std::net::SocketAddr::from(([127, 0, 0, 1], server.port().unwrap()));
			let during = Rc::new(Cell::new(0usize));
			let during_callback = Rc::clone(&during);
			let refused_after_intent = Rc::new(Cell::new(false));
			let refused_in_callback = Rc::clone(&refused_after_intent);
			let (ready_tx, ready_rx) = oneshot::channel::<()>();
			let (closed_tx, closed_rx) = oneshot::channel::<(bool, bool)>();

			let server_task = tokio::task::spawn_local(async move {
				let first = server.accept().await.unwrap();
				let host_to_close = server.host();
				first
					.publish("svc", move |verb, _args| {
						if verb != "close-host" {
							return Err(format!("no such method: {verb}"));
						}
						host_to_close.request_close();
						let refused = host_to_close
							.defer_turn()
							.is_err_and(|error| error.kind() == crate::ErrorKind::Closed);
						refused_in_callback.set(refused);
						during_callback.set(crate::host::pending_release_count());
						Ok(Argument::Symbol("closing".into()))
					})
					.unwrap();
				let second = server.accept().await.unwrap();
				ready_tx.send(()).unwrap();

				first.serve().await.unwrap();
				second.serve().await.unwrap();
				let _ = closed_tx.send((first.shared.released.get(), second.shared.released.get()));
			});

			let first_client = connect(
				&crate::tcp::locator(&addr.ip().to_string(), addr.port()),
				ConnectOptions::default(),
			)
			.await
			.unwrap();
			let second_client = connect(
				&crate::tcp::locator(&addr.ip().to_string(), addr.port()),
				ConnectOptions::default(),
			)
			.await
			.unwrap();
			ready_rx.await.unwrap();

			let svc = first_client.fetch("svc").await.unwrap();
			let _ = first_client.send(&svc, "close-host", &[]).await;
			let released = tokio::time::timeout(std::time::Duration::from_secs(5), closed_rx)
				.await
				.expect("Host close must release both session loops")
				.unwrap();

			assert_eq!(during.get(), 0, "native close intent needs no binding transaction");
			assert!(
				refused_after_intent.get(),
				"close intent must refuse another Host verb before callback unwind"
			);
			assert_eq!(crate::host::pending_release_count(), 0);
			assert_eq!(released, (true, true));
			assert!(observed_host.shared().raw().is_null());

			first_client.close(crate::PendingWork::Cancel).await.unwrap();
			second_client.close(crate::PendingWork::Cancel).await.unwrap();
			server_task.await.unwrap();
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
			let server = listen_with_host("127.0.0.1:0", Host::with_codec(Codec::Capnp).unwrap())
				.await
				.unwrap();
			let addr = std::net::SocketAddr::from(([127, 0, 0, 1], server.port().unwrap()));
			let (ready_tx, ready_rx) = oneshot::channel::<()>();
			let host = tokio::task::spawn_local(async move {
				let session = server.accept().await.unwrap();
				session
					.publish("echo", |_verb, args| Ok(Argument::List(args.to_vec())))
					.unwrap();
				ready_tx.send(()).unwrap();
				session.serve().await.unwrap();
			});

			let session = connect_with_host(
				&crate::tcp::locator(&addr.ip().to_string(), addr.port()),
				Host::with_codec(Codec::Capnp).unwrap(),
			)
			.await
			.unwrap();
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

// A byte stream wrapper that watches inbound bytes for a needle — the
// observer half of the wire-observing scenarios, standing where the old raw
// peer partner scripts stood.
struct Scanning<S> {
	inner: S,
	needle: &'static [u8],
	read_seen: Option<Rc<Cell<bool>>>,
	write_seen: Option<Rc<Cell<bool>>>,
	read_tail: Vec<u8>,
	write_tail: Vec<u8>,
}

impl<S> Scanning<S> {
	fn new(inner: S, needle: &'static [u8], seen: Rc<Cell<bool>>) -> Scanning<S> {
		Scanning {
			inner,
			needle,
			read_seen: Some(seen),
			write_seen: None,
			read_tail: Vec::new(),
			write_tail: Vec::new(),
		}
	}

	fn duplex(inner: S, needle: &'static [u8], read_seen: Rc<Cell<bool>>, write_seen: Rc<Cell<bool>>) -> Scanning<S> {
		Scanning {
			inner,
			needle,
			read_seen: Some(read_seen),
			write_seen: Some(write_seen),
			read_tail: Vec::new(),
			write_tail: Vec::new(),
		}
	}

	fn scan(needle: &[u8], seen: Option<&Rc<Cell<bool>>>, tail: &mut Vec<u8>, fresh: &[u8]) {
		tail.extend_from_slice(fresh);
		if tail.windows(needle.len()).any(|window| window == needle) {
			if let Some(seen) = seen {
				seen.set(true);
			}
		}
		// Keep only enough tail to catch a needle across chunk boundaries.
		let keep = needle.len().saturating_sub(1);
		if tail.len() > keep {
			tail.drain(..tail.len() - keep);
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
			let needle = self.needle;
			let seen = self.read_seen.as_ref().map(Rc::clone);
			Self::scan(needle, seen.as_ref(), &mut self.read_tail, &fresh);
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
		let poll = std::pin::Pin::new(&mut self.inner).poll_write(cx, src);
		if let std::task::Poll::Ready(Ok(written)) = &poll {
			let needle = self.needle;
			let seen = self.write_seen.as_ref().map(Rc::clone);
			Self::scan(needle, seen.as_ref(), &mut self.write_tail, &src[..*written]);
		}
		poll
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

// Distributed GC (ADR-0063), opt-in: every newly projected application
// capability occurrence receives one death rite, whether it came from fetch,
// a nested send reply, or a nested delivered argument. The duplex scanner
// proves both directions on the real wire; keeping the other handles live
// isolates each release rather than accepting a teardown side effect.
async fn serve_gc_tracking(server: tcp::Server) {
	// The public server is intentional: its callbacks run under the native
	// driver loop's Host bracket, so this proves turn->actual-Session recovery
	// rather than only the simpler byte-fed Session bracket.
	let session = server.accept().await.unwrap().with_gc();
	let delegated = session.spawn(|_verb, _args| Ok(Argument::Void)).unwrap();
	let delegated_reply = delegated.clone();
	session
		.publish("factory", move |verb, args| match verb {
			"reply" => Ok(Argument::Struct(vec![(
				"nested".to_string(),
				Argument::List(vec![Argument::Reference(delegated_reply.clone())]),
			)])),
			"accept" => {
				assert!(matches!(
					args,
					[Argument::Struct(entries)]
						if matches!(entries.as_slice(), [(name, Argument::List(items))]
							if name == "nested" && matches!(items.as_slice(), [Argument::Reference(_)]))
				));
				Ok(Argument::Void)
			}
			other => Err(format!("unexpected verb {other}")),
		})
		.unwrap();
	session.serve().await.unwrap();
}

async fn exercise_gc_tracking(
	addr: std::net::SocketAddr,
	client_to_server_gc: Rc<Cell<bool>>,
	server_to_client_gc: Rc<Cell<bool>>,
) {
	let stream = tokio::net::TcpStream::connect(addr).await.unwrap();
	let peer = stream.peer_addr().unwrap();
	let designator = crate::tcp::address_designator(&peer.ip().to_string(), peer.port());
	let stream = Scanning::duplex(
		stream,
		b"op:gc-export",
		Rc::clone(&server_to_client_gc),
		Rc::clone(&client_to_server_gc),
	);
	let captp = Host::new_host();
	let session = Session::establish_dialed_locator(
		captp.shared(),
		&crate::Locator::bare(crate::abi_constants::TRANSPORT_TCP, &designator),
		stream,
		Some(HANDSHAKE_TIMEOUT),
		None,
	)
	.await
	.unwrap()
	.with_gc();
	let factory = session.fetch("factory").await.unwrap();
	let reply = session.send(&factory, "reply", &[]).await.unwrap();
	assert!(matches!(
		&reply,
		Argument::Struct(entries)
			if matches!(entries.as_slice(), [(name, Argument::List(items))]
				if name == "nested" && matches!(items.as_slice(), [Argument::Reference(_)]))
	));
	drop(reply);
	wait_for(&client_to_server_gc, "the nested send reply release").await;

	let callback = session.spawn(|_verb, _args| Ok(Argument::Void)).unwrap();
	let inbound = [Argument::Struct(vec![(
		"nested".to_string(),
		Argument::List(vec![Argument::Reference(callback)]),
	)])];
	assert_eq!(
		session.send(&factory, "accept", &inbound).await.unwrap(),
		Argument::Void
	);
	wait_for(&server_to_client_gc, "the nested delivered argument release").await;

	client_to_server_gc.set(false);
	drop(factory);
	wait_for(&client_to_server_gc, "the fetched capability release").await;
	session.close(crate::PendingWork::Cancel).await.unwrap();
}

#[tokio::test]
async fn gc_tracks_fetch_replies_and_delivered_arguments() {
	let local = LocalSet::new();
	local
		.run_until(Box::pin(async {
			let server = listen("127.0.0.1:0").await.unwrap();
			let addr = std::net::SocketAddr::from(([127, 0, 0, 1], server.port().unwrap()));
			let client_to_server_gc = Rc::new(Cell::new(false));
			let server_to_client_gc = Rc::new(Cell::new(false));
			let host = tokio::task::spawn_local(serve_gc_tracking(server));
			exercise_gc_tracking(addr, client_to_server_gc, server_to_client_gc).await;
			host.await.unwrap();
		}))
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
			let addr = std::net::SocketAddr::from(([127, 0, 0, 1], server.port().unwrap()));
			let (ready_tx, ready_rx) = oneshot::channel::<()>();
			let host = tokio::task::spawn_local(async move {
				let session = server.accept().await.unwrap();
				session.publish("svc", |_verb, _args| Ok(Argument::Void)).unwrap();
				ready_tx.send(()).unwrap();
				let error = session.serve().await.unwrap_err();
				assert_eq!(error.kind(), crate::ErrorKind::Malformed);
				assert_eq!(error.message(), Some("session failed: MalformedFrame"));
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
			let designator = crate::tcp::address_designator(&peer.ip().to_string(), peer.port());
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
			let _cap = session.fetch("svc").await.unwrap();

			// Inject bytes no codec accepts, straight onto the socket.
			use std::io::Write;
			(&dup).write_all(b"this is not a syrup frame").unwrap();

			// The server's refused feed leaves a typed op:abort on its
			// outbound queue and writes it before releasing; it lands here.
			wait_for(&seen, "the typed op:abort from the partner").await;
			session.close(crate::PendingWork::Cancel).await.unwrap();
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
			let addr = std::net::SocketAddr::from(([127, 0, 0, 1], server.port().unwrap()));
			let host = tokio::task::spawn_local(async move {
				let session = server.accept().await.unwrap();
				session.serve().await.unwrap(); // ends when the client tears down
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
			// Bytes no codec accepts, fed straight into this side's pump: the
			// core refuses the frame and projects a typed op:abort.
			let err = crate::pump::feed(&session.shared, b"this is not a syrup frame")
				.await
				.unwrap_err();
			let abort = err.abort().expect("the refusal carries its typed cause");
			assert_eq!(abort.domain, AbortDomain::Codec);
			assert!(
				abort.kind.as_deref().is_some_and(|kind| !kind.is_empty()),
				"the projected abort kind is populated: {abort:?}"
			);
			assert_eq!(abort.abort_delivery_error_name, None);
			assert_eq!(abort.secondary_error_name, None);
			assert_eq!(abort.secondary_error_count, 0);
			session.close(crate::PendingWork::Cancel).await.unwrap();
			captp.close(crate::PendingWork::Cancel).await.unwrap();
			host.await.unwrap();
		})
		.await;
}

// A node whose host allocates through a caller-supplied context routes its
// bytes through that allocator. The Host retains that policy, so dropping the
// public Context before driving the Host is safe and every allocation returns
// when the Host family ends.
#[tokio::test]
async fn drives_a_host_in_a_context_with_a_custom_allocator() {
	use std::sync::Arc;

	struct Counting {
		allocs: Arc<AtomicUsize>,
		frees: Arc<AtomicUsize>,
	}
	impl crate::ContextAllocator for Counting {
		fn alloc(&self, size: usize, alignment: usize) -> *mut u8 {
			self.allocs.fetch_add(1, Ordering::Relaxed);
			let layout = std::alloc::Layout::from_size_align(size, alignment).unwrap();
			unsafe { std::alloc::alloc(layout) }
		}
		unsafe fn free(&self, ptr: *mut u8, size: usize, alignment: usize) {
			self.frees.fetch_add(1, Ordering::Relaxed);
			let layout = std::alloc::Layout::from_size_align(size, alignment).unwrap();
			std::alloc::dealloc(ptr, layout);
		}
	}

	let allocs = Arc::new(AtomicUsize::new(0));
	let frees = Arc::new(AtomicUsize::new(0));
	let ctx = crate::Context::with_allocator(Box::new(Counting {
		allocs: allocs.clone(),
		frees: frees.clone(),
	}))
	.unwrap();
	let captp = Host::new_in(&ctx, Codec::Syrup).unwrap();
	drop(ctx);
	let local = LocalSet::new();
	local
		.run_until(async move {
			let server = listen_with_host("127.0.0.1:0", captp).await.unwrap();
			let addr = std::net::SocketAddr::from(([127, 0, 0, 1], server.port().unwrap()));
			let (ready_tx, ready_rx) = oneshot::channel::<()>();
			let host = tokio::task::spawn_local(async move {
				let session = server.accept().await.unwrap();
				session
					.publish("svc", |_verb, _args| Ok(Argument::Symbol("alive".into())))
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
			let reply = session.send(&cap, "ping", &[]).await.unwrap();
			assert_eq!(reply, Argument::Symbol("alive".into()));
			session.close(crate::PendingWork::Cancel).await.unwrap();
			host.await.unwrap();
		})
		.await;
	// The context-backed host actually serviced the conversation.
	assert!(allocs.load(Ordering::Relaxed) > 0);
	drop(local);
	assert_eq!(allocs.load(Ordering::Relaxed), frees.load(Ordering::Relaxed));
}

// `send_redeeming` is `send` plus one question about the reply, so on an
// ordinary conversation it must answer exactly what `send` does and report no
// exporter. Both reply shapes are covered: a plain value, which names no route
// at all, and a live far capability, which names a route the host holds but not
// a *redeemed* one — the partner published it on this very session, so the reply
// already lives where the caller is standing and there is nothing to hand back.
// Proving the `Some(via)` arm needs a real three-party handoff (a gifter
// introducing a third-party exporter, then a redeem dial), which is what the
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
#[tokio::test]
async fn a_host_retained_view_does_not_close_on_drop() {
	let local = LocalSet::new();
	local
		.run_until(async {
			let server = listen("127.0.0.1:0").await.unwrap();
			let addr = std::net::SocketAddr::from(([127, 0, 0, 1], server.port().unwrap()));

			let (ready_tx, ready_rx) = oneshot::channel::<()>();
			let host = tokio::task::spawn_local(async move {
				let session = server.accept().await.unwrap();
				session
					.publish("svc", |_verb, _args| Ok(Argument::Symbol("alive".into())))
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

			// The Host-retained shape `send_redeeming` hands out for `via`.
			let view = Session::view(Rc::clone(&session.shared));
			let inbox = view.spawn(|_verb, _args| Ok(Argument::Symbol("inbox".into()))).unwrap();
			assert_ne!(inbox.id(), 0);
			assert_eq!(
				view.send(&cap, "ping", &[]).await.unwrap(),
				Argument::Symbol("alive".into())
			);
			drop(view);

			assert!(!session.shared.released.get());
			assert_eq!(
				session.send(&cap, "ping", &[]).await.unwrap(),
				Argument::Symbol("alive".into())
			);

			// The owning handle still closes it.
			session.close(crate::PendingWork::Cancel).await.unwrap();
			assert!(session.shared.released.get());
			host.await.unwrap();
		})
		.await;
}

// One partner that publishes `svc`, serves it, and ends when the client closes.
// Returns its locator and the serving task, so a teardown test can dial several
// distinct partners and watch which connections survive a close.
async fn svc_partner() -> (crate::Locator, oneshot::Receiver<()>, tokio::task::JoinHandle<()>) {
	let server = listen("127.0.0.1:0").await.unwrap();
	let addr = std::net::SocketAddr::from(([127, 0, 0, 1], server.port().unwrap()));
	let (ready_tx, ready_rx) = oneshot::channel::<()>();
	let serving = tokio::task::spawn_local(async move {
		let session = server.accept().await.unwrap();
		session
			.publish("svc", |_verb, _args| Ok(Argument::Symbol("alive".into())))
			.unwrap();
		ready_tx.send(()).unwrap();
		session.serve().await.unwrap();
	});
	(
		crate::tcp::locator(&addr.ip().to_string(), addr.port()),
		ready_rx,
		serving,
	)
}

// Explicit close through a Host-retained view names one exporter connection.
// It must not sweep another redeem or the caller session.
#[tokio::test]
async fn a_view_close_leaves_the_hosts_other_exporters_open() {
	let local = LocalSet::new();
	local
		.run_until(async {
			let (caller_uri, caller_ready, caller_serving) = svc_partner().await;
			let (first_uri, first_ready, first_serving) = svc_partner().await;
			let (second_uri, second_ready, second_serving) = svc_partner().await;

			// One host, three connections: the session the application sends on,
			// and two exporter connections the host dialed to redeem handoffs.
			let host = Host::new_host();
			let caller = connect_with_host(&caller_uri, host.clone()).await.unwrap();
			let first = connect_with_host(&first_uri, host.clone()).await.unwrap();
			let second = connect_with_host(&second_uri, host.clone()).await.unwrap();
			caller_ready.await.unwrap();
			first_ready.await.unwrap();
			second_ready.await.unwrap();

			// The Host-retained shape `send_redeeming` hands back as `via`.
			let via = Session::view(Rc::clone(&first.shared));
			via.close(crate::PendingWork::Cancel).await.unwrap();
			assert!(
				first.shared.released.get(),
				"a view close closes the connection it names"
			);
			assert!(
				!second.shared.released.get(),
				"another redeem's exporter is not this alias's to close"
			);
			assert!(
				!caller.shared.released.get(),
				"nor is the session the application sent on"
			);
			// The untouched exporter is still a working connection.
			let cap = second.fetch("svc").await.unwrap();
			assert_eq!(
				second.send(&cap, "ping", &[]).await.unwrap(),
				Argument::Symbol("alive".into())
			);

			// Closing the session the application sends on closes that session
			// and nothing else. The host was passed in, so it is not this
			// session's to tear down, and a sibling session on it would still
			// be using the exporters its own redeems caused.
			caller.close(crate::PendingWork::Cancel).await.unwrap();
			assert!(caller.shared.released.get());
			assert!(
				!second.shared.released.get(),
				"closing one session does not close a shared host's exporters"
			);

			// Releasing the host is what closes everything it holds.
			host.close(crate::PendingWork::Cancel).await.unwrap();
			assert!(
				second.shared.released.get(),
				"closing the host closes the exporters it dialed"
			);

			caller_serving.await.unwrap();
			first_serving.await.unwrap();
			second_serving.await.unwrap();
		})
		.await;
}

// The dial-side twin of the rude probe: a partner that accepts the connection
// and then says nothing is the case no failure check catches, because nothing
// fails. Unbounded, the dialer parks forever; the bound makes it a typed
// timeout, and the abandoned handshake closes the transport on the way out.
#[tokio::test]
async fn a_silent_partner_times_the_dial_out_rather_than_parking_it() {
	let local = LocalSet::new();
	local
		.run_until(async {
			// Accepts TCP, then holds the socket open past the dial's budget
			// without ever sending an `op:start-session`.
			let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
			let addr = listener.local_addr().unwrap();
			let silent = tokio::task::spawn_local(async move {
				let stream = listener.accept().await.unwrap();
				tokio::time::sleep(std::time::Duration::from_millis(500)).await;
				drop(stream);
			});

			let error = connect_with_runtime_options(
				&crate::tcp::locator(&addr.ip().to_string(), addr.port()),
				RuntimeConfig::providers([crate::tcp::provider(Default::default())])
					.with_handshake_timeout(std::time::Duration::from_millis(100)),
			)
			.await
			.err()
			.expect("a partner that never handshakes must not open a session");
			assert_eq!(error.kind(), crate::ErrorKind::TimedOut);
			silent.await.unwrap();
		})
		.await;
}

// Off-turn settlement: a behavior atomically defers onto a resolver vow
// (`Host::defer_turn`) and returns; the caller's reply arrives only
// when the parked resolver settles later — after real awaited work — as its
// own top-level event. A successful settle consumes the native authority, so
// the broken arm exercises a second call's fresh resolver.
#[tokio::test]
async fn an_async_worker_defers_its_answer_onto_a_resolver_vow() {
	use std::cell::RefCell;
	use std::rc::Rc;

	let local = LocalSet::new();
	local
		.run_until(async {
			let captp = Host::new_host();
			let parked: Rc<RefCell<Option<crate::Resolver>>> = Rc::new(RefCell::new(None));
			let behavior_host = captp.clone();
			let behavior_parked = Rc::clone(&parked);
			captp
				.publish_giftable("worker", move || {
					let host = behavior_host.clone();
					let parked = Rc::clone(&behavior_parked);
					Box::new(move |_verb, _args| {
						let resolver = host.defer_turn().map_err(|e| e.to_string())?;
						*parked.borrow_mut() = Some(resolver);
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

			// The worker's "real work": wait until the behavior parked its
			// resolver, then settle it from the loop, top-level.
			let take_parked = || async {
				loop {
					if let Some(resolver) = parked.borrow_mut().take() {
						break resolver;
					}
					tokio::time::sleep(std::time::Duration::from_millis(5)).await;
				}
			};

			let fulfilled = async {
				let mut resolver = take_parked().await;
				resolver.fulfill(&Argument::String("computed off-turn".into())).unwrap();
			};
			let (reply, ()) = tokio::join!(session.send(&worker, "work", &[]), fulfilled);
			assert_eq!(reply.unwrap(), Argument::String("computed off-turn".into()));

			let broken_arm = async {
				let mut resolver = take_parked().await;
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
				let mut resolver = take_parked().await;
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
// (ADR-0112): the behavior fires inside a `pancake_driver_step`, so
// `defer_turn` must find the turn latched to the loop's adopted Host (the
// step's deliver bracket), and the top-level resolver settle must reach the
// wire through a loop step rather than a byte-fed drain.
#[tokio::test]
async fn a_loop_hosted_worker_defers_its_answer_onto_a_resolver_vow() {
	use std::cell::RefCell;
	use std::rc::Rc;

	let local = LocalSet::new();
	local
		.run_until(async {
			let server = listen("127.0.0.1:0").await.unwrap();
			let addr = std::net::SocketAddr::from(([127, 0, 0, 1], server.port().unwrap()));
			let captp = server.host();
			let parked: Rc<RefCell<Option<crate::Resolver>>> = Rc::new(RefCell::new(None));
			let behavior_host = captp.clone();
			let behavior_parked = Rc::clone(&parked);
			captp
				.publish_giftable("worker", move || {
					let host = behavior_host.clone();
					let parked = Rc::clone(&behavior_parked);
					Box::new(move |_verb, _args| {
						let resolver = host.defer_turn().map_err(|e| e.to_string())?;
						*parked.borrow_mut() = Some(resolver);
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
				let resolver = loop {
					if let Some(resolver) = parked.borrow_mut().take() {
						break resolver;
					}
					tokio::time::sleep(std::time::Duration::from_millis(5)).await;
				};
				let mut resolver = resolver;
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
			// pancake's alone and a consumer must not read an implementation off
			// the fact that a record arrived.
			assert!(
				opened.iter().all(|ev| ev.a_profile == Some("pancake")),
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
