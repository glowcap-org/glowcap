use rooms_runtime::session::commands::*;
mod scopes;
use crate::documents::{SessionDocuments, SessionOwners};
use crate::session_state::{DurableSession, LoadStatus, SessionView};
use rooms_application::{
	grants::Access,
	session::checkpoint::reconciliation::{RoomContext, Text},
};
use rooms_application::{
	session::{
		checkpoint::{
			commands::{Command, Facts},
			reconciliation::Fact,
		},
		state::Change,
	},
	text::DocumentText,
};
use std::rc::Rc;
use std::{
	cell::RefCell,
	path::PathBuf,
	sync::atomic::{AtomicU64, Ordering},
};
use tokio::sync::{mpsc, oneshot};
static NEXT: AtomicU64 = AtomicU64::new(0);
struct Temp(PathBuf);
impl Temp {
	fn new() -> Self {
		let p = std::env::temp_dir().join(format!(
			"rooms-command-worker-{}-{}",
			std::process::id(),
			NEXT.fetch_add(1, Ordering::Relaxed)
		));
		std::fs::create_dir(&p).unwrap();
		Self(p)
	}
}
impl Drop for Temp {
	fn drop(&mut self) {
		std::fs::remove_dir_all(&self.0).unwrap();
	}
}
async fn owner(path: &std::path::Path) -> DurableSession {
	let SessionOwners {
		state,
		grants,
		bridge_secrets,
	} = SessionDocuments::open(path).await.unwrap().into_owners();
	drop(grants);
	drop(bridge_secrets);
	state
}
fn text<const N: usize, const NONEMPTY: bool>(raw: &str) -> Text<N, NONEMPTY> {
	Text::new(raw.into()).unwrap()
}
#[derive(Default)]
struct Trace {
	revisions: Vec<u64>,
	issues: Vec<bool>,
}
struct Events {
	trace: Rc<RefCell<Trace>>,
	issues: Option<mpsc::Sender<bool>>,
}
impl SessionEvents for Events {
	async fn preparing(
		&mut self,
		_checkpoint: &rooms_application::session::checkpoint::Checkpoint,
	) -> Result<impl Sized + 'static, rooms_runtime::Error> {
		Ok(())
	}

	fn facts(&self) -> impl Facts {}
	fn changed(&mut self, change: Change, view: &SessionView) {
		assert_eq!(view.read(|s| s.revision()).unwrap().unwrap(), change.revision);
		self.trace.borrow_mut().revisions.push(change.revision);
	}
	fn reconciliation_issue(&mut self, _: &Fact, error: Option<&str>) {
		self.trace.borrow_mut().issues.push(error.is_some());
		if let Some(tx) = &self.issues {
			tx.try_send(error.is_some()).unwrap();
		}
	}
}
fn events() -> (Events, Rc<RefCell<Trace>>) {
	let trace = Rc::new(RefCell::new(Trace::default()));
	(
		Events {
			trace: trace.clone(),
			issues: None,
		},
		trace,
	)
}
fn reached() -> Fact {
	Fact::DirectoryReached {
		directory: text("ocapn://directory.id"),
		locator: text("ocapn://directory.id"),
	}
}
fn join() -> Vec<DocumentText> {
	vec![serde_json::json!({"locator":"ocapn://directory.id","nick":"ada","conversation":{
		"kind":"room","id":"room","directory":"ocapn://directory.id","name":"general","held":false,"standing":null,"draft":""}}).to_string().into()]
}
async fn command(
	handle: &SessionCommands,
	id: &str,
	base: u64,
	command: Command,
	args: Vec<DocumentText>,
) -> Result<u64, rooms_runtime::Error> {
	handle
		.prepare_command(text(id), base, command, args)
		.unwrap()
		.send()
		.unwrap()
		.wait()
		.await
}

