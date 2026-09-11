use super::*;
use crate::session_runtime::direct_commands::{Command as Action, DirectCommands, LineKey, Operation};
fn operation(fixture: &Fixture, id: &str) -> Operation {
	Operation {
		id: text(id),
		base: fixture.commands.view().read(|s| s.revision()).unwrap().unwrap(),
	}
}
fn send(text: &str) -> Action {
	Action::Send {
		text: text.into(),
		files: Vec::new(),
	}
}
fn bytes(byte: u8) -> Source {
	Source::bytes(
		FileDescription::new("same".into(), "text/plain".into(), 3, 0, 0).unwrap(),
		vec![byte; 3],
	)
	.unwrap()
}
// Refuse opening the staging file, before any replacement can have happened.
struct BlockedDirectory {
	path: std::path::PathBuf,
	parked: std::path::PathBuf,
}
impl BlockedDirectory {
	fn new(path: &std::path::Path) -> Self {
		let parked = path.with_extension("blocked-write");
		std::fs::rename(path, &parked).unwrap();
		let guard = Self {
			path: path.into(),
			parked,
		};
		std::fs::write(path, b"not a directory").unwrap();
		guard
	}
}
impl Drop for BlockedDirectory {
	fn drop(&mut self) {
		std::fs::remove_file(&self.path).unwrap();
		std::fs::rename(&self.parked, &self.path).unwrap();
	}
}
fn pending(fixture: &Fixture, id: &str) -> bool {
	fixture
		.commands
		.view()
		.read(|s| s.pending_ids().unwrap().any(|p| p.text().as_str() == Some(id)))
		.unwrap()
}
#[tokio::test]
async fn durable_directs_bind_content_and_generation_and_repeat_without_recreating_authority() {
	deadline(async {
		let mut fixture = Fixture::new("durable-directs").await;
		let (dispatch, worker, mut outcomes) = fixture.dispatcher();
		let dispatcher = tokio::task::spawn_local(worker.run());
		fixture.arrival.notify("mintInboxFor").await;
		let context = published(&mut outcomes).await;
		let offer = fixture.peer.offers.recv().await.unwrap();
		let mut peer = remote(&offer, &context).await;
		let sources = Rc::new(Sources::new(Deadline));
		let (commands, worker) = DirectCommands::new(
			crate::client::Deadline,
			fixture.commands.clone(),
			fixture.routes.receiver(),
			fixture.lines.receiver(),
			sources.clone(),
		);
		let task = tokio::task::spawn_local(worker.run());

		let blocked = BlockedDirectory::new(&fixture._temp.0);
		let refused = operation(&fixture, "prepare-refused");
		let failure = commands
			.submit(refused.clone(), &context, send("before preparation"))
			.unwrap()
			.wait()
			.await
			.unwrap_err();
		assert_eq!(failure.delivery, Delivery::NotSent);
		assert!(!pending(&fixture, "prepare-refused"));
		assert!(Box::pin(peer.events.next())
			.as_mut()
			.poll(&mut Context::from_waker(Waker::noop()))
			.is_pending());
		drop(blocked);
		commands
			.submit(refused, &context, send("before preparation"))
			.unwrap()
			.wait()
			.await
			.unwrap();
		drop(fixture.events.next().await.unwrap());
		drop(peer.events.next().await.unwrap());
		let reads = Rc::new(Cell::new(0));
		let op = operation(&fixture, "file-send");
		let committed = commands
			.submit(
				op.clone(),
				&context,
				Action::Send {
					text: "file".into(),
					files: vec![source("same", 7, &reads)],
				},
			)
			.unwrap()
			.wait()
			.await
			.unwrap();
		let sent = committed.sent.unwrap();
		let event = fixture.events.next().await.unwrap();
		let key = LineKey {
			generation: event.generation,
			line: sent.line,
		};
		assert_eq!(event.files[0].read(0, 3).await.unwrap(), [7; 3]);
		assert_eq!(
			peer.events.next().await.unwrap().files[0].read(0, 3).await.unwrap(),
			[7; 3]
		);
		assert_eq!(reads.get(), 1, "hashing and delivery use the same frozen capture");
		assert!(!pending(&fixture, "file-send"));
		let repeated = commands
			.submit(
				op.clone(),
				&context,
				Action::Send {
					text: "file".into(),
					files: vec![bytes(7)],
				},
			)
			.unwrap()
			.wait()
			.await
			.unwrap();
		assert_eq!(repeated.revision, committed.revision);
		assert!(repeated.sent.is_none());
		assert!(
			commands
				.submit(
					op,
					&context,
					Action::Send {
						text: "file".into(),
						files: vec![bytes(8)]
					}
				)
				.unwrap()
				.wait()
				.await
				.is_err(),
			"same description with different bytes is not a retry"
		);
		let edit = operation(&fixture, "edit-file");
		commands
			.submit(
				edit.clone(),
				&context,
				Action::Edit {
					line: key,
					text: "edited".into(),
				},
			)
			.unwrap()
			.wait()
			.await
			.unwrap();
		drop(fixture.events.next().await.unwrap());
		drop(peer.events.next().await.unwrap());
		let wrong = LineKey {
			generation: [42; 16],
			line: key.line,
		};
		let invalid = operation(&fixture, "old-generation");
		assert!(commands
			.submit(invalid, &context, Action::Withdraw { line: wrong })
			.unwrap()
			.wait()
			.await
			.unwrap_err()
			.reason
			.contains("generation"));
		assert!(!pending(&fixture, "old-generation"));
		let withdraw = operation(&fixture, "withdraw-file");
		commands
			.submit(withdraw.clone(), &context, Action::Withdraw { line: key })
			.unwrap()
			.wait()
			.await
			.unwrap();
		drop(fixture.events.next().await.unwrap());
		drop(peer.events.next().await.unwrap());
		assert!(commands
			.submit(withdraw, &context, Action::Withdraw { line: key })
			.unwrap()
			.wait()
			.await
			.unwrap()
			.sent
			.is_none());
		assert!(
			commands
				.submit(
					edit,
					&context,
					Action::Edit {
						line: key,
						text: "edited".into()
					}
				)
				.unwrap()
				.wait()
				.await
				.unwrap()
				.sent
				.is_none(),
			"committed retries precede live line lookup"
		);
		assert!(Box::pin(peer.events.next())
			.as_mut()
			.poll(&mut Context::from_waker(Waker::noop()))
			.is_pending());

		peer.delay.set(true);
		let lost_commit = operation(&fixture, "accepted-without-commit");
		let accepted = commands
			.submit(lost_commit.clone(), &context, send("accepted before disk failure"))
			.unwrap();
		let (mut answer, line) = peer.answers.recv().await.unwrap();
		let blocked = BlockedDirectory::new(&fixture._temp.0);
		answer.fulfill_value(&line.into()).unwrap();
		let failure = accepted.wait().await.unwrap_err();
		assert_eq!(failure.delivery, Delivery::Accepted);
		assert_eq!(failure.ledger, crate::session_runtime::direct_commands::Ledger::Unknown);
		assert!(pending(&fixture, "accepted-without-commit"));
		drop(fixture.events.next().await.unwrap());
		drop(peer.events.next().await.unwrap());
		drop(blocked);
		assert!(commands
			.submit(lost_commit.clone(), &context, send("accepted before disk failure"))
			.unwrap()
			.wait()
			.await
			.is_err());
		fixture
			.commands
			.resolve(
				lost_commit.id.clone(),
				rooms_application::session::state::Outcome::Committed,
			)
			.unwrap()
			.send()
			.unwrap()
			.wait()
			.await
			.unwrap();
		assert!(commands
			.submit(lost_commit, &context, send("accepted before disk failure"))
			.unwrap()
			.wait()
			.await
			.unwrap()
			.sent
			.is_none());
		commands.close().await.unwrap();
		task.await.unwrap().unwrap();
		peer.owner.close_files().await.unwrap();
		dispatch.close().await.unwrap();
		dispatcher.await.unwrap().unwrap();
		drop((commands, sources, peer, offer));
		fixture.close().await;
	})
	.await;
}
#[tokio::test]
async fn durable_direct_shutdown_retains_uncertainty_and_orders_conversations_independently() {
	deadline(async {
		let mut fixture = Fixture::new("durable-shutdown").await;
		let (dispatch, worker, mut outcomes) = fixture.dispatcher();
		let dispatcher = tokio::task::spawn_local(worker.run());
		fixture.arrival.notify("mintInboxFor").await;
		let context = published(&mut outcomes).await;
		let offer = fixture.peer.offers.recv().await.unwrap();
		let mut peer = remote(&offer, &context).await;
		fixture.other_arrival.notify("mintInboxFor").await;
		let other_context = published(&mut outcomes).await;
		let other_offer = fixture.other.offers.recv().await.unwrap();
		let mut other = remote(&other_offer, &other_context).await;
		let sources = Rc::new(Sources::new(Deadline));
		let (commands, worker) = DirectCommands::new(
			crate::client::Deadline,
			fixture.commands.clone(),
			fixture.routes.receiver(),
			fixture.lines.receiver(),
			sources.clone(),
		);
		let task = tokio::task::spawn_local(worker.run());
		peer.delay.set(true);
		drop(
			commands
				.submit(operation(&fixture, "abandoned-reply"), &context, send("first"))
				.unwrap(),
		);
		let (mut answer, line) = peer.answers.recv().await.unwrap();
		assert!(
			pending(&fixture, "abandoned-reply"),
			"peer contact follows durable preparation"
		);
		let queued = commands
			.submit(operation(&fixture, "next-message"), &context, send("second"))
			.unwrap();
		commands
			.submit(operation(&fixture, "independent"), &other_context, send("other"))
			.unwrap()
			.wait()
			.await
			.unwrap();
		drop(fixture.events.next().await.unwrap());
		drop(other.events.next().await.unwrap());
		assert!(
			!pending(&fixture, "next-message"),
			"same-conversation command waits before ledger preparation"
		);
		answer.fulfill_value(&line.into()).unwrap();
		queued.wait().await.unwrap();
		assert!(!pending(&fixture, "abandoned-reply"));
		for expected in ["first", "second"] {
			assert_eq!(fixture.events.next().await.unwrap().line().unwrap().text, expected);
			assert_eq!(peer.events.next().await.unwrap().line().unwrap().text, expected);
		}
		peer.delay.set(true);
		let op = operation(&fixture, "uncertain-send");
		let uncertain = commands.submit(op.clone(), &context, send("uncertain")).unwrap();
		let (mut late, line) = peer.answers.recv().await.unwrap();
		let not_started = commands
			.submit(operation(&fixture, "queued-close"), &context, send("queued"))
			.unwrap();
		commands.close().await.unwrap();
		task.await.unwrap().unwrap();
		assert_eq!(uncertain.wait().await.unwrap_err().delivery, Delivery::Uncertain);
		assert_eq!(not_started.wait().await.unwrap_err().delivery, Delivery::NotSent);
		assert!(pending(&fixture, "uncertain-send"));
		assert!(!pending(&fixture, "queued-close"));
		let (resumed, worker) = DirectCommands::new(
			crate::client::Deadline,
			fixture.commands.clone(),
			fixture.routes.receiver(),
			fixture.lines.receiver(),
			sources.clone(),
		);
		let resumed_task = tokio::task::spawn_local(worker.run());
		assert!(resumed
			.submit(op, &context, send("uncertain"))
			.unwrap()
			.wait()
			.await
			.is_err());
		late.fulfill_value(&line.into()).unwrap();
		resumed.close().await.unwrap();
		resumed_task.await.unwrap().unwrap();
		// Restore actual files, not a synthesized effects document. The durable
		// pending operation remains visible and requires explicit resolution.
		let checkpoint = std::fs::read(fixture._temp.0.join("session.json")).unwrap();
		let effects = std::fs::read(fixture._temp.0.join("effects.json")).unwrap();
		let restored =
			rooms_application::session::state::SessionState::restore(&checkpoint, &effects, &CheckpointRoutes).unwrap();
		assert!(restored
			.pending_ids()
			.unwrap()
			.any(|id| id.text().as_str() == Some("uncertain-send")));

		let material = |text| {
			rooms_application::direct::operation::Command::Send { text, files: &[] }
				.material(rooms_application::direct::operation::Context {
					directory: context.directory().text(),
					conversation: context.conversation().text(),
					peer: context.peer().text(),
					registration: context.registration().as_str(),
				})
				.unwrap()
		};
		assert!(matches!(
			restored.inspect_ordinary(text("uncertain-send"), 0, &material("uncertain")),
			Err(rooms_application::session::state::Error::Unresolved)
		));
		assert!(matches!(
			restored.inspect_ordinary(text("abandoned-reply"), 0, &material("first")),
			Ok(rooms_application::session::state::Inspection::Committed(_))
		));
		peer.owner.close_files().await.unwrap();
		other.owner.close_files().await.unwrap();
		dispatch.close().await.unwrap();
		dispatcher.await.unwrap().unwrap();
		drop((commands, resumed, peer, other, offer, other_offer, sources));
		fixture.close().await;
	})
	.await;
}

