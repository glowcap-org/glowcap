//! Only a drain which transferred packets owns a transport flush.
use super::support::*;

#[derive(Clone, Copy)]
enum FlushMode {
	Pending,
	Ready,
	Closed,
	PanicRead,
	PanicWrite,
	PanicFlush,
}

pub(super) struct FlushStream {
	flush_polled: Rc<Cell<bool>>,
	mode: Rc<Cell<FlushMode>>,
}

impl FlushStream {
	pub(super) fn pending(flush_polled: Rc<Cell<bool>>) -> Self {
		Self {
			flush_polled,
			mode: Rc::new(Cell::new(FlushMode::Pending)),
		}
	}
}

impl AsyncRead for FlushStream {
	fn poll_read(
		self: std::pin::Pin<&mut Self>,
		_cx: &mut std::task::Context<'_>,
		_buf: &mut tokio::io::ReadBuf<'_>,
	) -> std::task::Poll<std::io::Result<()>> {
		assert!(!matches!(self.mode.get(), FlushMode::PanicRead), "injected read panic");
		std::task::Poll::Pending
	}
}

impl AsyncWrite for FlushStream {
	fn poll_write(
		self: std::pin::Pin<&mut Self>,
		_cx: &mut std::task::Context<'_>,
		src: &[u8],
	) -> std::task::Poll<std::io::Result<usize>> {
		assert!(
			!matches!(self.mode.get(), FlushMode::PanicWrite),
			"injected write panic"
		);
		std::task::Poll::Ready(Ok(src.len()))
	}

	fn poll_flush(
		self: std::pin::Pin<&mut Self>,
		_cx: &mut std::task::Context<'_>,
	) -> std::task::Poll<std::io::Result<()>> {
		self.flush_polled.set(true);
		match self.mode.get() {
			FlushMode::Pending => std::task::Poll::Pending,
			FlushMode::Ready | FlushMode::PanicRead | FlushMode::PanicWrite => std::task::Poll::Ready(Ok(())),
			FlushMode::PanicFlush => panic!("injected flush panic"),
			FlushMode::Closed => std::task::Poll::Ready(Err(std::io::Error::new(
				std::io::ErrorKind::BrokenPipe,
				"transport closed",
			))),
		}
	}

	fn poll_shutdown(
		self: std::pin::Pin<&mut Self>,
		_cx: &mut std::task::Context<'_>,
	) -> std::task::Poll<std::io::Result<()>> {
		std::task::Poll::Ready(Ok(()))
	}
}

#[tokio::test]
async fn finishing_preserves_a_new_sealed_channel_failure() {
	LocalSet::new()
		.run_until(async {
			let host = Host::new_host();
			let remote = Host::new_host();
			host.shared()
				.set_advertised_locator(&crate::Locator::bare(
					crate::TRANSPORT_NOISE_TCP,
					&host.designator().unwrap(),
				))
				.unwrap();
			let locator = crate::Locator::bare(crate::TRANSPORT_NOISE_TCP, &remote.designator().unwrap());
			let owned = crate::uri::OwnedLocator::new(&locator).unwrap();
			let mut ptr = core::ptr::null_mut();
			// SAFETY: the Host, owned locator and out slot stay live through the call.
			// SessionShared takes ownership of the returned session below.
			crate::host::check_host(unsafe {
				ffi::glowcap_host_session_open_dialed_locator(
					host.shared().raw(),
					owned.borrow_view().unwrap(),
					&mut ptr,
				)
			})
			.unwrap();
			let shared = SessionShared::new(
				ptr,
				host.shared(),
				FlushStream {
					flush_polled: Rc::new(Cell::new(false)),
					mode: Rc::new(Cell::new(FlushMode::Ready)),
				},
			);
			crate::pump::flush_outbound(&shared).await.unwrap();
			let session = Session::owning(Rc::clone(&shared));
			let closing = session.close(crate::PendingWork::Finish { grace: None });
			tokio::pin!(closing);
			std::future::poll_fn(|cx| {
				assert!(std::future::Future::poll(closing.as_mut(), cx).is_pending());
				std::task::Poll::Ready(())
			})
			.await;
			// An all-zero responder handshake has an invalid identity element.
			let refusal = crate::pump::feed(&shared, &[0; 144]).await.unwrap_err();
			assert_eq!(refusal.code(), sys::ERR_CLOSED);
			assert!(refusal.to_string().contains("IdentityElement"));
			assert_eq!(closing.await.unwrap_err(), refusal);
			assert_eq!(session.closed().await.unwrap_err(), refusal);
			host.close(crate::PendingWork::Cancel).await.unwrap();
			remote.close(crate::PendingWork::Cancel).await.unwrap();
		})
		.await;
}

