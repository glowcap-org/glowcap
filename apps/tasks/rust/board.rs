//! A small, friendly client for the tasks board, built on glowcap actors.
//!
//! On the connection API this is barely a layer: connect, fetch the board by
//! name, publish a watcher, and call `add`/`done`/`list`. The glowcap
//! `Session` owns the peer on a background task, so the application above sees
//! only the board methods.
//!
//!   let board = Board::join(&tcp::locator("127.0.0.1", 9099)).await?;
//!   let id = board.add("buy groceries").await?;
//!   board.done(id).await?;
//!   let tasks = board.list().await?;
//!   board.leave().await;

use std::rc::Rc;

use glowcap::{Argument, ConnectOptions, Locator, PendingWork, Runtime, RuntimeConfig, Session, tcp};

const BOARD: &str = "board";

#[derive(Debug, Clone)]
pub struct Task {
	pub id: i64,
	pub text: String,
	pub completed: bool,
}

fn parse_task(arg: &Argument) -> Option<Task> {
	let fields = arg.as_list()?;
	if fields.len() < 3 {
		return None;
	}
	Some(Task {
		id: fields[0].as_i64()?,
		text: fields[1].as_str()?.to_string(),
		completed: fields[2].as_bool().unwrap_or(false),
	})
}

fn parse_snapshot(arg: &Argument) -> Vec<Task> {
	arg.as_list()
		.unwrap_or_default()
		.iter()
		.filter_map(parse_task)
		.collect()
}

/// A membership in a task board: the connection plus the board capability.
pub struct Board {
	session: Rc<Session>,
	board: glowcap::Ref,
	runtime: Runtime,
}

impl Board {
	/// Join the board at `locator`. Call inside a `LocalSet` (the peer is `!Send`).
	pub async fn join(locator: &Locator) -> Result<Board, String> {
		let runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
			.await
			.map_err(|e| format!("runtime: {e:?}"))?;
		let session = Rc::new(
			runtime
				.connect(locator, ConnectOptions::default())
				.await
				.map_err(|e| format!("connect: {e:?}"))?,
		);
		let board = session.fetch(BOARD).await.map_err(|e| format!("fetch board: {e:?}"))?;

		// Watch the board so changes are pushed to us (we ignore the updates in
		// this one-shot client, but it exercises the capability callback).
		let watcher = session
			.spawn(|verb, _args| {
				if verb != "update" {
					return Err(format!("watcher has no method {verb}"));
				}
				Ok(Argument::Void)
			})
			.map_err(|e| format!("spawn watcher: {e:?}"))?;
		session
			.send(&board, "watch", &[(&watcher).into()])
			.await
			.map_err(|e| format!("watch: {e:?}"))?;

		Ok(Board {
			session,
			board,
			runtime,
		})
	}

	pub async fn add(&self, text: &str) -> Result<i64, String> {
		match self.session.send(&self.board, "add", &[text.into()]).await {
			Ok(reply) => reply.as_i64().ok_or_else(|| "unexpected reply to add".to_string()),
			Err(e) => Err(format!("add: {e:?}")),
		}
	}

	pub async fn done(&self, id: i64) -> Result<(), String> {
		self.session
			.send(&self.board, "done", &[id.into()])
			.await
			.map(|_| ())
			.map_err(|e| format!("done: {e:?}"))
	}

	pub async fn list(&self) -> Result<Vec<Task>, String> {
		let result = self
			.session
			.send(&self.board, "list", &[])
			.await
			.map_err(|e| format!("list: {e:?}"))?;
		Ok(parse_snapshot(&result))
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
