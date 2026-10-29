//! Client-side contracts over real Host capabilities. These actors control
//! replies and acknowledgements. They are not a substitute Rooms server.
use super::HostPlatform;
use glowcap::{Argument, ConnectOptions, Host, ListenerIdentity, PendingWork, Runtime, RuntimeConfig, tcp};
use rooms_application::{
	files::{CHUNK_BYTES, FileDescription, transfer},
	room::{attachment::Attachment, history},
};
use rooms_glowcap::client::{Client, Error, room::Room};
use serde_json::{Value, json};
use std::future::Future;
use std::{
	cell::{Cell, RefCell},
	rc::Rc,
	time::Duration,
};

#[derive(Clone, Default)]
struct ObservedDeadline {
	calls: Rc<RefCell<Vec<u64>>>,
	expire_next: Rc<Cell<bool>>,
}
impl rooms_glowcap::client::Deadline for ObservedDeadline {
	fn monotonic_millis(&self) -> u64 {
		0
	}
	async fn within<T>(&self, milliseconds: u64, work: impl Future<Output = T>) -> Option<T> {
		self.calls.borrow_mut().push(milliseconds);
		if self.expire_next.replace(false) {
			return None;
		}
		HostPlatform.within(milliseconds, work).await
	}
}
impl rooms_glowcap::client::Tasks for ObservedDeadline {
	type Task = super::HostTask;
	fn spawn(&self, work: impl Future<Output = ()> + 'static) -> Self::Task {
		HostPlatform.spawn(work)
	}
}