#[tokio::test]
async fn local_cancellation_does_not_become_a_wire_failure() {
	LocalSet::new()
		.run_until(async {
			for resume in [false, true] {
				let host = Host::new_host();
				let locator = crate::Locator::bare(crate::abi_constants::TRANSPORT_TCP, "127.0.0.1:1");
				let owned = crate::uri::OwnedLocator::new(&locator).unwrap();
				let mut ptr = core::ptr::null_mut();
				// SAFETY: the Host, owned locator and out slot stay live through the call.
				// SessionShared takes ownership of the returned session below.
				crate::host::check_host(unsafe {
					ffi::glowcap_host_session_open_dialed_locator(
						host.shared().raw(),
						owned.borrow_view().unwrap(),
						&mut ptr,
					)
				})
				.unwrap();
				let shared = SessionShared::new(
					ptr,
					host.shared(),
					FlushStream {
						flush_polled: Rc::new(Cell::new(false)),
						mode: Rc::new(Cell::new(FlushMode::Ready)),
					},
				);
				let session = Session::owning(Rc::clone(&shared));
				let closing = session.close(crate::PendingWork::Cancel);
				tokio::pin!(closing);
				// Admit cancellation before the reader runs, without polling the
				// spawned close driver or writer until the pump observes it.
				std::future::poll_fn(|cx| {
					assert!(std::future::Future::poll(closing.as_mut(), cx).is_pending());
					std::task::Poll::Ready(())
				})
				.await;
				let pumping = async {
					if resume {
						crate::pump::serve_loop(Rc::clone(&shared)).await
					} else {
						crate::pump::feed(&shared, b"late bytes").await
					}
				};
				tokio::time::timeout(Duration::from_secs(1), pumping)
					.await
					.unwrap()
					.unwrap();
				closing.await.unwrap();
				session.closed().await.unwrap();
				host.close(crate::PendingWork::Cancel).await.unwrap();
			}
		})
		.await;
}

#[tokio::test]
async fn refused_feed_precedes_abort_delivery_failure() {
	LocalSet::new()
		.run_until(async {
			for (chunk, code) in [
				(b"this is not a frame".as_slice(), sys::ERR_CODEC),
				(b"2000000:".as_slice(), sys::ERR_FRAME_TOO_LARGE),
			] {
				let host = Host::new_host();
				let locator = crate::Locator::bare(crate::abi_constants::TRANSPORT_TCP, "127.0.0.1:1");
				let owned = crate::uri::OwnedLocator::new(&locator).unwrap();
				let mut ptr = core::ptr::null_mut();
				// SAFETY: the Host, owned locator and out slot stay live through the call.
				// SessionShared takes ownership of the returned session below.
				crate::host::check_host(unsafe {
					ffi::glowcap_host_session_open_dialed_locator(
						host.shared().raw(),
						owned.borrow_view().unwrap(),
						&mut ptr,
					)
				})
				.unwrap();
				let mode = Rc::new(Cell::new(FlushMode::Ready));
				let shared = SessionShared::new(
					ptr,
					host.shared(),
					FlushStream {
						flush_polled: Rc::new(Cell::new(false)),
						mode: Rc::clone(&mode),
					},
				);
				// The hello succeeds. Only the refusal's final flush fails.
				crate::pump::flush_outbound(&shared).await.unwrap();
				mode.set(FlushMode::Closed);
				let refusal =
					tokio::time::timeout(std::time::Duration::from_secs(1), crate::pump::feed(&shared, chunk))
						.await
						.expect("refused feed must retire")
						.unwrap_err();
				assert_eq!(refusal.code(), code);
				if code == sys::ERR_CODEC {
					assert_eq!(refusal.abort().unwrap().error_name, "MalformedFrame");
				}
				for _ in 0..2 {
					assert_eq!(
						shared.terminal_result().unwrap_err(),
						refusal,
						"terminal observers lost the feed refusal"
					);
				}
				assert_eq!(refusal.secondary_error_count(), 1);
				assert!(refusal.secondary_errors()[0].to_string().contains("transport closed"));
				host.close(crate::PendingWork::Cancel).await.unwrap();
			}
		})
		.await;
}

