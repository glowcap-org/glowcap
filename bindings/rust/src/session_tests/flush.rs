//! Only a drain which transferred packets owns a transport flush.
use super::support::*;

#[derive(Clone, Copy)]
enum FlushMode {
	Pending,
	Ready,
	Closed,
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
		std::task::Poll::Pending
	}
}

impl AsyncWrite for FlushStream {
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
		match self.mode.get() {
			FlushMode::Pending => std::task::Poll::Pending,
			FlushMode::Ready => std::task::Poll::Ready(Ok(())),
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