#[tokio::test]
async fn admission_accounts_for_capacity_and_reserves_room_for_commands() {
	let temp = Temp::new();
	let (handle, worker) = SessionCommands::open(owner(&temp.0).await, rooms_platform::HostPlatform)
		.await
		.unwrap();
	let mut facts = Vec::new();
	for _ in 0..MAX_PENDING_FACTS {
		facts.push(handle.prepare_fact(reached()).unwrap());
	}
	assert!(matches!(handle.prepare_fact(reached()), Err(AdmissionError::Full)));
	let mut commands = Vec::new();
	for _ in MAX_PENDING_FACTS..MAX_PENDING {
		commands.push(
			handle
				.prepare_command(text("id"), 0, Command::SetStanding, vec!["x".into()])
				.unwrap(),
		);
	}
	assert!(matches!(
		handle.prepare_command(text("extra"), 0, Command::SetStanding, vec!["x".into()]),
		Err(AdmissionError::Full)
	));
	drop(commands.pop());
	commands.push(
		handle
			.prepare_command(text("replacement"), 0, Command::SetStanding, vec!["x".into()])
			.unwrap(),
	);
	drop(commands);
	drop(facts);
	let mut spare = String::with_capacity(MAX_RETAINED_BYTES);
	spare.push('x');
	assert!(matches!(
		handle.prepare_command(text("bytes"), 0, Command::SetStanding, vec![spare.into()]),
		Err(AdmissionError::Full)
	));
	let mut spare = String::with_capacity(MAX_FACT_BYTES);
	spare.push_str("room");
	assert!(matches!(
		handle.prepare_scoped_fact(
			Fact::RoomReconnect {
				context: room_context(),
				conversation: Text::new(spare.into()).unwrap(),
				connected: true
			},
			&FactScope::new()
		),
		Err(AdmissionError::Full)
	));
	let ticket = handle
		.prepare_command(text("unsent"), 0, Command::SetStanding, vec!["never".into()])
		.unwrap();
	let (events, trace) = events();
	let (run, close) = tokio::join!(worker.run(events), handle.close());
	assert!(run.is_ok());
	assert!(close.is_ok());
	assert!(matches!(ticket.send(), Err(AdmissionError::Closed)));
	assert!(trace.borrow().revisions.is_empty());
}

#[tokio::test]
async fn sent_commands_drain_even_when_their_callers_stop_observing() {
	let temp = Temp::new();
	let (handle, worker) = SessionCommands::open(owner(&temp.0).await, rooms_platform::HostPlatform)
		.await
		.unwrap();
	let view = handle.view();
	let (events, trace) = events();
	let first = handle
		.prepare_command(text("first"), 0, Command::SetStanding, vec!["first".into()])
		.unwrap()
		.send()
		.unwrap();
	drop(first);
	let second = handle
		.prepare_command(text("second"), 1, Command::SetStanding, vec!["second".into()])
		.unwrap()
		.send()
		.unwrap();
	let (run, close, second) = tokio::join!(worker.run(events), handle.close(), second.wait());
	assert!(run.is_ok());
	assert!(close.is_ok());
	assert_eq!(second.unwrap(), 2);
	assert_eq!(trace.borrow().revisions, [1, 2]);
	assert!(view.read(|s| s.revision()).is_err());
	let mut restored = owner(&temp.0).await;
	assert!(matches!(restored.load().await.unwrap(), LoadStatus::Ready));
	let raw = restored
		.state()
		.unwrap()
		.checkpoint()
		.unwrap()
		.encode_for(Access::Admin)
		.unwrap();
	assert_eq!(
		serde_json::from_str::<serde_json::Value>(&raw).unwrap()["standing"],
		"second"
	);
}

#[tokio::test]
async fn open_finishes_returned_authority_before_exposing_its_view() {
	use rooms_application::session::checkpoint::commands::results;
	use rooms_glowcap::routes::CheckpointRoutes;
	let temp = Temp::new();
	let mut state = owner(&temp.0).await;
	assert!(matches!(state.load().await.unwrap(), LoadStatus::Ready));
	state
		.command(text("join"), 0, Command::JoinRoom, &join(), &())
		.await
		.unwrap();
	let plan = results::Command::EnsureRoomLink
		.prepare(
			state.state().unwrap().checkpoint().unwrap(),
			&["room".into()],
			&CheckpointRoutes,
			false,
		)
		.unwrap();
	let material = "room result".into();
	let id = text("result");
	state.prepare_plan(id.clone(), 1, &material, &plan).await.unwrap();
	let link = glowcap::format_sturdyref(
		&glowcap::parse_locator("ocapn://directory.id").unwrap(),
		b"room-link",
		glowcap::CaptpVersion::V1_0,
	)
	.unwrap();
	state
		.record_result(
			&id,
			Some(&material),
			text(&serde_json::json!({"roomLink":link}).to_string()),
		)
		.await
		.unwrap();
	drop(state);
	let (handle, worker) = SessionCommands::open(owner(&temp.0).await, rooms_platform::HostPlatform)
		.await
		.unwrap();
	let view = handle.view();
	view.read(|state| {
		assert_eq!(state.revision().unwrap(), 2);
		assert_eq!(state.pending_ids().unwrap().len(), 0);
		let checkpoint: serde_json::Value =
			serde_json::from_str(&state.checkpoint().unwrap().encode_for(Access::Admin).unwrap()).unwrap();
		assert_eq!(checkpoint["conversations"][0]["link"], link);
	})
	.unwrap();
	let (events, trace) = events();
	let (run, close) = tokio::join!(worker.run(events), handle.close());
	assert!(run.is_ok());
	assert!(close.is_ok());
	assert!(
		trace.borrow().revisions.is_empty(),
		"startup completed before observers were published"
	);
}

