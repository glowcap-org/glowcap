//! Real CapTP exercises the host client and shared wire adapter. The fixture
//! owns an in-memory index. This is not the production archive storage service.
use super::HostPlatform;
use glowcap::{
	Argument, ConnectOptions, Host, ListenerIdentity, PendingWork, Ref, Runtime, RuntimeConfig, Session, tcp,
};
use rooms_application::{
	archive::{Access, Body, ConversationKind, Coordinates, Facet, Filter, LineState, Record, index::Index, protocol},
	room::ArgumentView,
};
use rooms_glowcap::{
	Value, archive as wire,
	client::{Client, Error, archive::Archive},
};
use std::{
	cell::{Cell, RefCell},
	rc::Rc,
	sync::Arc,
	time::Duration,
};
fn record(directory: &str, conversation: &str, text: &str, at: u64) -> Record {
	Record::new(
		Coordinates {
			source: "recorder".into(),
			generation: "generation".into(),
			id: "same-id".into(),
		},
		directory.into(),
		Body::Line {
			conversation_kind: ConversationKind::Room,
			conversation: conversation.into(),
			from: "alice".into(),
			text: text.into(),
			mine: false,
			at,
			order: at,
			state: LineState::Present,
			previews: Default::default(),
			attachments: vec![],
		},
	)
	.unwrap()
}
fn facet(session: &Rc<Session>, index: Rc<RefCell<Index>>, scope: Facet) -> Ref {
	let session_weak = Rc::downgrade(session);
	session
		.spawn_owned(move |verb, args| {
			let fail = |e: rooms_application::archive::Error| e.to_string();
			match (verb, args) {
				("put", [row]) => {
					let record = protocol::record(&Value(row)).map_err(fail)?;
					if !scope.permits_put(&record) {
						return Err("archive scope refused write".into());
					}
					let mut index = index.borrow_mut();
					let revision = index.revision() + 1;
					index.apply(revision, record).map_err(fail)?;
					Ok(Argument::Integer(revision as i64))
				}
				("read", [asked, after, limit]) => {
					let asked = protocol::filter(&Value(asked)).map_err(fail)?;
					let after =
						u64::try_from(Value(after).integer().ok_or("after integer")?).map_err(|_| "negative cursor")?;
					let limit = protocol::read_limit(&Value(limit)).map_err(fail)?;
					let Some(filter) = scope.scope().intersect(&asked) else {
						return Ok(Argument::List(vec![
							Argument::Integer(after as i64),
							false.into(),
							Argument::List(vec![]),
						]));
					};
					let page = index.borrow().read(&filter, after, limit).map_err(fail)?;
					wire::page_row(&page, &filter, after, limit).map_err(fail)
				}
				("narrow", [asked, access]) => {
					let asked = protocol::filter(&Value(asked)).map_err(fail)?;
					let access = match access.as_str() {
						Some("read") => Access::Read,
						Some("read-write") => Access::ReadWrite,
						_ => return Err("invalid access".into()),
					};
					let narrowed = scope.narrow(&asked, access).map_err(fail)?;
					Ok(facet(&session_weak.upgrade().ok_or("closed")?, index.clone(), narrowed).into())
				}
				_ => Err("unexpected archive call".into()),
			}
		})
		.unwrap()
}
#[tokio::test]
async fn archive_clients_keep_scopes_and_validate_replies_over_tcp() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(10), scenario())
				.await
				.expect("archive scenario deadline");
		})
		.await;
}
async fn scenario() {
	let host = Host::from_seed([197; 32]).unwrap();
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
	let (connected, accepted) = tokio::join!(runtime.connect(&locator, ConnectOptions::default()), server.accept());
	let accepted = Rc::new(accepted.unwrap());
	let service = accepted.clone();
	let serving = tokio::task::spawn_local(async move { service.serve().await });
	let client = Client::new(connected.unwrap(), HostPlatform);
	let root = facet(
		&accepted,
		Rc::new(RefCell::new(Index::new(5000).unwrap())),
		Facet::new(Filter::default(), Access::ReadWrite).unwrap(),
	);
	let held = root.clone();
	let public = accepted
		.publish("archive", move |verb, _| {
			assert_eq!(verb, "root");
			Ok(held.clone().into())
		})
		.unwrap();
	let reference = client
		.session()
		.send(&client.session().fetch("archive").await.unwrap(), "root", &[])
		.await
		.unwrap();
	let Argument::Reference(reference) = reference else {
		panic!("archive reference")
	};
	let archive = Archive::new(client.clone(), reference);
	let all = Filter::default();
	assert_eq!(archive.put(&record("dir", "garden", "first", 10)).await.unwrap(), 1);
	assert_eq!(archive.put(&record("dir", "library", "second", 20)).await.unwrap(), 2);
	assert_eq!(archive.put(&record("other", "garden", "third", 30)).await.unwrap(), 3);
	assert_eq!(archive.read_all(&all).await.unwrap().len(), 3);
	let first = archive.read(&all, 0, 1).await.unwrap();
	assert_eq!(first.next, 1);
	assert!(first.more);
	assert_eq!(archive.put(&record("dir", "garden", "edited", 99)).await.unwrap(), 4);
	let whole = archive.read(&all, 0, usize::MAX).await.unwrap();
	assert_eq!(whole.records.len(), 3);
	assert!(
		matches!(whole.records[2].record.body(),Body::Line { at:10,order:10,text,.. } if text.as_str()==Some("edited"))
	);
	assert!(matches!(first.records[0].record.body(),Body::Line {text,..} if text.as_str()==Some("first")));
	let scope = Filter {
		directory: Some("dir".into()),
		conversation: Some("garden".into()),
		..Default::default()
	};
	let garden = archive.narrow(&scope, Access::Read).await.unwrap();
	assert_eq!(garden.read(&all, 0, 128).await.unwrap().records.len(), 1);
	assert!(garden.put(&record("dir", "garden", "refused", 50)).await.is_err());
	assert!(garden.narrow(&all, Access::ReadWrite).await.is_err());
	let other = Filter {
		conversation: Some("library".into()),
		..Default::default()
	};
	assert!(garden.narrow(&other, Access::Read).await.is_err());
	assert!(garden.read(&other, 0, 128).await.unwrap().records.is_empty());
	drop(garden);
	assert_eq!(archive.read(&all, 100, 128).await.unwrap().next, 100);
	assert_eq!(
		archive.put(&record("dir", "library", "still live", 60)).await.unwrap(),
		5
	);
	let scanned_calls = Rc::new(Cell::new(0));
	let count = scanned_calls.clone();
	let endless = accepted
		.publish("endless", move |verb, args| {
			assert_eq!(verb, "read");
			count.set(count.get() + 1);
			let after = Value(&args[1]).integer().unwrap() as u64;
			let record = Arc::new(record("dir", "garden", "repeated", 1));
			let page = rooms_application::archive::index::Page {
				next: after + 128,
				more: true,
				records: (1..=128)
					.map(|offset| {
						Arc::new(rooms_application::archive::index::Entry {
							revision: after + offset,
							record: record.clone(),
						})
					})
					.collect(),
			};
			Ok(wire::page_row(&page, &Filter::default(), after, 128).unwrap())
		})
		.unwrap();
	let feed = Archive::new(client.clone(), client.session().fetch("endless").await.unwrap());
	assert!(matches!(
		feed.read_all(&all).await,
		Err(Error::Archive(rooms_application::archive::Error::Capacity))
	));
	assert_eq!(scanned_calls.get(), 40);
	drop(feed);
	accepted.release(endless).unwrap();
	let reply = Rc::new(RefCell::new(Argument::Integer(0)));
	let calls = Rc::new(Cell::new(0));
	let (answer, called) = (reply.clone(), calls.clone());
	let malformed = accepted
		.publish("malformed", move |_, _| {
			called.set(called.get() + 1);
			Ok(answer.borrow().clone())
		})
		.unwrap();
	let bad = Archive::new(client.clone(), client.session().fetch("malformed").await.unwrap());
	assert!(matches!(
		bad.put(&record("dir", "garden", "bad", 1)).await,
		Err(Error::Archive(_))
	));
	assert!(matches!(bad.narrow(&all, Access::Read).await, Err(Error::Archive(_))));
	assert!(bad.read(&all, 0, 0).await.is_err());
	assert!(bad.read(&all, 1 << 53, 128).await.is_err());
	assert_eq!(calls.get(), 2); // Invalid local reads spend no remote turn.
	let valid = wire::page_row(&whole, &all, 0, 128).unwrap();
	*reply.borrow_mut() = valid.clone();
	assert!(bad.read(&all, 0, 2).await.is_err());
	assert!(bad.read(&scope, 0, 128).await.is_err()); // No sibling data leaks through a claimed scope.
	for replacement in [Argument::Integer(-1), Argument::Integer(1 << 53), Argument::Float(4.0)] {
		let Argument::List(mut row) = valid.clone() else {
			unreachable!()
		};
		row[0] = replacement;
		*reply.borrow_mut() = Argument::List(row);
		assert!(bad.read(&all, 0, 128).await.is_err());
	}
	let Argument::List(mut row) = valid else { unreachable!() };
	row[2] = Argument::List(vec![root.clone().into()]);
	*reply.borrow_mut() = Argument::List(row);
	assert!(bad.read(&all, 0, 128).await.is_err());
	*reply.borrow_mut() = Argument::Void;
	drop((bad, archive, first, whole));
	client.session().close(PendingWork::Cancel).await.unwrap();
	drop(client);
	accepted.release(public).unwrap();
	accepted.release(malformed).unwrap();
	drop(root);
	accepted.close(PendingWork::Cancel).await.unwrap();
	runtime.close(PendingWork::Cancel).await.unwrap();
	server.close().await.unwrap();
	host.close(PendingWork::Cancel).await.unwrap();
	serving.await.unwrap().unwrap();
}
