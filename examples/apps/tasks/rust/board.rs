//! A small, friendly client for the tasks board, built on pancake actors.
//!
//! On the connection API this is barely a layer: connect, fetch the board by
//! name, publish a watcher, and call `add`/`done`/`list`. The pancake
//! `Connection` owns the peer on a background task, so the application above sees
//! only the board methods.
//!
//!   let board = Board::join(&tcp_locator("127.0.0.1", 9099)).await?;
//!   let id = board.add("buy groceries").await?;
//!   board.done(id).await?;
//!   let tasks = board.list().await?;
//!   board.leave().await;

use std::rc::Rc;

use pancake::{connect, Argument, Connection};

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
	conn: Rc<Connection>,
	board: pancake::Ref,
}

impl Board {
	/// Join the board at `locator`. Call inside a `LocalSet` (the peer is `!Send`).
	pub async fn join(locator: &str) -> Result<Board, String> {
		let conn = Rc::new(
			connect(locator, None)
				.await
				.map_err(|e| format!("connect: {e:?}"))?,
		);
		let board = conn
			.fetch(BOARD)
			.await
			.map_err(|e| format!("fetch board: {e:?}"))?;

		// Watch the board so changes are pushed to us (we ignore the updates in
		// this one-shot client, but it exercises the capability callback).
		let watcher = conn
			.spawn(|verb, _args| {
				if verb != "update" {
					return Err(format!("watcher has no method {verb}"));
				}
				Ok(Argument::Void)
			})
			.await
			.map_err(|e| format!("spawn watcher: {e:?}"))?;
		conn.send(&board, "watch", &[(&watcher).into()])
			.await
			.map_err(|e| format!("watch: {e:?}"))?;

		Ok(Board { conn, board })
	}

	pub async fn add(&self, text: &str) -> Result<i64, String> {
		match self.conn.send(&self.board, "add", &[text.into()]).await {
			Ok(reply) => reply
				.as_i64()
				.ok_or_else(|| "unexpected reply to add".to_string()),
			Err(e) => Err(format!("add: {e:?}")),
		}
	}

	pub async fn done(&self, id: i64) -> Result<(), String> {
		self.conn
			.send(&self.board, "done", &[id.into()])
			.await
			.map(|_| ())
			.map_err(|e| format!("done: {e:?}"))
	}

	pub async fn list(&self) -> Result<Vec<Task>, String> {
		let result = self
			.conn
			.send(&self.board, "list", &[])
			.await
			.map_err(|e| format!("list: {e:?}"))?;
		Ok(parse_snapshot(&result))
	}

	pub async fn leave(self) {
		self.conn.close();
	}
}