async fn hold_clock() -> (std::sync::mpsc::Sender<()>, tokio::task::JoinHandle<()>) {
	// A pending blocking worker prevents Tokio's paused clock from advancing
	// automatically during filesystem work. Tests advance retry time explicitly.
	let (release, wait) = std::sync::mpsc::channel();
	let (started, running) = oneshot::channel();
	let task = tokio::task::spawn_blocking(move || {
		started.send(()).unwrap();
		wait.recv().unwrap();
	});
	running.await.unwrap();
	(release, task)
}
#[tokio::test(start_paused = true)]
async fn failed_facts_retain_order_while_commands_can_resolve_the_conflict() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let (release, clock) = hold_clock().await;
			let temp = Temp::new();
			let (handle, worker) = SessionCommands::open(owner(&temp.0).await, rooms_platform::HostPlatform)
				.await
				.unwrap();
			let (mut events, trace) = events();
			let (issue, mut issues) = mpsc::channel(16);
			events.issues = Some(issue);
			let task = tokio::task::spawn_local(worker.run(events));
			assert_eq!(command(&handle, "join", 0, Command::JoinRoom, join()).await.unwrap(), 1);
			let bad = Fact::RoomAuthorityAcquired {
				context: handle
					.view()
					.read(|state| RoomContext::capture(state.checkpoint().unwrap().rooms().next().unwrap()))
					.unwrap(),
				conversation: text("room"),
				room_link: text("broken"),
				manager_link: text("broken"),
			};
			let scope = FactScope::new();
			let first = handle.prepare_scoped_fact(bad, &scope).unwrap().send().unwrap();
			assert!(first.wait().await.is_err());
			assert_eq!(issues.recv().await, Some(true));
			let later = handle.prepare_fact(reached()).unwrap().send().unwrap();
			let mut later = Box::pin(later.wait());
			assert_eq!(
				command(&handle, "leave", 1, Command::LeaveConversation, vec!["room".into()])
					.await
					.unwrap(),
				2
			);
			assert!(
				std::future::poll_fn(|cx| std::task::Poll::Ready(std::future::Future::poll(later.as_mut(), cx)))
					.await
					.is_pending()
			);
			tokio::time::advance(std::time::Duration::from_secs(1)).await;
			assert_eq!(issues.recv().await, Some(false));
			later.await.unwrap();
			assert_eq!(issues.recv().await, Some(false));
			assert_eq!(
				trace.borrow().revisions,
				[1, 2, 2],
				"reconciliation retains command revision"
			);
			assert!(handle.close().await.is_ok());
			assert!(task.await.unwrap().is_ok());
			release.send(()).unwrap();
			clock.await.unwrap();
		})
		.await;
}

#[tokio::test(start_paused = true)]
async fn retries_back_off_and_close_wakes_without_losing_unsynchronized_status() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let (release, clock) = hold_clock().await;
			let temp = Temp::new();
			let (handle, worker) = SessionCommands::open(owner(&temp.0).await, rooms_platform::HostPlatform)
				.await
				.unwrap();
			let (mut events, _) = events();
			let (issue, mut issues) = mpsc::channel(16);
			events.issues = Some(issue);
			let task = tokio::task::spawn_local(worker.run(events));
			let fact = Fact::DirectAccepted {
				conversation: text("direct"),
				directory: text("missing"),
				peer: text("peer"),
				registration: text("bad"),
			};
			let scope = FactScope::new();
			assert!(
				handle
					.prepare_scoped_fact(fact, &scope)
					.unwrap()
					.send()
					.unwrap()
					.wait()
					.await
					.is_err()
			);
			assert_eq!(issues.recv().await, Some(true));
			let queued: Vec<_> = (1..MAX_PENDING_FACTS)
				.map(|_| handle.prepare_fact(reached()).unwrap().send().unwrap())
				.collect();
			assert!(
				matches!(handle.prepare_fact(reached()), Err(AdmissionError::Full)),
				"a failed first reply must not release fact custody"
			);
			assert_eq!(
				command(&handle, "during-retry", 0, Command::SetStanding, vec!["working".into()])
					.await
					.unwrap(),
				1
			);
			for seconds in [1, 2, 4, 8, 16, 30, 30] {
				tokio::time::advance(std::time::Duration::from_millis(seconds * 1000 - 1)).await;
				tokio::task::yield_now().await;
				assert!(issues.try_recv().is_err(), "retry fired before its delay");
				tokio::time::advance(std::time::Duration::from_millis(1)).await;
				assert_eq!(issues.recv().await, Some(true));
			}
			let closed = handle.close().await.unwrap_err();
			assert!(matches!(closed, rooms_runtime::Error::Storage(_)));
			let closed_text = closed.to_string();
			assert!(closed_text.contains("32 unsynchronized facts"));
			for reply in queued {
				assert!(reply.wait().await.is_err());
			}
			assert_eq!(task.await.unwrap().unwrap_err().to_string(), closed_text);
			assert_eq!(handle.closed().await.unwrap_err().to_string(), closed_text);
			release.send(()).unwrap();
			clock.await.unwrap();
		})
		.await;
}

