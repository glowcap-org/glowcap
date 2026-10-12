//! Controlled authenticated message channel. The fixture supplies transport
//! proof. It does not claim to exercise browser DTLS or SCTP.
use glowcap::{
	AcceptedTransport, Argument, Channel, ChannelClose, ChannelDesignator, Host, Locator, PacketRead, PacketWrite,
	PendingWork, Session,
};
use std::{
	cell::{Cell, RefCell},
	collections::VecDeque,
	future::Future,
	io,
	pin::Pin,
	rc::Rc,
	task::{Context, Poll, Waker},
	time::Duration,
};
use tokio::sync::oneshot;

#[derive(Default)]
struct Queue {
	packets: RefCell<VecDeque<Vec<u8>>>,
	closed: Cell<bool>,
	wake: RefCell<Option<Waker>>,
}
impl Queue {
	fn close(&self) {
		self.closed.set(true);
		if let Some(wake) = self.wake.borrow_mut().take() {
			wake.wake();
		}
	}
}
struct Reader(Rc<Queue>);
impl PacketRead for Reader {
	fn poll_packet(&mut self, cx: &mut Context<'_>) -> Poll<io::Result<Option<Vec<u8>>>> {
		if let Some(packet) = self.0.packets.borrow_mut().pop_front() {
			return Poll::Ready(Ok(Some(packet)));
		}
		if self.0.closed.get() {
			return Poll::Ready(Ok(None));
		}
		*self.0.wake.borrow_mut() = Some(cx.waker().clone());
		Poll::Pending
	}
}
struct Writer(Rc<Queue>);
impl PacketWrite for Writer {
	fn poll_packet(&mut self, _: &mut Context<'_>, prefix: &[u8], body: &[u8]) -> Poll<io::Result<()>> {
		assert!(prefix.is_empty(), "message transport received byte-stream framing");
		assert!(body.len() <= 16 * 1024);
		if self.0.closed.get() {
			return Poll::Ready(Err(io::ErrorKind::BrokenPipe.into()));
		}
		let mut queue = self.0.packets.borrow_mut();
		if queue.len() == 16 {
			return Poll::Ready(Err(io::Error::other("fixture queue exceeded")));
		}
		queue.push_back(body.to_vec());
		drop(queue);
		if let Some(wake) = self.0.wake.borrow_mut().take() {
			wake.wake();
		}
		Poll::Ready(Ok(()))
	}
	fn poll_flush(&mut self, _: &mut Context<'_>) -> Poll<io::Result<()>> {
		Poll::Ready(Ok(()))
	}
}
struct Close {
	queues: [Rc<Queue>; 2],
	started: Option<oneshot::Sender<()>>,
	permission: oneshot::Receiver<bool>,
}
impl ChannelClose for Close {
	fn poll_close(&mut self, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
		if let Some(started) = self.started.take() {
			for queue in &self.queues {
				queue.close();
			}
			let _ = started.send(());
		}
		match Pin::new(&mut self.permission).poll(cx) {
			Poll::Pending => Poll::Pending,
			Poll::Ready(Ok(true)) => Poll::Ready(Ok(())),
			Poll::Ready(_) => Poll::Ready(Err(io::Error::other("fixture physical close refused"))),
		}
	}
}
struct Barrier {
	started: oneshot::Receiver<()>,
	complete: oneshot::Sender<bool>,
}
fn channel(inbound: Rc<Queue>, outbound: Rc<Queue>) -> (Channel, Barrier) {
	let (started, observed) = oneshot::channel();
	let (complete, permission) = oneshot::channel();
	let close = Close {
		queues: [Rc::clone(&inbound), Rc::clone(&outbound)],
		started: Some(started),
		permission,
	};
	(
		Channel::packets(Reader(inbound), Writer(outbound), close),
		Barrier {
			started: observed,
			complete,
		},
	)
}

