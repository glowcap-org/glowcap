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

use glowcap::{Argument, ConnectOptions, Locator, PendingWork, Ref, Runtime, RuntimeConfig, Session, tcp};

/// One list on the board: its name and the text of each task in order.
#[derive(Debug, Clone)]
pub struct TaskList {
	pub name: String,
	pub tasks: Vec<String>,
}

fn capability(reply: &Argument, what: &str) -> Result<Ref, String> {
	Ref::try_from(reply).map_err(|_| format!("{what} was not a capability"))
}

fn integer(reply: &Argument, what: &str) -> Result<i64, String> {
	reply.as_i64().ok_or_else(|| format!("{what} was not an integer"))
}

fn text(reply: &Argument, what: &str) -> Result<String, String> {
	reply
		.as_str()
		.map(str::to_string)
		.ok_or_else(|| format!("{what} was not text"))
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
		let args: Vec<Argument> = if self.cursor.is_empty() {
			Vec::new()
		} else {
			vec![self.cursor.as_slice().into()]
		};
		let reply = self
			.session
			.send(&self.receiver, "poll", &args)
			.await
			.map_err(|e| format!("poll: {e:?}"))?;
		let observation = || "the watcher sent no observation".to_string();
		let Argument::Tagged { value, .. } = &reply else {
			return Err(observation());
		};
		if value.len() != 5 {
			return Err(observation());
		}
		// Loam's `access:observation` record, see docs/loam/access-observation.md:
		// the cursor comes first and the fourth field is whether anything changed.
		let cursor = value[0].as_bytes().ok_or_else(observation)?.to_vec();
		let changed = value[3].as_bool().ok_or_else(observation)?;
		self.cursor = cursor;
		Ok(changed)
	}

	/// Whether anything on the board changed since the previous look.
	pub async fn changed(&mut self) -> Result<bool, String> {
		self.poll().await
	}

	/// Close the board's observation context. Call it once when done watching.
	pub async fn stop(&self) -> Result<(), String> {
		let closed = self
			.session
			.send(&self.canceller, "cancel", &[])
			.await
			.map_err(|e| format!("cancel: {e:?}"))?;
		closed
			.as_bool()
			.map(|_| ())
			.ok_or_else(|| "cancelling the watcher returned no boolean".to_string())
	}
}

/// A membership in a task board: the connection plus the board and its first two lists.
pub struct Board {
	session: Rc<Session>,
	root: Ref,
	todo: Ref,
	done: Ref,
	runtime: Runtime,
}

impl Board {
	/// Join the board named `name` at `locator`. Call inside a `LocalSet` (the peer is `!Send`).
	pub async fn join(locator: &Locator, name: &str) -> Result<Board, String> {
		let runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
			.await
			.map_err(|e| format!("runtime: {e:?}"))?;
		let session = Rc::new(
			runtime
				.connect(locator, ConnectOptions::default())
				.await
				.map_err(|e| format!("connect: {e:?}"))?,
		);
		let board = session.fetch(name).await.map_err(|e| format!("fetch board: {e:?}"))?;
		let mut lists = Vec::new();
		for at in 0..2i64 {
			let reply = session
				.send(&board, "list", &[at.into()])
				.await
				.map_err(|e| format!("list {at}: {e:?}"))?;
			lists.push(capability(&reply, "list")?);
		}
		let done = lists.pop().ok_or("missing done list")?;
		let todo = lists.pop().ok_or("missing to do list")?;
		Ok(Board {
			session,
			root: board,
			todo,
			done,
			runtime,
		})
	}

	async fn call(&self, target: &Ref, verb: &str, args: &[Argument]) -> Result<Argument, String> {
		self.session
			.send(target, verb, args)
			.await
			.map_err(|e| format!("{verb}: {e:?}"))
	}

	/// One change with a fresh sequence number, so a retry applies once.
	async fn mutate(&self, target: &Ref, args: Vec<Argument>) -> Result<Argument, String> {
		let seq = self.call(target, "mutation-sequence", &[]).await?;
		let mut wrapped = vec![seq];
		wrapped.extend(args);
		self.call(target, "mutate", &wrapped).await
	}

	/// Add a task to "To do" and return the new task.
	pub async fn add(&self, text: &str) -> Result<Task, String> {
		interface::add(self.session.clone(), self.todo.clone(), text)
			.await
			.map(Task)
			.map_err(|error| format!("add: {error:?}"))
	}

	/// Move `task` from "To do" to the end of "Done".
	pub async fn done(&self, task: &Task) -> Result<(), String> {
		self.mutate(&self.todo, vec!["move".into(), (&task.0).into(), (&self.done).into()])
			.await
			.map(|_| ())
	}

	/// Start watching the board for changes.
	pub async fn watch(&self) -> Result<Watcher, String> {
		let reply = self.mutate(&self.root, vec!["observe".into()]).await?;
		let [receiver, canceller, ..] = reply.as_list().ok_or("watching returned no receiver")? else {
			return Err("watching returned no canceller".to_string());
		};
		let mut watcher = Watcher {
			session: Rc::clone(&self.session),
			receiver: capability(receiver, "watch receiver")?,
			canceller: capability(canceller, "watch canceller")?,
			cursor: Vec::new(),
		};
		watcher.poll().await?;
		Ok(watcher)
	}

	/// Read both lists, "To do" first.
	pub async fn lists(&self) -> Result<Vec<TaskList>, String> {
		let mut lists = Vec::new();
		for list in [&self.todo, &self.done] {
			let name = text(&self.call(list, "name", &[]).await?, "list name")?;
			let count = integer(&self.call(list, "count", &[]).await?, "list count")?;
			let mut tasks = Vec::new();
			for at in 0..count {
				let task = capability(&self.call(list, "task", &[at.into()]).await?, "task")?;
				tasks.push(text(&self.call(&task, "text", &[]).await?, "task text")?);
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
