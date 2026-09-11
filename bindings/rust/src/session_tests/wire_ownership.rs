//! Wire observation, distributed GC, refused-feed, and allocator scenarios.

use super::support::*;

// A byte stream wrapper that watches inbound bytes for a needle — the
// observer half of the wire-observing scenarios, standing where the old raw
// peer partner scripts stood.
struct Scanning<S> {
	inner: S,
	needle: &'static [u8],
	read_seen: Option<Rc<WireSignal>>,
	write_seen: Option<Rc<WireSignal>>,
	read_tail: Vec<u8>,
	write_tail: Vec<u8>,
}

struct WireSignal {
	count: Cell<usize>,
	changed: tokio::sync::Notify,
}

impl WireSignal {
	fn new() -> Self {
		Self {
			count: Cell::new(0),
			changed: tokio::sync::Notify::new(),
		}
	}

	fn observe(&self, count: usize) {
		self.count.set(self.count.get() + count);
		self.changed.notify_one();
	}
}

impl<S> Scanning<S> {
	fn new(inner: S, needle: &'static [u8], seen: Rc<WireSignal>) -> Scanning<S> {
		Scanning {
			inner,
			needle,
			read_seen: Some(seen),
			write_seen: None,
			read_tail: Vec::new(),
			write_tail: Vec::new(),
		}
	}

	fn duplex(inner: S, needle: &'static [u8], read_seen: Rc<WireSignal>, write_seen: Rc<WireSignal>) -> Scanning<S> {
		Scanning {
			inner,
			needle,
			read_seen: Some(read_seen),
			write_seen: Some(write_seen),
			read_tail: Vec::new(),
			write_tail: Vec::new(),
		}
	}

	fn scan(needle: &[u8], seen: Option<&Rc<WireSignal>>, tail: &mut Vec<u8>, fresh: &[u8]) {
		tail.extend_from_slice(fresh);
		let matches = tail.windows(needle.len()).filter(|window| *window == needle).count();
		if matches != 0 {
			if let Some(seen) = seen {
				seen.observe(matches);
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

async fn wait_for(signal: &WireSignal, expected: usize, what: &str) {
	let observed = async {
		loop {
			let changed = signal.changed.notified();
			if signal.count.get() >= expected {
				return;
			}
			changed.await;
		}
	};
	tokio::time::timeout(std::time::Duration::from_secs(10), observed)
		.await
		.unwrap_or_else(|_| panic!("timed out waiting for {what}"));
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
	client_to_server_gc: Rc<WireSignal>,
	server_to_client_gc: Rc<WireSignal>,
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
	wait_for(&client_to_server_gc, 1, "the nested send reply release").await;

	let callback = session.spawn(|_verb, _args| Ok(Argument::Void)).unwrap();
	let inbound = [Argument::Struct(vec![(
		"nested".to_string(),
		Argument::List(vec![Argument::Reference(callback)]),
	)])];
	assert_eq!(
		session.send(&factory, "accept", &inbound).await.unwrap(),
		Argument::Void
	);
	wait_for(&server_to_client_gc, 1, "the nested delivered argument release").await;

	drop(factory);
	wait_for(&client_to_server_gc, 2, "the fetched capability release").await;
	session.close(crate::PendingWork::Cancel).await.unwrap();
}

#[tokio::test]
async fn gc_tracks_fetch_replies_and_delivered_arguments() {
	let local = LocalSet::new();
	local
		.run_until(Box::pin(async {
			let server = listen("127.0.0.1:0").await.unwrap();
			let addr = std::net::SocketAddr::from(([127, 0, 0, 1], server.port().unwrap()));
			let client_to_server_gc = Rc::new(WireSignal::new());
			let server_to_client_gc = Rc::new(WireSignal::new());
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
			let seen = Rc::new(WireSignal::new());
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
			wait_for(&seen, 1, "the typed op:abort from the partner").await;
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
	use crate::HostOptions;
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
	let captp = Host::new_in(
		&ctx,
		HostOptions {
			codec: Codec::Syrup,
			..HostOptions::default()
		},
	)
	.unwrap();
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
