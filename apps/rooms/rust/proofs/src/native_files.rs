//! Loopback integration fixtures, not a second Rooms server. Application
//! methods run through real Host calls. Publication and the pending-work queue
//! are controlled here to exercise exact outcomes and pending-work lifetimes.
use glowcap::{Argument, ConnectOptions, Host, PendingWork, Resolver, Runtime, RuntimeConfig, Session, tcp};
use rooms_application::{
	files::{FileDescription, FileMember, FileRoom, FileStore, ReadOutcome, ReadTicket},
	room::{attachment, message::LineId},
};
use rooms_glowcap::values;
use std::{cell::RefCell, future::poll_fn, rc::Rc, time::Duration};
use tokio::{sync::mpsc, task::LocalSet};

type Store = Rc<RefCell<FileStore>>;
type Waiting = (Resolver, ReadTicket);

struct Fixture {
	store: Store,
	rooms: Vec<FileRoom>,
	_members: Vec<FileMember>,
	waiting: mpsc::Receiver<Waiting>,
}

impl Fixture {
	fn new(host: &Host) -> Self {
		let store = Rc::new(RefCell::new(FileStore::default()));
		let (tx, waiting) = mpsc::channel(256);
		let mut rooms = Vec::new();
		let mut members = Vec::new();
		for name in ["a", "b"] {
			let room = store.borrow_mut().room().unwrap();
			let member = store.borrow_mut().member(&room).unwrap();
			let upload = store
				.borrow_mut()
				.attach(&member, FileDescription::parse(name, "text/plain", 4, 0, 0).unwrap())
				.unwrap();
			let mut files = store.borrow_mut().post(&member).unwrap();
			let blob = files[0].blob();
			let line = Rc::new(RefCell::new(
				store
					.borrow()
					.line(&room, LineId::new(1).unwrap(), "author".into(), &mut files)
					.unwrap(),
			));
			let file_store = store.clone();
			host.publish(&format!("upload-{name}"), move || {
				let (store, upload) = (file_store.clone(), upload.clone());
				Box::new(move |verb, args| {
					store
						.borrow_mut()
						.upload_call(&upload, verb, &values(args).collect::<Vec<_>>())
						.map_err(|e| e.to_string())?;
					Ok(Argument::Void)
				})
			})
			.unwrap();
			let (file_store, behavior_host, tx) = (store.clone(), host.clone(), tx.clone());
			host.publish(&format!("blob-{name}"), move || {
				let (store, host, blob, tx) = (file_store.clone(), behavior_host.clone(), blob.clone(), tx.clone());
				Box::new(move |verb, args| {
					match store
						.borrow_mut()
						.blob_call(&blob, verb, &values(args).collect::<Vec<_>>())
						.map_err(|e| e.to_string())?
					{
						// The current binding accepts owned reply bytes. This explicit
						// copy is an adapter cost, not a zero-copy wire claim.
						ReadOutcome::Ready(bytes) => Ok(Argument::Bytes(bytes.to_vec())),
						ReadOutcome::Waiting(ticket) => {
							let resolver = host.defer_turn().map_err(|e| e.to_string())?;
							tx.try_send((resolver, ticket)).map_err(|e| e.to_string())?;
							Ok(Argument::Void)
						}
					}
				})
			})
			.unwrap();
			let file_store = store.clone();
			host.publish(&format!("line-{name}"), move || {
				let (store, line) = (file_store.clone(), line.clone());
				Box::new(move |verb, args| {
					let args = values(args).collect::<Vec<_>>();
					let mut line = line.borrow_mut();
					let mut store = store.borrow_mut();
					let change = store
						.dispatch_line(None, &mut line, verb, &args)
						.map_err(|e| e.to_string())?;
					// This fixture observes the mutation tag; full subscriber/history
					// effects belong to the production room owner still being ported.
					Ok(change.map_or(Argument::Void, |c| c.kind.wire_tag().into()))
				})
			})
			.unwrap();
			rooms.push(room);
			members.push(member);
		}
		Self {
			store,
			rooms,
			_members: members,
			waiting,
		}
	}
}

async fn pair(server: &tcp::Server, runtime: &Runtime) -> (Session, Session) {
	let locator = server.locator().unwrap();
	let (client, accepted) = tokio::join!(runtime.connect(&locator, ConnectOptions::default()), server.accept());
	(client.unwrap(), accepted.unwrap())
}

async fn settle(store: &Store, (mut resolver, ticket): Waiting) {
	let result = poll_fn(|cx| store.borrow().poll_read(&ticket, cx).map(|r| r.map(<[u8]>::to_vec))).await;
	match result {
		Ok(bytes) => resolver.fulfill(&Argument::Bytes(bytes)).unwrap(),
		Err(error) => resolver.break_with(&error.to_string()).unwrap(),
	}
}

#[tokio::test(flavor = "current_thread")]
async fn files_cross_real_host_sessions_and_retire_together() {
	LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(10), scenario())
				.await
				.expect("file protocol progress");
		})
		.await;
}