#[tokio::test]
async fn durable_preparation_cancels_owned_reads_and_refuses_another_session_owner() {
	deadline(async {
		let mut fixture = Fixture::new("durable-capture-close").await;
		let other_fixture = Fixture::new("durable-wrong-owner").await;
		let (dispatch, worker, mut outcomes) = fixture.dispatcher();
		let dispatcher = tokio::task::spawn_local(worker.run());
		fixture.arrival.notify("mintInboxFor").await;
		let context = published(&mut outcomes).await;
		let offer = fixture.peer.offers.recv().await.unwrap();
		let mut peer = remote(&offer, &context).await;
		let sources = Rc::new(Sources::new(Deadline));
		let (wrong, wrong_worker) = DirectCommands::new(
			crate::client::Deadline,
			other_fixture.commands.clone(),
			fixture.routes.receiver(),
			fixture.lines.receiver(),
			sources.clone(),
		);
		assert!(wrong
			.submit(operation(&other_fixture, "wrong-session"), &context, send("wrong"))
			.err()
			.unwrap()
			.contains("another durable session"));
		drop((wrong, wrong_worker));
		other_fixture.close().await;
		let (commands, worker) = DirectCommands::new(
			crate::client::Deadline,
			fixture.commands.clone(),
			fixture.routes.receiver(),
			fixture.lines.receiver(),
			sources.clone(),
		);
		let task = tokio::task::spawn_local(worker.run());
		struct Slow(Rc<Cell<bool>>, Rc<tokio::sync::Notify>);
		struct Active(Rc<Cell<bool>>);
		impl Drop for Active {
			fn drop(&mut self) {
				self.0.set(false);
			}
		}
		impl Reader for Slow {
			fn read(&self, _: usize, _: usize) -> Pin<Box<dyn Future<Output = Result<Vec<u8>, String>>>> {
				self.0.set(true);
				self.1.notify_one();
				let guard = Active(self.0.clone());
				Box::pin(async move {
					let _guard = guard;
					core::future::pending().await
				})
			}
		}
		let active = Rc::new(Cell::new(false));
		let started = Rc::new(tokio::sync::Notify::new());
		let capture = commands
			.submit(
				operation(&fixture, "capture-cancel"),
				&context,
				Action::Send {
					text: "slow".into(),
					files: vec![Source::reader(
						FileDescription::new("slow".into(), "text/plain".into(), 1, 0, 0).unwrap(),
						Slow(active.clone(), started.clone()),
					)],
				},
			)
			.unwrap();
		started.notified().await;
		assert!(active.get());
		let mut closing = Box::pin(commands.close());
		assert!(closing
			.as_mut()
			.poll(&mut Context::from_waker(Waker::noop()))
			.is_pending());
		drop(closing);
		assert!(commands
			.submit(operation(&fixture, "after-close"), &context, send("closed"))
			.is_err());
		commands.close().await.unwrap();
		task.await.unwrap().unwrap();
		let failure = capture.wait().await.unwrap_err();
		assert_eq!(failure.delivery, Delivery::NotSent);
		assert_eq!(
			failure.ledger,
			crate::session_runtime::direct_commands::Ledger::Unrecorded
		);
		assert!(!active.get() && !pending(&fixture, "capture-cancel"));
		assert!(Box::pin(peer.events.next())
			.as_mut()
			.poll(&mut Context::from_waker(Waker::noop()))
			.is_pending());
		peer.owner.close_files().await.unwrap();
		dispatch.close().await.unwrap();
		dispatcher.await.unwrap().unwrap();
		drop((commands, peer, offer, sources));
		fixture.close().await;
	})
	.await;
}
