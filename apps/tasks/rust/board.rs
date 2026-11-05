//! A small client for the tasks board, built on glowcap actors.
//!
//! The board is a secret-named capability with two lists, "To do" first and
//! "Done" second. Every change is a receipt-backed call: ask the target for a
//! fresh `mutation-sequence`, then `mutate` with that number, so a retried
//! change applies once. Adding a task returns the task, and `done` moves that
//! task. A watcher reports whether anything on the board changed since its last
//! look, and `stop` frees the board's observation context. The glowcap `Session` owns the peer on a background
//! task, so the application above sees only the board methods.
//!
//!   let board = Board::join(&tcp::locator("127.0.0.1", 9099), &name).await?;
//!   let mut watcher = board.watch().await?;
//!   let task = board.add("buy groceries").await?;
//!   board.done(&task).await?;
//!   let lists = board.lists().await?;
//!   let changed = watcher.changed().await?;
//!   watcher.stop().await?;
//!   board.leave().await?;

use crate::interface;
use std::rc::Rc;
use tokio::sync::Mutex;

use glowcap::{ConnectOptions, Locator, PendingWork, Ref, Runtime, RuntimeConfig, Session, tcp};

/// One list on the board: its name and the text of each task in order.
#[derive(Debug, Clone)]
pub struct TaskList {
	pub name: String,
	pub tasks: Vec<String>,
}

/// A task on the board, named by its capability.
pub struct Task(Ref);

/// Reports whether the board changed since the last look.
pub struct Watcher {
	session: Rc<Session>,
	receiver: Ref,
	canceller: Ref,
	cursor: Vec<u8>,
}

impl Watcher {
	/// Poll from the stored cursor, keep the reply's cursor, and return whether the board changed.
	async fn poll(&mut self) -> Result<bool, String> {
		// The optional owned cursor is the one input snapshot. Keep the current
		// cursor until the generated decoder has checked the entire reply.
		let cursor = (!self.cursor.is_empty()).then(|| self.cursor.clone());
		let interface::LoamObservation(cursor, _description, _reset, changed, _notices) =
			interface::receiver_poll(&self.session, &self.receiver, cursor)
				.map_err(|error| format!("poll: {error}"))?
				.await
				.map_err(|error| format!("poll: {error}"))?;
		self.cursor = cursor;
		Ok(changed)
	}

	/// Whether anything on the board changed since the previous look.
	pub async fn changed(&mut self) -> Result<bool, String> {
		self.poll().await
	}

	/// Close the board's observation context. Call it once when done watching.
	pub async fn stop(&self) -> Result<(), String> {
		interface::cancel(&self.session, &self.canceller)
			.await
			.map(|_| ())
			.map_err(|e| format!("cancel: {e}"))
	}
}

/// A membership in a task board: the connection plus the board and its first two lists.
pub struct Board {
	session: Rc<Session>,
	root: Ref,
	todo: Ref,
	done: Ref,
	runtime: Runtime,
	/// One inline mutex orders mutations through their reply; reads stay independent.
	/// Waiting futures own queue entries, so dropping one cannot wedge the gate.
	mutations: Mutex<()>,
}

impl Board {
	/// Join the board named `name` at `locator`. Call inside a `LocalSet` (the peer is `!Send`).
	pub async fn join(locator: &Locator, name: &str) -> Result<Board, String> {
		let runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
			.await
			.map_err(|e| format!("runtime: {e}"))?;
		Self::join_with_runtime(runtime, locator, name).await
	}

	/// Join with a configured Runtime, transferring its lifetime to the Board.
	pub async fn join_with_runtime(runtime: Runtime, locator: &Locator, name: &str) -> Result<Board, String> {
		let session = Rc::new(
			runtime
				.connect(locator, ConnectOptions::default())
				.await
				.map_err(|e| format!("connect: {e}"))?,
		);
		let board = session.fetch(name).await.map_err(|e| format!("fetch board: {e}"))?;
		let mut lists = Vec::new();
		for at in 0..2i64 {
			let pending = interface::board_list(&session, &board, at).map_err(|error| format!("list {at}: {error}"))?;
			lists.push(pending.await.map_err(|error| format!("list {at}: {error}"))?);
		}
		let done = lists.pop().ok_or("missing done list")?;
		let todo = lists.pop().ok_or("missing to do list")?;
		Ok(Board {
			session,
			root: board,
			todo,
			done,
			runtime,
			mutations: Mutex::new(()),
		})
	}

	/// Add a task to "To do" and return the new task.
	pub async fn add(&self, text: &str) -> Result<Task, String> {
		let _mutation = self.mutations.lock().await;
		interface::add(self.session.clone(), self.todo.clone(), text)
			.await
			.map(Task)
			.map_err(|error| format!("add: {error}"))
	}

	/// Move `task` from "To do" to the end of "Done".
	pub async fn done(&self, task: &Task) -> Result<(), String> {
		let _mutation = self.mutations.lock().await;
		interface::move_task(
			self.session.clone(),
			self.todo.clone(),
			(&task.0).into(),
			(&self.done).into(),
		)
		.await
		.map(|_| ())
		.map_err(|error| format!("move: {error}"))
	}

	/// Start watching the board for changes.
	pub async fn watch(&self) -> Result<Watcher, String> {
		let mutation = self.mutations.lock().await;
		let interface::LoamRegistration(receiver, canceller) =
			interface::observe(self.session.clone(), self.root.clone())
				.await
				.map_err(|error| format!("observe: {error}"))?;
		drop(mutation);
		let mut watcher = Watcher {
			session: Rc::clone(&self.session),
			receiver,
			canceller,
			cursor: Vec::new(),
		};
		if let Err(primary) = watcher.poll().await {
			// Observe already committed a durable context. Dropping its refs
			// does not retire it, so cancel before returning the poll failure.
			return match watcher.stop().await {
				Ok(()) => Err(primary),
				Err(cleanup) => Err(format!("{primary}; watcher cleanup failed: {cleanup}")),
			};
		}
		Ok(watcher)
	}

	/// Read both lists, "To do" first.
	pub async fn lists(&self) -> Result<Vec<TaskList>, String> {
		let mut lists = Vec::new();
		for list in [&self.todo, &self.done] {
			let name = interface::list_name(&self.session, list)
				.await
				.map_err(|error| format!("list name: {error}"))?;
			let count = interface::list_count(&self.session, list)
				.await
				.map_err(|error| format!("list count: {error}"))?;
			let mut tasks = Vec::new();
			for at in 0..count {
				let pending =
					interface::list_task(&self.session, list, at).map_err(|error| format!("task: {error}"))?;
				let task = pending.await.map_err(|error| format!("task: {error}"))?;
				tasks.push(
					interface::task_text(&self.session, &task)
						.await
						.map_err(|error| format!("task text: {error}"))?,
				);
			}
			lists.push(TaskList { name, tasks });
		}
		Ok(lists)
	}

	pub async fn leave(self) -> Result<(), String> {
		let session_error = self.session.close(PendingWork::Cancel).await.err();
		let runtime_error = self.runtime.close(PendingWork::Cancel).await.err();
		match (session_error, runtime_error) {
			(None, None) => Ok(()),
			(Some(error), None) => Err(format!("leave session: {error}")),
			(None, Some(error)) => Err(format!("leave runtime: {error}")),
			(Some(session), Some(runtime)) => Err(format!("leave session: {session}; leave runtime: {runtime}")),
		}
	}
}