#[tokio::test]
async fn dropping_all_handles_does_not_leave_unsent_admissions_holding_the_worker_open() {
	let temp = Temp::new();
	let (handle, worker) = SessionCommands::open(owner(&temp.0).await, rooms_platform::HostPlatform)
		.await
		.unwrap();
	let ticket = handle
		.prepare_command(text("unsent"), 0, Command::SetStanding, vec!["never".into()])
		.unwrap();
	drop(handle);
	let (events, _) = events();
	assert!(worker.run(events).await.is_ok());
	assert!(matches!(ticket.send(), Err(AdmissionError::Closed)));
}

#[test]
fn worker_cancellation_keeps_disk_custody_and_counts_the_inflight_request() {
	tokio::runtime::Builder::new_current_thread()
		.enable_all()
		.max_blocking_threads(1)
		.build()
		.unwrap()
		.block_on(tokio::task::LocalSet::new().run_until(async {
			let temp = Temp::new();
			let (handle, worker) = SessionCommands::open(owner(&temp.0).await, rooms_platform::HostPlatform)
				.await
				.unwrap();
			let view = handle.view();
			let (release, blocker) = hold_clock().await;
			let (events, trace) = events();
			let mut task = Box::pin(worker.run(events));
			let first = handle
				.prepare_command(text("first"), 0, Command::SetStanding, vec!["committed".into()])
				.unwrap()
				.send()
				.unwrap();
			// Poll the worker through admission into the blocked disk operation.
			// This proves an in-flight command without inspecting its queue.
			assert!(
				std::future::poll_fn(|cx| std::task::Poll::Ready(std::future::Future::poll(task.as_mut(), cx)))
					.await
					.is_pending()
			);
			assert_eq!(view.read(|s| s.revision()).unwrap().unwrap(), 0);
			let queued: Vec<_> = (1..MAX_PENDING)
				.map(|at| {
					handle
						.prepare_command(
							text(&format!("queued-{at}")),
							at as u64,
							Command::SetStanding,
							vec!["queued".into()],
						)
						.unwrap()
						.send()
						.unwrap()
				})
				.collect();
			assert!(
				matches!(
					handle.prepare_command(text("overflow"), 64, Command::SetStanding, vec!["extra".into()]),
					Err(AdmissionError::Full)
				),
				"the active request still owns its budget"
			);
			drop(task);
			assert!(handle.closed().await.is_err());
			assert!(first.wait().await.is_err());
			for reply in queued {
				assert!(reply.wait().await.is_err());
			}
			assert!(view.read(|s| s.revision()).is_err());
			assert!(trace.borrow().revisions.is_empty());
			let lock = std::fs::OpenOptions::new()
				.read(true)
				.write(true)
				.open(temp.0.join(".rooms-session.lock"))
				.unwrap();
			assert_eq!(
				std::io::Error::from(lock.try_lock().unwrap_err()).kind(),
				std::io::ErrorKind::WouldBlock
			);
			release.send(()).unwrap();
			blocker.await.unwrap();
			tokio::time::timeout(std::time::Duration::from_secs(2), async {
				loop {
					match lock.try_lock() {
						Ok(()) => break,
						Err(error) => {
							assert_eq!(std::io::Error::from(error).kind(), std::io::ErrorKind::WouldBlock);
							tokio::task::yield_now().await;
						}
					}
				}
			})
			.await
			.unwrap();
			drop(lock);
			let mut restored = owner(&temp.0).await;
			assert!(matches!(restored.load().await.unwrap(), LoadStatus::Ready));
			assert_eq!(restored.state().unwrap().revision().unwrap(), 1);
			assert_eq!(
				restored
					.command(text("first"), 999, Command::SetStanding, &["committed".into()], &())
					.await
					.unwrap(),
				(1, None)
			);
		}));
}

mod room_links;
mod transactions;

fn room_context() -> RoomContext {
	use rooms_application::session::checkpoint::RoomIntent;
	RoomContext::capture(RoomIntent {
		id: &text("room"),
		directory: &text("ocapn://directory.id"),
		name: &text("general"),
		held: false,
		reconnect: None,
		link: None,
		manager: None,
		steward: None,
		publication_id: None,
		bridge: None,
	})
}