pub async fn run() {
	for clean in [true, false] {
		let caller = Host::with_options(Default::default()).unwrap();
		let server = Host::with_options(Default::default()).unwrap();
		let caller_key = caller.designator().unwrap();
		let server_key = server.designator().unwrap();
		server
			.publish("echo", || Box::new(|_, args| Ok(Argument::List(args.to_vec()))))
			.unwrap();
		let first = Rc::new(Queue::default());
		let second = Rc::new(Queue::default());
		let (left, left_close) = channel(Rc::clone(&first), Rc::clone(&second));
		let (right, right_close) = channel(second, first);
		let locator = Locator::bare("webrtc", &server_key);
		let accepted = AcceptedTransport {
			transport: "webrtc",
			designator: ChannelDesignator::Key(&server_key),
			local_address: "",
			verified_channel_key: Some(&caller_key),
		};
		let budget = Some(Duration::from_secs(2));
		let (dialed, accepted) = tokio::join!(
			Session::dial_channel(&caller, &locator, left, budget, Some(&server_key)),
			Session::accept_channel(&server, accepted, right, budget),
		);
		let dialed = dialed.unwrap();
		let accepted = accepted.unwrap();
		let echo = dialed.fetch("echo").await.unwrap();
		for size in [1, 4096, 8192] {
			let payload = vec![Argument::Bytes(vec![0x5a; size])];
			assert_eq!(
				dialed.send(&echo, "roundtrip", &payload).await.unwrap(),
				Argument::List(payload)
			);
		}
		let serving = dialed.borrowed();
		let serve_observer = tokio::task::spawn_local(async move { serving.serve().await });
		let closing_host = caller.clone();
		let observer = tokio::task::spawn_local(async move { closing_host.close(PendingWork::Cancel).await });
		left_close.started.await.unwrap();
		assert!(
			!observer.is_finished(),
			"Host released before physical channel retirement"
		);
		observer.abort();
		assert!(observer.await.unwrap_err().is_cancelled());
		let observing = dialed.borrowed();
		let session_observer = tokio::task::spawn_local(async move { observing.closed().await });
		tokio::task::yield_now().await;
		assert!(
			!session_observer.is_finished(),
			"Session released before physical channel retirement"
		);
		assert!(
			!serve_observer.is_finished(),
			"serve completed before channel retirement"
		);
		left_close.complete.send(clean).unwrap();
		right_close.started.await.unwrap();
		right_close.complete.send(true).unwrap();
		let session_result = session_observer.await.unwrap();
		assert_eq!(session_result.is_ok(), clean);
		assert_eq!(serve_observer.await.unwrap().is_ok(), clean);
		let host_result = caller.close(PendingWork::Cancel).await;
		assert_eq!(host_result.is_ok(), clean);
		if let Err(error) = host_result {
			assert!(error.to_string().contains("fixture physical close refused"));
		}
		drop((echo, dialed, accepted));
		server.close(PendingWork::Cancel).await.unwrap();
	}
	refused_admission_retires_the_channel().await;
}

async fn refused_admission_retires_the_channel() {
	for mode in ["closed-host", "invalid-proof", "silent-partner"] {
		let host = Host::with_options(Default::default()).unwrap();
		let key = host.designator().unwrap();
		if mode == "closed-host" {
			host.close(PendingWork::Cancel).await.unwrap();
		}
		let (wire, barrier) = channel(Rc::new(Queue::default()), Rc::new(Queue::default()));
		let dialing_host = host.clone();
		let admission = tokio::task::spawn_local(async move {
			let locator = Locator::bare("webrtc", &key);
			let proof = if mode == "invalid-proof" { "invalid key" } else { &key };
			Session::dial_channel(
				&dialing_host,
				&locator,
				wire,
				Some(Duration::from_millis(20)),
				Some(proof),
			)
			.await
		});
		barrier.started.await.unwrap();
		assert!(
			!admission.is_finished(),
			"{mode} returned before transferred channel cleanup"
		);
		barrier.complete.send(true).unwrap();
		assert!(admission.await.unwrap().is_err());
		host.close(PendingWork::Cancel).await.unwrap();
	}
}
