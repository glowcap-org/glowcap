mod direct_dispatch;
mod lines;
mod operations;
mod peers;
mod publications;
mod route_openings;
mod routes;
use super::*;
use crate::documents::SessionDocuments;
use glowcap::{PendingWork, Runtime, RuntimeConfig, tcp};
use rooms_application::{
	directory::registration,
	grants::Access,
	session::checkpoint::{
		Checkpoint, Routes,
		commands::{Command, Facts},
		reconciliation::Id,
	},
	text::DocumentText,
};
use rooms_glowcap::routes::CheckpointRoutes;
use rooms_runtime::session::commands::SessionCommands;
use serde_json::{Value, json};
use std::{
	cell::{Ref, RefCell},
	rc::Rc,
	time::Duration,
};
use tokio::sync::mpsc;

struct Temp(std::path::PathBuf);
impl Drop for Temp {
	fn drop(&mut self) {
		std::fs::remove_dir_all(&self.0).unwrap();
	}
}
fn text<const N: usize, const E: bool>(s: &str) -> rooms_application::fields::Text<N, E> {
	rooms_application::fields::Text::new(s.into()).unwrap()
}
async fn command(commands: &SessionCommands, id: &str, command: Command, args: Vec<DocumentText>) {
	let base = commands.view().read(|s| s.revision()).unwrap().unwrap();
	commands
		.prepare_command(text(id), base, command, args)
		.unwrap()
		.send()
		.unwrap()
		.wait()
		.await
		.unwrap();
}
async fn until(runtime: &DirectoryRuntime, predicate: impl Fn(&Directories) -> bool) {
	let mut changes = runtime.changes();
	loop {
		changes.borrow_and_update();
		if predicate(&runtime.read()) {
			return;
		}
		changes.changed().await.unwrap();
	}
}
#[tokio::test]
async fn committed_intent_drives_bounded_connections_facts_adoption_and_reconnect() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(20), scenario())
				.await
				.expect("directory supervisor deadline");
		})
		.await;
}
async fn scenario() {
	let temp = Temp(std::env::temp_dir().join(format!("rooms-runtime-{}", std::process::id())));
	std::fs::create_dir(&temp.0).unwrap();
	let docs = SessionDocuments::open(&temp.0).await.unwrap().into_owners();
	drop((docs.grants, docs.bridge_secrets));
	let (commands, command_worker) = SessionCommands::open(docs.state, rooms_platform::HostPlatform)
		.await
		.unwrap();
	let transport = Rc::new(
		Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
			.await
			.unwrap(),
	);
	let (runtime, worker, events, mut inbox) = DirectoryRuntime::new(
		transport.clone(),
		commands.clone(),
		"ocapn://member.id".into(),
		rooms_platform::HostPlatform,
		rooms_platform::OsEntropy,
	)
	.unwrap();
	let command_task = tokio::task::spawn_local(command_worker.run(events));
	let runtime_task = tokio::task::spawn_local(worker.run());
	let (tx, mut arrivals) = mpsc::channel(16);
	let mut peers = Vec::new();
	let mut ids = Vec::<Id>::new();
	let mut checkpoint: Value = serde_json::from_str(&Checkpoint::empty().encode_for(Access::Admin).unwrap()).unwrap();
	for index in 0..5 {
		let peer = peers::Peer::start(index, tx.clone()).await;
		let locator = peer.locator();
		let id = CheckpointRoutes.locator_authority(&locator).unwrap();
		checkpoint["directories"]
			.as_array_mut()
			.unwrap()
			.push(json!({"id":id,"locator":locator,"home":index==0,"nick":"alice","standing":null}));
		ids.push(text(&id));
		peers.push(peer);
	}
	commands
		.prepare_adoption(
			text("adopt"),
			0,
			Checkpoint::decode(&checkpoint.to_string(), &CheckpointRoutes).unwrap(),
		)
		.unwrap()
		.send()
		.unwrap()
		.wait()
		.await
		.unwrap();
	let mut registered = Vec::new();
	for _ in 0..CONNECTING_LIMIT {
		registered.push(arrivals.recv().await.unwrap());
	}
	assert!(arrivals.try_recv().is_err());
	assert_eq!(
		runtime
			.read()
			.rows()
			.iter()
			.filter(|r| r.phase() == Phase::Connecting)
			.count(),
		CONNECTING_LIMIT
	);
	assert_eq!(
		runtime
			.read()
			.rows()
			.iter()
			.filter(|r| r.phase() == Phase::Waiting)
			.count(),
		1
	);
	registered[0].ack().await;
	registered.push(arrivals.recv().await.unwrap());
	for registration in &registered[1..] {
		registration.ack().await;
	}
	until(&runtime, |r| r.rows().iter().all(|row| row.phase() == Phase::Connected)).await;
	registered.sort_by_key(|r| r.index);
	// Admission reads the held foreign publication from the current live view.
	command(&commands,"join",Command::JoinRoom,vec![json!({"locator":peers[0].locator(),"nick":"alice","conversation":{
		"kind":"room","id":"room","directory":ids[0].text().as_str().unwrap(),"name":"shared","held":false,"standing":null,"draft":""}}).to_string().into()]).await;
	let checkpoint: Value = commands
		.view()
		.read(|s| serde_json::from_str(&s.checkpoint().unwrap().encode_for(Access::Admin).unwrap()).unwrap())
		.unwrap();
	assert_eq!(checkpoint["conversations"][0]["publicationId"], "foreign-0");
	registered[0].notify("mintInboxFor").await;
	let held = inbox.next().await.unwrap();
	assert_eq!(held.directory(), &ids[0]);
	assert!(held.current());
	registered[0].notify("directRequested").await;
	let rename = commands
		.prepare_command(
			text("rename"),
			commands.view().read(|s| s.revision()).unwrap().unwrap(),
			Command::SetDirectoryNick,
			vec![ids[0].text().clone(), "renamed".into()],
		)
		.unwrap()
		.send()
		.unwrap();
	// Acceptance sees a current producer here, but queues behind the rename.
	// The serializer must recheck the scope after that command commits.
	assert!(
		runtime
			.accept_direct(&held)
			.await
			.err()
			.unwrap()
			.to_string()
			.contains("retired")
	);
	rename.wait().await.unwrap();
	assert_eq!(
		commands
			.view()
			.read(|s| s.checkpoint().unwrap().directs().count())
			.unwrap(),
		0
	);
	assert!(
		!held.current(),
		"commit must synchronously retire queued registration authority"
	);
	let renamed = arrivals.recv().await.unwrap();
	assert_eq!((renamed.index, renamed.connection), (0, 1));
	assert_eq!(renamed.nick, "renamed");
	assert!(
		renamed.voucher.is_none(),
		"an old name voucher cannot be reused for a new name"
	);
	renamed.ack().await;
	until(&runtime, |r| r.rows()[0].phase() == Phase::Connected).await;
	renamed.notify("mintInboxFor").await;
	let fresh = inbox.next().await.unwrap();
	assert!(fresh.current());
	assert_eq!(
		fresh.event().kind,
		registration::Kind::MintInboxFor,
		"retired queued work is skipped"
	);
	let accepted = runtime.accept_direct(&fresh).await.unwrap();
	assert!(accepted.current());
	assert_eq!(accepted.directory(), &ids[0]);
	let duplicate = runtime.accept_direct(&fresh).await.unwrap();
	assert_eq!(accepted.conversation(), duplicate.conversation());
	assert_eq!(
		commands
			.view()
			.read(|s| s.checkpoint().unwrap().directs().count())
			.unwrap(),
		1
	);
	let reopen = json!({"kind":"direct", "id":accepted.conversation().text().as_str().unwrap(),
        "directory":accepted.directory().text().as_str().unwrap(), "peer":accepted.peer().text().as_str().unwrap(),
        "peerRegistrationId":accepted.registration().as_str(), "closed":false, "draft":""});
	command(
		&commands,
		"close-direct",
		Command::CloseDirect,
		vec![accepted.conversation().text().clone()],
	)
	.await;
	assert!(!accepted.current());
	let shares = rooms_runtime::archive::shares::ArchiveShares::new(rooms_platform::OsEntropy);
	assert!(
		shares
			.receiver()
			.offer(
				&accepted,
				"",
				rooms_application::archive::ShareKind::Room,
				Some("garden"),
				"retired"
			)
			.is_err()
	);
	assert!(shares.receiver().views().is_empty());
	command(
		&commands,
		"remove-direct",
		Command::LeaveConversation,
		vec![accepted.conversation().text().clone()],
	)
	.await;
	command(
		&commands,
		"reopen-direct",
		Command::OpenDirect,
		vec![reopen.to_string().into()],
	)
	.await;
	assert!(
		!accepted.current(),
		"restoring identical intent cannot revive an issued context"
	);
	assert!(!duplicate.current());
	let reopened = runtime.accept_direct(&fresh).await.unwrap();
	assert!(reopened.current());
	assert_eq!(accepted.conversation(), reopened.conversation());
	renamed.notify("directRequested").await;
	let request = inbox.next().await.unwrap();
	assert!(
		runtime.accept_direct(&request).await.is_err(),
		"a route request cannot accept a conversation"
	);
	drop(request);
	// A real closed connection redials after the bounded retry delay and uses
	// the proof belonging to the same name. Other directories remain live.
	let prior_connection = runtime.connected(&ids[1]).unwrap().0.client().session().borrowed();
	let scope = ids[1].text().as_str().unwrap();
	assert!(runtime.has_connection(scope, &prior_connection));
	registered[1].session.close(PendingWork::Cancel).await.unwrap();
	let reconnected = arrivals.recv().await.unwrap();
	assert_eq!((reconnected.index, reconnected.connection), (1, 2));
	assert_eq!(reconnected.voucher, Some(vec![1, 9]));
	reconnected.ack().await;
	until(&runtime, |r| r.rows()[1].phase() == Phase::Connected).await;
	assert!(!runtime.has_connection(scope, &prior_connection));
	assert!(runtime.has_connection(scope, runtime.connected(&ids[1]).unwrap().0.client().session()));
	assert!(fresh.current());
	// Handed-out work remains charged. Filling the remaining capacity retires
	// only the overflowing directory and recovery discards its old generation.
	for _ in 0..REGISTRATION_LIMIT - 2 {
		registered[3].notify("directRequested").await;
	}
	registered[3].notify("directRequested").await;
	until(&runtime, |r| r.rows()[3].phase() == Phase::Waiting).await;
	assert!(runtime.read().rows()[3].issue().unwrap().contains("budget"));
	assert!(fresh.current());
	let resumed = arrivals.recv().await.unwrap();
	assert_eq!((resumed.index, resumed.connection), (3, 1));
	resumed.ack().await;
	until(&runtime, |r| r.rows()[3].phase() == Phase::Connected).await;
	let mut next = Box::pin(inbox.next());
	std::future::poll_fn(|cx| {
		use core::future::Future;
		assert!(
			next.as_mut().poll(cx).is_pending(),
			"only retired notices remain queued"
		);
		std::task::Poll::Ready(())
	})
	.await;
	resumed.notify("mintInboxFor").await;
	let resumed_work = next.await.unwrap();
	assert_eq!(resumed_work.directory(), &ids[3]);
	assert_eq!(resumed_work.event().kind, registration::Kind::MintInboxFor);
	drop(resumed_work);
	command(&commands, "leave", Command::LeaveDirectory, vec![ids[4].text().clone()]).await;
	until(&runtime, |r| r.rows().len() == 4).await;
	assert!(runtime.read().fact_issues().next().is_none());
	runtime.close().await.unwrap();
	runtime_task.await.unwrap().unwrap();
	assert!(!fresh.current());
	assert!(!reopened.current());
	assert!(runtime.read().rows().is_empty());
	assert!(inbox.next().await.is_none());
	commands.close().await.unwrap();
	command_task.await.unwrap().unwrap();
	transport.close(PendingWork::Cancel).await.unwrap();
	for peer in peers {
		peer.close().await;
	}
}