#[tokio::test]
async fn conversation_capabilities_have_independent_lifetimes_and_bounded_transfers() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(10), scenario())
				.await
				.expect("conversation scenario deadline");
		})
		.await;
}
async fn scenario() {
	let host = Host::from_seed([84; 32]).unwrap();
	let server = tcp::listen(
		"127.0.0.1",
		0,
		tcp::ListenOptions {
			identity: ListenerIdentity::Host(host.clone()),
			..Default::default()
		},
	)
	.await
	.unwrap();
	let runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
		.await
		.unwrap();
	let locator = server.locator().unwrap();
	let (client, accepted) = tokio::join!(runtime.connect(&locator, ConnectOptions::default()), server.accept());
	let accepted = Rc::new(accepted.unwrap());
	let service = accepted.clone();
	let serving = tokio::task::spawn_local(async move { service.serve().await });
	let deadlines = ObservedDeadline::default();
	let client = Client::new(client.unwrap(), deadlines.clone());
	let calls = Rc::new(RefCell::new(Vec::<Value>::new()));
	let record = |target: &'static str, calls: Rc<RefCell<Vec<Value>>>| {
		move |verb: &str, args: &[Argument]| {
			let args: Vec<Value> = args
				.iter()
				.map(|v| match v {
					Argument::String(s) => json!(s),
					Argument::Integer(i) => json!({"integer":i.to_string()}),
					_ => Value::Null,
				})
				.collect();
			calls
				.borrow_mut()
				.push(json!({"target":target,"verb":verb,"args":args}));
		}
	};
	let line_record = record("line", calls.clone());
	let line = accepted
		.spawn_owned(move |verb, args| {
			let verb = verb.ok_or("fixture requires a method")?;
			line_record(verb, args);
			match verb {
				"edit" | "refile" | "withdraw" => Ok(Argument::Void),
				_ => Err("unknown line verb".into()),
			}
		})
		.unwrap();
	let bytes = Rc::new(RefCell::new(Vec::<u8>::new()));
	let discard_count = Rc::new(Cell::new(0));
	let delay = Rc::new(Cell::new(false));
	let (tx, mut acknowledgements) = tokio::sync::mpsc::channel(1);
	let (seen, discarded, delayed, actor_host) = (bytes.clone(), discard_count.clone(), delay.clone(), host.clone());
	let upload = accepted
		.spawn_owned(move |verb, args| match verb.ok_or("fixture requires a method")? {
			"write" => {
				assert_eq!(args.len(), 1);
				let chunk = args[0].as_bytes().unwrap();
				assert!(chunk.len() <= CHUNK_BYTES);
				seen.borrow_mut().extend_from_slice(chunk);
				if delayed.get() {
					tx.try_send(actor_host.defer_turn().unwrap()).unwrap();
				}
				Ok(Argument::Void)
			}
			"discard" => {
				assert!(args.is_empty());
				discarded.set(discarded.get() + 1);
				Ok(Argument::Void)
			}
			_ => Err("unknown upload verb".into()),
		})
		.unwrap();
	let history_reply = Rc::new(RefCell::new(Ok(Argument::List(vec![]))));
	let reply = history_reply.clone();
	let line_ref = line.clone();
	let upload_ref = upload.clone();
	let seat_record = record("seat", calls.clone());
	let seat = accepted
		.spawn_owned(move |verb, args| {
			let verb = verb.ok_or("fixture requires a method")?;
			seat_record(verb, args);
			match verb {
				"post" => Ok(Argument::List(vec![1.into(), line_ref.clone().into()])),
				"postFiles" | "leave" => Ok(Argument::Void),
				"history" => {
					assert!(args.is_empty());
					reply.borrow().clone()
				}
				"attach" => {
					assert_eq!(args.len(), 5);
					assert_eq!(args[0].as_str(), Some("file"));
					assert_eq!(args[1].as_str(), Some("application/octet-stream"));
					assert_eq!(args[3].as_i64(), Some(0));
					assert_eq!(args[4].as_i64(), Some(0));
					Ok(upload_ref.clone().into())
				}
				_ => Err("unknown membership verb".into()),
			}
		})
		.unwrap();
	let service = accepted.clone();
	let member = seat.clone();
	let root = accepted
		.publish("room", move |verb, args| {
			let verb = verb.ok_or("fixture requires a method")?;
			assert_eq!(verb, "subscribe");
			let Argument::Reference(inbox) = &args[1] else {
				panic!("no inbox")
			};
			service
				.tell(
					inbox,
					"notify",
					&["room".into(), "".into(), "listed".into(), Argument::Boolean(false)],
				)
				.unwrap();
			// This double answers the file verbs on its seat, so the seat stands
			// in for the files facet the real room hands over separately.
			Ok(Argument::List(vec![
				member.clone().into(),
				"participant".into(),
				Argument::Void,
				member.clone().into(),
			]))
		})
		.unwrap();
	let reference = client.session().fetch("room").await.unwrap();
	let (room, _messages) = Room::subscribe(client.clone(), reference, "alice", Default::default())
		.await
		.unwrap();
	let posted = room.say("hello").await.unwrap().unwrap();
	posted.edit("changed").await.unwrap();
	posted.refile("caption", &[1, 0]).await.unwrap();
	posted.withdraw().await.unwrap();
	posted.withdraw().await.unwrap();
	assert!(room.post_files("files").await.unwrap().is_none());
	room.leave().await.unwrap();
	let captured: Value = serde_json::from_str(include_str!("../../../proofs/fixtures/conversation.json")).unwrap();
	assert_eq!(json!(*calls.borrow()), captured["calls"]);
	// Leaving membership does not revoke a line capability already held.
	posted.edit("after leave").await.unwrap();
	assert!(matches!(room.say("late").await, Err(Error::Membership(_))));
	let reference = client.session().fetch("room").await.unwrap();
	let (room, _messages) = Room::subscribe(client.clone(), reference, "alice", Default::default())
		.await
		.unwrap();
	assert!(room.history().await.unwrap().is_empty());
	*history_reply.borrow_mut() = Err("history unavailable".into());
	assert!(
		room.history()
			.await
			.unwrap_err()
			.to_string()
			.contains("history unavailable")
	);
	*history_reply.borrow_mut() = Ok(Argument::List(vec![
		Argument::List(vec![
			"alice".into(),
			"kept".into(),
			Argument::BigInteger {
				negative: false,
				digits: "100000000000000000000000000000000000000000000000000000000000000000000000000000000".into(),
			},
		]),
		Argument::List(vec![line.clone().into()]),
	]));
	let tail = room.history().await.unwrap();
	assert_eq!(tail.len(), 1);
	assert_eq!(tail[0].at, 1e80);
	*history_reply.borrow_mut() = Ok(Argument::List(
		(0..=history::MAX_LINES)
			.map(|_| Argument::List(vec!["alice".into()]))
			.collect(),
	));
	assert!(matches!(
		room.history().await,
		Err(Error::History(history::Error::TooManyLines))
	));
	let mut staged = room
		.stage(FileDescription::parse("file", "application/octet-stream", (CHUNK_BYTES + 1) as u64, 0, 0).unwrap())
		.await
		.unwrap();
	room.post_files("streaming").await.unwrap();
	staged.write(vec![7; CHUNK_BYTES]).await.unwrap();
	staged.write(vec![8]).await.unwrap();
	assert!(staged.complete());
	assert_eq!(staged.written(), CHUNK_BYTES + 1);
	assert_eq!(bytes.borrow().len(), CHUNK_BYTES + 1);
	delay.set(true);
	let mut cancelled = room
		.stage(FileDescription::parse("file", "application/octet-stream", 2, 0, 0).unwrap())
		.await
		.unwrap();
	room.post_files("cancelled observation").await.unwrap();
	let mut pending = Box::pin(cancelled.write(vec![9]));
	let mut acknowledgement =
		tokio::select! {r=acknowledgements.recv()=>r.unwrap(),_=&mut pending=>panic!("write acknowledged too early")};
	drop(pending);
	assert_eq!(cancelled.written(), 0);
	assert!(matches!(
		cancelled.write(vec![9]).await,
		Err(Error::Transfer(transfer::Error::UnobservedWrite))
	));
	assert_eq!(bytes.borrow().len(), CHUNK_BYTES + 2);
	acknowledgement.fulfill(&Argument::Void).unwrap();
	cancelled.discard().await.unwrap();
	assert_eq!(discard_count.get(), 1);
	delay.set(false);
	let mut timed = room
		.stage(FileDescription::parse("file", "application/octet-stream", 2, 0, 0).unwrap())
		.await
		.unwrap();
	room.post_files("timed-out observation").await.unwrap();
	deadlines.expire_next.set(true);
	assert!(matches!(timed.write(vec![10]).await, Err(Error::Timeout(_))));
	assert_eq!(deadlines.calls.borrow().last(), Some(&transfer::STALL_MS));
	assert!(matches!(
		timed.write(vec![10]).await,
		Err(Error::Transfer(transfer::Error::UnobservedWrite))
	));
	timed.discard().await.unwrap();
	assert_eq!(bytes.borrow().len(), CHUNK_BYTES + 3);
	let read_count = Rc::new(Cell::new(0));
	let reads = read_count.clone();
	let mode = Rc::new(Cell::new(0));
	let response_mode = mode.clone();
	let blob = accepted
		.publish("blob", move |verb, args| {
			let verb = verb.ok_or("fixture requires a method")?;
			assert_eq!(verb, "read");
			assert_eq!(args.len(), 2);
			reads.set(reads.get() + 1);
			let offset = args[0].as_i64().unwrap() as usize;
			let length = args[1].as_i64().unwrap() as usize;
			assert!(length <= CHUNK_BYTES);
			let remaining = CHUNK_BYTES + 1 - offset;
			Ok(match response_mode.get() {
				1 => Argument::Bytes(vec![]),
				2 => Argument::Bytes(vec![0; length + 1]),
				3 => Argument::List(vec![]),
				_ => Argument::Bytes(vec![3; length.min(remaining).min(10000)]),
			})
		})
		.unwrap();
	let file = room.file(Attachment {
		description: FileDescription::parse("blob", "application/octet-stream", (CHUNK_BYTES + 1) as u64, 0, 0)
			.unwrap(),
		blob: client.session().fetch("blob").await.unwrap(),
	});
	let mut progress = Vec::new();
	let got = file.fetch(|n| progress.push(n)).await.unwrap();
	assert_eq!(got, vec![3; CHUNK_BYTES + 1]);
	assert_eq!(progress.last(), Some(&(CHUNK_BYTES + 1)));
	let before = read_count.get();
	assert!(file.read(u64::MAX, 1).await.unwrap().is_empty());
	assert_eq!(read_count.get(), before);
	assert!(matches!(
		file.read(0, 0).await,
		Err(Error::Transfer(transfer::Error::ReadLength))
	));
	for bad in 1..=3 {
		mode.set(bad);
		assert!(matches!(
			file.read(0, 3).await,
			Err(Error::Transfer(transfer::Error::ReadReply))
		));
	}
	mode.set(0);
	assert_eq!(deadlines.calls.borrow().last(), Some(&transfer::STALL_MS));
	room.leave().await.unwrap();
	assert_eq!(file.read(0, 3).await.unwrap(), vec![3; 3]);
	drop((room, posted, staged, file, client));
	accepted.release(root).unwrap();
	accepted.release(blob).unwrap();
	drop((seat, line, upload));
	accepted.close(PendingWork::Cancel).await.unwrap();
	runtime.close(PendingWork::Cancel).await.unwrap();
	server.close().await.unwrap();
	host.close(PendingWork::Cancel).await.unwrap();
	serving.await.unwrap().unwrap();
}
