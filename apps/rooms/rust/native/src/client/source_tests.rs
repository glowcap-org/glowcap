//! Inline sender files through real direct messages and bounded remote reads.
use super::Deadline;
use glowcap::{tcp, Argument, ConnectOptions, PendingWork, Runtime, RuntimeConfig, Session};
use rooms_application::{
	direct::Notice,
	directory::registration::Id,
	files::{sources as policy, FileDescription, CHUNK_BYTES},
	room::attachment::Attachment,
};
use rooms_glowcap::client::{
	direct::{self, Direct},
	files::File,
	sources::{Reader, Source, Sources},
	Client, Tasks,
};
use std::{cell::Cell, future::Future, pin::Pin, rc::Rc, time::Duration};
#[derive(Clone, Default)]
struct Platform {
	expire_reads: Rc<Cell<bool>>,
}
impl rooms_glowcap::client::Deadline for Platform {
	async fn within<T>(&self, ms: u64, work: impl Future<Output = T>) -> Option<T> {
		if ms == rooms_application::files::transfer::STALL_MS && self.expire_reads.replace(false) {
			return None;
		}
		Deadline.within(ms, work).await
	}
}
impl Tasks for Platform {
	type Task = super::Task;
	fn spawn(&self, work: impl Future<Output = ()> + 'static) -> Self::Task {
		Deadline.spawn(work)
	}
}
struct Probe {
	mode: Rc<Cell<u8>>,
	calls: tokio::sync::mpsc::Sender<(usize, usize)>,
	gate: Rc<tokio::sync::Notify>,
}
impl Reader for Probe {
	fn read(&self, offset: usize, length: usize) -> Pin<Box<dyn Future<Output = Result<Vec<u8>, String>>>> {
		let (mode, calls, gate) = (self.mode.get(), self.calls.clone(), self.gate.clone());
		Box::pin(async move {
			calls.try_send((offset, length)).unwrap();
			if mode == 1 {
				gate.notified().await;
			}
			Ok((offset..offset + length - usize::from(mode == 2))
				.map(|i| (i % 251) as u8)
				.collect())
		})
	}
}
fn description(size: usize) -> FileDescription {
	FileDescription::parse("file", "application/octet-stream", size as u64, 0, 0).unwrap()
}
#[tokio::test]
async fn inline_sources_stream_expire_and_retire_with_their_owner() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(15), scenario())
				.await
				.expect("source scenario deadline");
		})
		.await;
}
async fn scenario() {
	let server = tcp::listen("127.0.0.1", 0, Default::default()).await.unwrap();
	let runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
		.await
		.unwrap();
	let locator = server.locator().unwrap();
	let (caller, peer) = tokio::join!(runtime.connect(&locator, ConnectOptions::default()), server.accept());
	let peer = Rc::new(peer.unwrap().with_gc());
	let service = peer.clone();
	let serving = tokio::task::spawn_local(async move { service.serve().await });
	let platform = Platform::default();
	let client = Client::new(caller.unwrap(), platform.clone());
	let (tx, mut delivered) = tokio::sync::mpsc::channel::<(Session, Vec<Attachment<glowcap::Ref>>)>(8);
	let (defer, mut deferred) = tokio::sync::mpsc::channel(1);
	let root = peer
		.publish(
			"dm",
			direct::receiver(move |notice, session| {
				let Notice::Message { text, attachments, .. } = notice else {
					return Err("messages only".into());
				};
				if text == "cancel" {
					defer.try_send(session.host().defer_turn().unwrap()).unwrap();
				}
				tx.try_send((session, attachments)).unwrap();
				Ok(Argument::Void)
			}),
		)
		.unwrap();
	let direct = Direct::adopt(
		client.clone(),
		client.session().fetch("dm").await.unwrap(),
		Id::parse("11111111-1111-4111-8111-111111111111").unwrap(),
	);
	let owner = Sources::new(platform.clone());
	assert!(Source::bytes(description(1), vec![]).is_err());
	direct
		.send_files(
			"bytes",
			&owner,
			vec![Source::bytes(description(CHUNK_BYTES + 1), vec![7; CHUNK_BYTES + 1]).unwrap()],
		)
		.await
		.unwrap();
	assert_eq!(owner.usage().bytes, CHUNK_BYTES + 1);
	let (session, mut attachments) = delivered.recv().await.unwrap();
	let file = File::new(Client::new(session, Deadline), attachments.pop().unwrap());
	assert_eq!(file.fetch(|_| {}).await.unwrap(), vec![7; CHUNK_BYTES + 1]);
	assert_eq!(owner.usage().bytes, 0);
	assert!(file.read(0, 1).await.is_err());
	assert!(file.read(u64::MAX, 1).await.unwrap().is_empty());
	let mode = Rc::new(Cell::new(0));
	let gate = Rc::new(tokio::sync::Notify::new());
	let (calls, mut reads) = tokio::sync::mpsc::channel(64);
	let source = |size| {
		Source::reader(
			description(size),
			Probe {
				mode: mode.clone(),
				gate: gate.clone(),
				calls: calls.clone(),
			},
		)
	};
	direct
		.send_files("stream", &owner, vec![source(CHUNK_BYTES + 1)])
		.await
		.unwrap();
	let (session, mut attachments) = delivered.recv().await.unwrap();
	let stream = File::new(Client::new(session, Deadline), attachments.pop().unwrap());
	assert_eq!(
		stream.read(CHUNK_BYTES as u64, 1).await.unwrap(),
		vec![(CHUNK_BYTES % 251) as u8]
	);
	assert_eq!(reads.recv().await.unwrap(), (CHUNK_BYTES, 1));
	mode.set(2);
	assert!(stream.read(0, 4).await.is_err());
	assert_eq!(reads.recv().await.unwrap(), (0, 4));
	assert_eq!(owner.usage().files, 1);
	mode.set(0);
	platform.expire_reads.set(true);
	assert!(stream
		.read(0, 4)
		.await
		.err()
		.unwrap()
		.to_string()
		.contains("stopped answering"));
	let bytes = stream.fetch(|_| {}).await.unwrap();
	assert_eq!(bytes, (0..CHUNK_BYTES + 1).map(|i| (i % 251) as u8).collect::<Vec<_>>());
	assert_eq!(reads.recv().await.unwrap(), (0, CHUNK_BYTES));
	assert_eq!(reads.recv().await.unwrap(), (CHUNK_BYTES, 1));
	assert_eq!(owner.usage(), Default::default());
	// A delivery observation cancelled after the peer got its capabilities
	// expires its sources even if the peer later acknowledges the message.
	let mut pending = Box::pin(direct.send_files("cancel", &owner, vec![source(3)]));
	let (session, mut attachments) =
		tokio::select! {v=delivered.recv()=>v.unwrap(),_=&mut pending=>panic!("early delivery")};
	let mut resolve = deferred.recv().await.unwrap();
	drop(pending);
	assert_eq!(owner.usage().bytes, 0);
	let cancelled = File::new(Client::new(session, Deadline), attachments.pop().unwrap());
	assert!(cancelled.read(0, 1).await.is_err());
	resolve.fulfill(&Argument::Void).unwrap();
	// The owner admits only a bounded set of asynchronous reads, and dropping
	// it breaks those answers instead of leaving worker tasks detached.
	direct.send_files("pending", &owner, vec![source(3)]).await.unwrap();
	let (session, mut attachments) = delivered.recv().await.unwrap();
	let pending_file = File::new(Client::new(session, Deadline), attachments.pop().unwrap());
	mode.set(1);
	let mut work: Vec<_> = (0..policy::MAX_READS)
		.map(|_| Box::pin(pending_file.read(0, 1)))
		.collect();
	std::future::poll_fn(|cx| {
		for work in &mut work {
			assert!(work.as_mut().poll(cx).is_pending());
		}
		std::task::Poll::Ready(())
	})
	.await;
	for _ in 0..policy::MAX_READS {
		assert_eq!(reads.recv().await.unwrap(), (0, 1));
	}
	assert_eq!(owner.usage().reads, policy::MAX_READS);
	assert!(pending_file
		.read(0, 1)
		.await
		.err()
		.unwrap()
		.to_string()
		.contains("too many direct file reads"));
	assert!(owner.take_failure().is_none());
	drop(owner);
	for work in work {
		assert!(work.await.is_err());
	}
	assert!(pending_file.read(0, 1).await.is_err());
	// Closing the connection also cancels its read tasks while the source owner
	// remains alive. It must not keep an in-flight lease charged until timeout.
	let owner = Sources::new(platform);
	direct.send_files("disconnect", &owner, vec![source(3)]).await.unwrap();
	let (session, mut attachments) = delivered.recv().await.unwrap();
	let disconnected = File::new(Client::new(session, Deadline), attachments.pop().unwrap());
	let mut reading = Box::pin(disconnected.read(0, 1));
	tokio::select! {v=reads.recv()=>assert_eq!(v,Some((0,1))),_=&mut reading=>panic!("early read")};
	peer.release(root).unwrap();
	client.session().close(PendingWork::Cancel).await.unwrap();
	assert!(reading.await.is_err());
	while owner.usage().reads != 0 {
		tokio::task::yield_now().await;
	}
	assert!(owner.take_failure().is_none());
	drop(owner);
	drop((disconnected, file, stream, cancelled, pending_file, direct, client));
	peer.close(PendingWork::Cancel).await.unwrap();
	runtime.close(PendingWork::Cancel).await.unwrap();
	server.close().await.unwrap();
	server.host().close(PendingWork::Cancel).await.unwrap();
	serving.await.unwrap().unwrap();
}