#[tokio::test]
async fn fact_borrow_ends_before_the_command_persistence_future_exists() {
	let temp = Temp(std::env::temp_dir().join(format!("rooms-runtime-facts-{}", std::process::id())));
	std::fs::create_dir(&temp.0).unwrap();
	let docs = SessionDocuments::open(&temp.0).await.unwrap().into_owners();
	let mut state = docs.state;
	assert!(matches!(
		state.load().await.unwrap(),
		crate::session_state::LoadStatus::Ready
	));
	struct Borrowed<'a>(Ref<'a, ()>);
	impl Facts for Borrowed<'_> {}
	let live = RefCell::new(());
	let args = vec!["standing".into()];
	let pending = {
		let facts = Borrowed(live.borrow());
		let _ = &facts.0;
		state.command(text("standing"), 0, Command::SetStanding, &args, &facts)
	};
	assert!(live.try_borrow_mut().is_ok());
	pending.await.unwrap();
	drop((state, docs.grants, docs.bridge_secrets));
}

#[tokio::test]
async fn cancelled_worker_reports_failure_and_cannot_claim_clean_shutdown() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let temp = Temp(std::env::temp_dir().join(format!("rooms-runtime-cancelled-{}", std::process::id())));
			std::fs::create_dir(&temp.0).unwrap();
			let docs = SessionDocuments::open(&temp.0).await.unwrap().into_owners();
			let (commands, command_worker) = SessionCommands::open(docs.state, rooms_platform::HostPlatform)
				.await
				.unwrap();
			let transport = Rc::new(
				Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
					.await
					.unwrap(),
			);
			let (runtime, worker, events, inbox) = DirectoryRuntime::new(
				transport.clone(),
				commands,
				"ocapn://member.id".into(),
				rooms_platform::HostPlatform,
				rooms_platform::OsEntropy,
			)
			.unwrap();
			let task = tokio::task::spawn_local(worker.run());
			task.abort();
			assert!(task.await.unwrap_err().is_cancelled());
			assert!(runtime.read().failure().unwrap().contains("before completing shutdown"));
			assert!(runtime.close().await.is_err());
			drop((events, inbox, command_worker, docs.grants, docs.bridge_secrets));
			transport.close(PendingWork::Cancel).await.unwrap();
		})
		.await;
}