async fn scenario() {
	let host = Host::with_options(Default::default()).unwrap();
	let mut fixture = Fixture::new(&host);
	let server = tcp::listen(
		"127.0.0.1",
		0,
		tcp::ListenOptions {
			identity: glowcap::ListenerIdentity::Host(host.clone()),
			..Default::default()
		},
	)
	.await
	.unwrap();
	let runtime_a = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
		.await
		.unwrap();
	let runtime_b = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
		.await
		.unwrap();
	let (a, accepted_a) = pair(&server, &runtime_a).await;
	let (b, accepted_b) = pair(&server, &runtime_b).await;
	let offered_blob = accepted_a.published_ref("blob-a").unwrap().unwrap();
	accepted_a
		.publish("attachment", move |_, _| {
			Ok(Argument::List(vec![
				"file".into(),
				"a".into(),
				"text/plain".into(),
				4.into(),
				Argument::Reference(offered_blob.clone()),
				0.into(),
				0.into(),
			]))
		})
		.unwrap();
	let serving_a = tokio::task::spawn_local(async move { accepted_a.serve().await });
	let serving_b = tokio::task::spawn_local(async move { accepted_b.serve().await });
	let upload_a = a.fetch("upload-a").await.unwrap();
	let upload_b = b.fetch("upload-b").await.unwrap();
	let blob_a_other_connection = b.fetch("blob-a").await.unwrap();
	let blob_b = b.fetch("blob-b").await.unwrap();
	let line_a = b.fetch("line-a").await.unwrap();
	let attachment = a.fetch("attachment").await.unwrap();
	let reply = a.send(&attachment, "fixture", &[]).await.unwrap();
	let files = attachment::read_exact(&values(reply.as_list().unwrap()).collect::<Vec<_>>(), 0).unwrap();
	drop(reply); // The admitted Ref, including its real GC guard, survives.
	let blob_a = &files[0].blob;
	let read_args = [0.into(), 4.into()];
	let read = a.send(blob_a, "read", &read_args);
	let write = async {
		let waiting = fixture.waiting.recv().await.unwrap();
		let chunk = [Argument::Bytes(b"ab".to_vec())];
		let ((), write) = tokio::join!(settle(&fixture.store, waiting), a.send(&upload_a, "write", &chunk));
		write.unwrap();
	};
	let (reply, ()) = tokio::join!(read, write);
	assert_eq!(reply.unwrap().as_bytes(), Some(b"ab".as_slice()));
	assert_eq!(
		b.send(&blob_a_other_connection, "read", &read_args)
			.await
			.unwrap()
			.as_bytes(),
		Some(b"ab".as_slice())
	);
	// A wire capability nested in a structured argument must refuse the write.
	let nested = Argument::Struct(vec![(
		"nested".into(),
		Argument::Set(vec![Argument::Reference(blob_a.clone())]),
	)]);
	let error = a.send(&upload_a, "write", &[nested]).await.unwrap_err();
	assert!(error.to_string().contains("do not take capability arguments"));
	b.send(&upload_b, "write", &[Argument::Bytes(b"room".to_vec())])
		.await
		.unwrap();
	let parked_args = [2.into(), 2.into()];
	let read = a.send(blob_a, "read", &parked_args);
	let withdraw = async {
		let waiting = fixture.waiting.recv().await.unwrap();
		let ((), change) = tokio::join!(settle(&fixture.store, waiting), b.send(&line_a, "withdraw", &[]));
		assert_eq!(change.unwrap().as_str(), Some("withdrawn"));
	};
	let (refusal, ()) = tokio::join!(read, withdraw);
	assert!(refusal.unwrap_err().to_string().contains("blob-expired:"));
	assert!(
		b.send(&blob_a_other_connection, "read", &read_args)
			.await
			.unwrap_err()
			.to_string()
			.contains("blob-expired:")
	);
	assert!(
		a.send(&upload_a, "write", &[Argument::Bytes(b"cd".to_vec())])
			.await
			.unwrap_err()
			.to_string()
			.contains("upload-incomplete:")
	);
	fixture.store.borrow_mut().close_room(&fixture.rooms[0]).unwrap();
	assert_eq!(
		b.send(&blob_b, "read", &read_args).await.unwrap().as_bytes(),
		Some(b"room".as_slice())
	);
	assert_eq!(fixture.store.borrow().usage().pending_bytes, 0);
	// A huge wire integer still means EOF; a floating-point offset is refused.
	let huge = Argument::BigInteger {
		negative: false,
		digits: "9".repeat(80),
	};
	assert!(
		b.send(&blob_b, "read", &[huge, 1.into()])
			.await
			.unwrap()
			.as_bytes()
			.unwrap()
			.is_empty()
	);
	assert!(
		b.send(&blob_b, "read", &[0.0.into(), 1.into()])
			.await
			.unwrap_err()
			.to_string()
			.contains("offset >= 0")
	);
	a.close(PendingWork::Cancel).await.unwrap();
	b.close(PendingWork::Cancel).await.unwrap();
	serving_a.await.unwrap().unwrap();
	serving_b.await.unwrap().unwrap();
	server.close().await.unwrap();
	host.close(PendingWork::Cancel).await.unwrap();
	runtime_a.close(PendingWork::Cancel).await.unwrap();
	runtime_b.close(PendingWork::Cancel).await.unwrap();
	assert!(host.take_failures().unwrap().is_empty());
}