#[tokio::test]
async fn transport_panics_retire_the_session_and_wake_observers() {
	LocalSet::new()
		.run_until(async {
			for (mode, detail) in [
				(FlushMode::PanicRead, "injected read panic"),
				(FlushMode::PanicWrite, "injected write panic"),
				(FlushMode::PanicFlush, "injected flush panic"),
			] {
				let host = Host::new_host();
				let locator = crate::Locator::bare(crate::abi_constants::TRANSPORT_TCP, "127.0.0.1:1");
				let owned = crate::uri::OwnedLocator::new(&locator).unwrap();
				let mut ptr = core::ptr::null_mut();
				// SAFETY: the Host and owned locator stay live through the call. The returned
				// session handle transfers to SessionShared below.
				crate::host::check_host(unsafe {
					ffi::glowcap_host_session_open_dialed_locator(
						host.shared().raw(),
						owned.borrow_view().unwrap(),
						&mut ptr,
					)
				})
				.unwrap();
				let shared = SessionShared::new(
					ptr,
					host.shared(),
					FlushStream {
						flush_polled: Rc::new(Cell::new(false)),
						mode: Rc::new(Cell::new(mode)),
					},
				);
				if matches!(mode, FlushMode::PanicRead) {
					shared.spawn_serve();
					let serving = shared.take_serving().unwrap();
					let _ = tokio::time::timeout(std::time::Duration::from_secs(1), serving)
						.await
						.expect("a panicking reader must wake its observers")
						.expect("a transport panic must become a Session failure");
				} else {
					let covering = crate::pump::writer::request_flush(&shared).unwrap();
					let _ = tokio::time::timeout(
						std::time::Duration::from_secs(1),
						crate::pump::writer::written(&shared, covering),
					)
					.await
					.expect("a panicking writer must wake its observers");
				}
				assert!(shared.released.get(), "a panicking transport left its session live");
				let failure = shared.terminal_result().unwrap_err();
				assert!(
					failure.to_string().contains(detail),
					"transport panic lost its cause: {failure}"
				);
				assert_eq!(shared.terminal_result().unwrap_err().to_string(), failure.to_string());
				host.close(crate::PendingWork::Cancel).await.unwrap();
			}
		})
		.await;
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
			// SAFETY: `shared_host.raw()` is the `GlowcapHost` handle of the `Host` this test holds, live until the
			// test ends; `owned.borrow_view()` is a view into the `OwnedLocator` local, which outlives the call, and
			// `ptr` is a local out-parameter the callee fills with a host-owned session handle that
			// `SessionShared::new` takes over below.
			crate::host::check_host(unsafe {
				ffi::glowcap_host_session_open_dialed_locator(shared_host.raw(), owned.borrow_view().unwrap(), &mut ptr)
			})
			.unwrap();

			let flush_polled = Rc::new(Cell::new(false));
			let shared = SessionShared::new(ptr, shared_host, FlushStream::pending(Rc::clone(&flush_polled)));
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
			// SAFETY: as `cancelling_during_transport_flush_tears_the_stream` above, for the `Host` and `OwnedLocator`
			// locals of this test.
			crate::host::check_host(unsafe {
				ffi::glowcap_host_session_open_dialed_locator(shared_host.raw(), owned.borrow_view().unwrap(), &mut ptr)
			})
			.unwrap();

			let flush_polled = Rc::new(Cell::new(false));
			let shared = SessionShared::new(ptr, shared_host, FlushStream::pending(Rc::clone(&flush_polled)));
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
async fn an_empty_drain_does_not_flush_a_retired_transport() {
	LocalSet::new()
		.run_until(async {
			let host = Host::new_host();
			let shared_host = host.shared();
			let locator = crate::Locator::bare(crate::abi_constants::TRANSPORT_TCP, "127.0.0.1:1");
			let owned = crate::uri::OwnedLocator::new(&locator).unwrap();
			let mut ptr = core::ptr::null_mut();
			// SAFETY: as `cancelling_during_transport_flush_tears_the_stream` above, for the `Host` and `OwnedLocator`
			// locals of this test.
			crate::host::check_host(unsafe {
				ffi::glowcap_host_session_open_dialed_locator(shared_host.raw(), owned.borrow_view().unwrap(), &mut ptr)
			})
			.unwrap();
			let flush_polled = Rc::new(Cell::new(false));
			let mode = Rc::new(Cell::new(FlushMode::Ready));
			let shared = SessionShared::new(
				ptr,
				shared_host,
				FlushStream {
					flush_polled: flush_polled.clone(),
					mode: mode.clone(),
				},
			);
			crate::pump::flush_outbound(&shared).await.unwrap();
			assert!(flush_polled.replace(false), "the initial handshake packet must flush");
			mode.set(FlushMode::Closed);
			let result = crate::pump::flush_outbound(&shared).await;
			assert!(
				result.is_ok(),
				"an empty drain must not manufacture a wire failure: {result:?}"
			);
			assert!(!flush_polled.get(), "no transferred frame owns this flush");
			assert!(!shared.torn.get());
			shared.close_transport();
			host.close(crate::PendingWork::Cancel).await.unwrap();
		})
		.await;
}

#[tokio::test]
async fn cancelled_opening_retires_both_handshake_roles() {
	LocalSet::new()
		.run_until(async {
			for (accepted, cancel_observer) in [(false, false), (false, true), (true, false), (true, true)] {
				let host = Host::new_host();
				let polled = Rc::new(Cell::new(false));
				let channel = crate::Channel::stream(FlushStream::pending(polled.clone()));
				let locator = crate::Locator::bare(crate::abi_constants::TRANSPORT_TCP, "127.0.0.1:1");
				let mut opening = Box::pin(async {
					if accepted {
						Session::accept_channel(
							&host,
							crate::session::AcceptedTransport {
								transport: crate::abi_constants::TRANSPORT_TCP,
								designator: crate::session::ChannelDesignator::Address("127.0.0.1:1"),
								local_address: "127.0.0.1:1",
								verified_channel_key: None,
							},
							channel,
							None,
						)
						.await
					} else {
						Session::dial_channel(&host, &locator, channel, None, None).await
					}
				});
				std::future::poll_fn(|cx| {
					assert!(std::future::Future::poll(opening.as_mut(), cx).is_pending());
					std::task::Poll::Ready(())
				})
				.await;
				let retire = async {
					if cancel_observer {
						drop(opening);
						host.close(crate::PendingWork::Cancel).await.unwrap();
					} else {
						let (opened, closed) = tokio::join!(opening, host.close(crate::PendingWork::Cancel));
						assert!(opened.is_err(), "a closing Host admitted a handshake");
						closed.unwrap();
					}
				};
				tokio::time::timeout(std::time::Duration::from_secs(1), retire)
					.await
					.expect("cancelled handshake kept the Host alive");
			}
		})
		.await;
}

#[tokio::test]
async fn failed_handshake_does_not_poison_a_later_connection() {
	LocalSet::new()
		.run_until(async {
			let host = Host::new_host();
			let mut failed = crate::Channel::stream(FlushStream {
				flush_polled: Rc::new(Cell::new(false)),
				mode: Rc::new(Cell::new(FlushMode::Closed)),
			});
			struct RefusedClose;
			impl crate::ChannelClose for RefusedClose {
				fn poll_close(&mut self, _: &mut std::task::Context<'_>) -> std::task::Poll<std::io::Result<()>> {
					std::task::Poll::Ready(Err(std::io::Error::other("physical close failed")))
				}
			}
			failed.close = Some(Box::new(RefusedClose));
			let absent = crate::Locator::bare(crate::TRANSPORT_TCP, "127.0.0.1:1");
			assert!(
				Session::dial_channel(&host, &absent, failed, Some(Duration::from_secs(1)), None)
					.await
					.is_err()
			);
			let server = listen("127.0.0.1:0").await.unwrap();
			let locator = tcp::locator("127.0.0.1", server.port().unwrap());
			let serving = tokio::task::spawn_local(async move {
				let session = server.accept().await.unwrap();
				session.publish("alive", |_, _| Ok("yes".into())).unwrap();
				session.serve().await.unwrap();
			});
			let stream = tokio::net::TcpStream::connect(&locator.designator).await.unwrap();
			let next = Session::dial_channel(
				&host,
				&locator,
				crate::Channel::stream(stream),
				Some(Duration::from_secs(1)),
				None,
			)
			.await
			.unwrap();
			let target = next.fetch("alive").await.unwrap();
			assert!(next.send(&target, "check", &[]).await.is_ok());
			next.close(crate::PendingWork::Cancel).await.unwrap();
			assert!(
				host.close(crate::PendingWork::Cancel)
					.await
					.unwrap_err()
					.to_string()
					.contains("physical close failed")
			);
			serving.await.unwrap();
		})
		.await;
}

/// A session's writes must never stop its reads. Over a pipe smaller than one
/// frame, a peer that waited on its own write before reading again would
/// leave both sides waiting for the other to read, from the handshake on.
/// Concurrent echoes of frames many times the pipe's size keep both
/// directions full at once.
#[tokio::test]
async fn a_pipe_smaller_than_a_frame_carries_both_directions_at_once() {
	LocalSet::new()
		.run_until(async {
			let exporter = Host::from_seed([71; 32]).unwrap();
			let dialer = Host::from_seed([72; 32]).unwrap();
			let locator = crate::Locator::bare(crate::abi_constants::TRANSPORT_TCP, "127.0.0.1:9011");
			exporter.set_advertised_locator(&locator).unwrap();
			exporter
				.publish("echo", || Box::new(|_verb, args| Ok(args[0].clone())))
				.unwrap();
			let (left, right) = tokio::io::duplex(64);
			let budget = Some(std::time::Duration::from_secs(5));
			let traffic = async {
				let (dialed, accepted) = tokio::join!(
					crate::Session::dial_over(&dialer, &locator, left, budget),
					crate::Session::accept_over(&exporter, "tcp", "127.0.0.1:9011", "127.0.0.1:9011", right, budget)
				);
				let (dialed, _accepted) = (dialed.unwrap(), accepted.unwrap());
				let echo = dialed.fetch("echo").await.unwrap();
				let call = |index: u8| {
					let payload = Argument::Bytes(vec![index; 4096]);
					let (dialed, echo) = (&dialed, &echo);
					async move {
						let reply = dialed.send(echo, "echo", std::slice::from_ref(&payload)).await.unwrap();
						assert_eq!(reply, payload);
					}
				};
				tokio::join!(call(0), call(1), call(2), call(3));
			};
			tokio::time::timeout(std::time::Duration::from_secs(10), traffic)
				.await
				.expect("both peers kept reading while their writes waited");
			exporter.close(crate::PendingWork::Cancel).await.unwrap();
			dialer.close(crate::PendingWork::Cancel).await.unwrap();
		})
		.await;
}
