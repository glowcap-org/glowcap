//! Transport failure, terminal close, callback barrier, and retained-view scenarios.

use super::support::*;
use tokio::io::AsyncReadExt;

#[tokio::test]
async fn ended_precedes_physical_retirement_without_taking_close_ownership() {
	use std::cell::RefCell;
	use std::task::{Poll, Waker};

	struct HeldClose {
		ready: Rc<Cell<bool>>,
		waker: Rc<RefCell<Option<Waker>>>,
	}
	impl crate::ChannelClose for HeldClose {
		fn poll_close(&mut self, cx: &mut std::task::Context<'_>) -> Poll<std::io::Result<()>> {
			if self.ready.get() {
				Poll::Ready(Ok(()))
			} else {
				*self.waker.borrow_mut() = Some(cx.waker().clone());
				Poll::Pending
			}
		}
	}

	LocalSet::new()
		.run_until(async {
			let host = Host::new_host();
			let shared_host = host.shared();
			let locator = crate::Locator::bare(crate::abi_constants::TRANSPORT_TCP, "127.0.0.1:1");
			let owned = crate::uri::OwnedLocator::new(&locator).unwrap();
			let mut ptr = core::ptr::null_mut();
			crate::host::check_host(unsafe {
				ffi::glowcap_host_session_open_dialed_locator(shared_host.raw(), owned.borrow_view().unwrap(), &mut ptr)
			})
			.unwrap();

			let ready = Rc::new(Cell::new(false));
			let waker = Rc::new(RefCell::new(None));
			let (stream, _peer) = tokio::io::duplex(64);
			let mut channel = crate::Channel::stream(stream);
			channel.close = Some(Box::new(HeldClose {
				ready: Rc::clone(&ready),
				waker: Rc::clone(&waker),
			}));
			let shared = SessionShared::new_channel(ptr, shared_host, channel);
			let session = Session::owning(Rc::clone(&shared));

			shared.close_transport();
			tokio::time::timeout(Duration::from_millis(100), session.ended())
				.await
				.expect("end observation waited for physical retirement")
				.unwrap();
			assert!(!session.is_open());
			assert!(!shared.released.get());
			assert!(
				tokio::time::timeout(Duration::from_millis(20), session.closed())
					.await
					.is_err()
			);

			ready.set(true);
			waker
				.borrow_mut()
				.take()
				.expect("retirement registered its wake")
				.wake();
			tokio::time::timeout(Duration::from_millis(100), session.closed())
				.await
				.expect("physical retirement did not resume")
				.unwrap();
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
				ffi::glowcap_host_session_open_dialed_locator(shared_host.raw(), owned.borrow_view().unwrap(), &mut ptr)
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
				ffi::glowcap_host_session_open_dialed_locator(shared_host.raw(), owned.borrow_view().unwrap(), &mut ptr)
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
							let rc = unsafe { ffi::glowcap_host_session_fetch(raw, "nested".as_ptr(), 6, &mut vow) };
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

// A behavior that drops its own captured `Session` mid-turn requests the
// shared cancel policy without freeing the `Box<ActorCell>` whose behavior
// frame is still on the stack. The cancel takes effect when the turn returns
// (ADR-0114), so the turn's own reply stands and later calls see the close.
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
			// The turn finished before its cancel took effect, so its reply is
			// not an outstanding operation the cancel breaks.
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
			assert_eq!(crate::finalizer::pending_count(), 0);
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
						during_callback.set(crate::finalizer::pending_count());
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
			assert_eq!(crate::finalizer::pending_count(), 0);
			assert_eq!(released, (true, true));
			assert!(observed_host.shared().raw().is_null());

			first_client.close(crate::PendingWork::Cancel).await.unwrap();
			second_client.close(crate::PendingWork::Cancel).await.unwrap();
			server_task.await.unwrap();
		})
		.await;
}

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

#[tokio::test]
async fn a_session_dropped_outside_its_local_set_latches_the_refused_close() {
	// A byte-fed session, so no loop tier stands between the drop and its
	// Host: the refusal below reaches the Host only through the drop's own
	// fallback.
	let local = LocalSet::new();
	let (host, session) = local
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
			let shared = SessionShared::new(
				ptr,
				shared_host,
				super::flush::FlushStream::pending(Rc::new(Cell::new(false))),
			);
			(host, Session::owning(shared))
		})
		.await;

	// A drop has no result channel, and outside its LocalSet it cannot spawn
	// the close driver either. The connection still ends, and the exact
	// refusal waits for the next barrier that can report it.
	drop(session);
	let error = local
		.run_until(host.close(crate::PendingWork::Cancel))
		.await
		.expect_err("the refused close driver was not reported at the Host's close barrier");
	assert!(error.to_string().contains("LocalSet"), "{error}");
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
			// Accepts TCP without sending `op:start-session`, then remains open
			// until the timed-out dialer closes its side.
			let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
			let addr = listener.local_addr().unwrap();
			let silent = tokio::task::spawn_local(async move {
				let (mut stream, _) = listener.accept().await.unwrap();
				let mut bytes = [0_u8; 256];
				while stream.read(&mut bytes).await.unwrap() != 0 {}
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
