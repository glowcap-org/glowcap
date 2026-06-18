//! A small, friendly client for the rooms chat, built on pancake actors.
//!
//! On the connection API this is barely a layer: connect, fetch the directory by
//! name, ask it to open or enter a room (which hands back a live reference to
//! that room), spawn an inbox the room can call back, subscribe by handing it
//! that capability, and forward the room's callbacks onto a channel. The pancake
//! `Connection` owns the peer on a background task, so the application above sees
//! only `recv`/`say`/`leave`.
//!
//!   let dir = Directory::connect(addr).await?;
//!   let mut room = Room::subscribe(dir.conn(), dir.enter("general").await?, "alice").await?;
//!   room.say("hello").await;
//!   while let Some(msg) = room.recv().await { println!("{}: {}", msg.from, msg.text); }
//!   room.leave().await;
//!
//! [`Directory::open`] and [`Directory::enter`] mirror the wire one-to-one and
//! stay strict. The friendly "enter, opening it if new" behavior is a CLI
//! convenience and lives in `client.rs`, not here.

use std::rc::Rc;

use pancake::{connect, tcp_locator, Argument, Connection};
use tokio::sync::mpsc;

const DIRECTORY: &str = "directory";

/// Lift a capability a `send` returned (an `Argument::Reference`) into a `Ref`
/// you can `send` to.
fn room_ref(arg: Argument, verb: &str) -> Result<pancake::Ref, String> {
	pancake::Ref::try_from(&arg).map_err(|_| format!("{verb} did not return a room capability"))
}

/// The wire reason a broken `send` carried, so a caller can classify it (e.g.
/// tell "no room named" apart from "already exists"); falls back to the debug
/// form when the partner gave no message.
fn reason(err: pancake::Error) -> String {
	err.message().unwrap_or_else(|| format!("{err:?}"))
}

/// The directory of rooms: an open connection plus the directory's reference.
/// `connect` dials and fetches it; `open` and `enter` send it the strict verbs,
/// each returning a reference to the room. Both mirror the wire — `open` errs if
/// the name is taken, `enter` errs if there is no such room — and the error
/// string carries the wire reason so a caller can classify it. The friendly
/// enter-or-open is a CLI convenience and lives in `client.rs`.
pub struct Directory {
	conn: Rc<Connection>,
	directory: pancake::Ref,
}

impl Directory {
	/// Dial `locator`, start the connection's driver, and fetch the directory.
	pub async fn connect(locator: &str) -> Result<Directory, String> {
		// `dial` spawns the connection's driver task, so inbound events are
		// already being served — `fetch`, `send`, and inbox callbacks all work
		// without a separate serve loop.
		let conn = Rc::new(dial(locator).await?);
		let directory = conn
			.fetch(DIRECTORY)
			.await
			.map_err(|e| format!("fetch directory: {e:?}"))?;
		Ok(Directory { conn, directory })
	}

	/// The open connection, for subscribing to a room the directory returns.
	pub fn conn(&self) -> Rc<Connection> {
		self.conn.clone()
	}

	/// Create a new room and return its reference. Errs if the name is taken.
	pub async fn open(&self, name: &str) -> Result<pancake::Ref, String> {
		let arg = self
			.conn
			.send(&self.directory, "open", &[name.into()])
			.await
			.map_err(reason)?;
		room_ref(arg, "open")
	}

	/// Return an existing room's reference. Errs if there is no such room.
	pub async fn enter(&self, name: &str) -> Result<pancake::Ref, String> {
		let arg = self
			.conn
			.send(&self.directory, "enter", &[name.into()])
			.await
			.map_err(reason)?;
		room_ref(arg, "enter")
	}

	/// The live rooms — the ones with people in them — as `(name, count)`.
	pub async fn list(&self) -> Result<Vec<(String, i64)>, String> {
		let arg = self
			.conn
			.send(&self.directory, "list", &[])
			.await
			.map_err(reason)?;
		Ok(parse_rooms(&arg))
	}

	/// Follow the live room list: spawn an observer the directory calls back with
	/// each change, register it, and return the current snapshot as a baseline.
	/// `on_event(kind, name, count)` then fires on every open/close/count change
	/// (`kind` is `"opened"`, `"closed"`, or `"count"`).
	pub async fn watch<F>(&self, on_event: F) -> Result<Vec<(String, i64)>, String>
	where
		F: Fn(String, String, i64) + 'static,
	{
		let observer = self
			.conn
			.spawn(move |verb, args| {
				if verb != "notify" {
					return Err(format!("watch inbox has no method {verb}"));
				}
				let kind = as_str(args.first());
				let name = as_str(args.get(1));
				let count = args.get(2).and_then(Argument::as_i64).unwrap_or(0);
				on_event(kind, name, count);
				Ok(Argument::Void)
			})
			.await
			.map_err(|e| format!("spawn watch inbox: {e:?}"))?;
		let arg = self
			.conn
			.send(&self.directory, "watch", &[(&observer).into()])
			.await
			.map_err(reason)?;
		Ok(parse_rooms(&arg))
	}
}

/// Parse the wire shape of `list`/`watch` — a list of `[name, count]` pairs —
/// into `(name, count)` tuples.
fn parse_rooms(arg: &Argument) -> Vec<(String, i64)> {
	let mut out = Vec::new();
	for item in arg.as_list().unwrap_or(&[]) {
		if let Some(pair) = item.as_list() {
			if pair.len() >= 2 {
				out.push((as_str(Some(&pair[0])), pair[1].as_i64().unwrap_or(0)));
			}
		}
	}
	out
}

/// Dial a transport-neutral rooms locator: an `ocapn://…iroh` URI joins over
/// iroh (when this client is built with the `iroh` feature), a bare `host:port`
/// over TCP. The room's wire is identical either way; only how a member reaches
/// it differs. The rooms URIs carry direct-addresses, so the explicit iroh
/// posture is [`Reachability::Direct`](pancake::Reachability::Direct) — relay-less
/// and lookup-less, no default.
async fn dial(locator: &str) -> Result<Connection, String> {
	// An `ocapn://…iroh` URI dials over iroh with the relay-less `Direct` posture
	// its direct-addresses imply; a bare `host:port` is a `tcp` locator, which
	// ignores reachability (`None`). `connect` has one signature either way — a
	// tcp-only build still takes the argument and fails an iroh locator with a
	// rebuild hint — so this is one call, not a feature-forked pair.
	if locator.contains("://") {
		return connect(locator, Some(pancake::Reachability::Direct))
			.await
			.map_err(|e| format!("connect iroh: {e:?}"));
	}
	let (host, port) = locator.rsplit_once(':').ok_or_else(|| {
		format!("rooms locator is neither host:port nor an ocapn:// URI: {locator}")
	})?;
	let port: u16 = port
		.parse()
		.map_err(|_| format!("rooms locator has no valid port: {locator}"))?;
	let loc = tcp_locator(host, port);
	connect(&loc, None)
		.await
		.map_err(|e| format!("connect: {e:?}"))
}

/// One line in the room. `system` is true for the room's own announcements (a
/// member joining, your welcome); otherwise `from` is who said it.
#[derive(Debug, Clone)]
pub struct Message {
	pub from: String,
	pub text: String,
	pub system: bool,
}

/// A membership in a chat room: the connection plus a stream of the lines the
/// room pushes. `recv` for the next line, `say` to talk, `leave` when done.
pub struct Room {
	conn: Rc<Connection>,
	room: pancake::Ref,
	msg_rx: mpsc::UnboundedReceiver<Message>,
}

fn as_str(arg: Option<&Argument>) -> String {
	arg.and_then(Argument::as_str)
		.unwrap_or_default()
		.to_string()
}

impl Room {
	/// Subscribe to a room you already hold a reference to, on the directory's
	/// open connection, as `nick`. Call inside a `LocalSet` (the peer is
	/// `!Send`).
	pub async fn subscribe(
		conn: Rc<Connection>,
		room: pancake::Ref,
		nick: &str,
	) -> Result<Room, String> {
		// The room calls our inbox back with each line; forward it onto a channel.
		let (msg_tx, msg_rx) = mpsc::unbounded_channel::<Message>();
		let welcome_tx = msg_tx.clone();
		let inbox = conn
			.spawn(move |verb, args| {
				if verb != "notify" {
					return Err(format!("inbox has no method {verb}"));
				}
				let from = as_str(args.first());
				let text = as_str(args.get(1));
				let _ = msg_tx.send(Message {
					system: from == "room",
					from,
					text,
				});
				Ok(Argument::Void)
			})
			.await
			.map_err(|e| format!("spawn inbox: {e:?}"))?;

		// Subscribe, handing the room a capability to our inbox. The welcome
		// reply names everyone already present — the only way to learn about
		// earlier arrivals — so it joins the message stream as a system line.
		let welcome = conn
			.send(&room, "subscribe", &[nick.into(), (&inbox).into()])
			.await
			.map_err(|e| format!("subscribe: {e:?}"))?;
		if let Some(text) = welcome.as_str() {
			let _ = welcome_tx.send(Message {
				system: true,
				from: "room".to_string(),
				text: text.to_string(),
			});
		}

		Ok(Room { conn, room, msg_rx })
	}

	/// Say a line to everyone in the room.
	pub async fn say(&self, text: &str) {
		let _ = self.conn.send(&self.room, "post", &[text.into()]).await;
	}

	/// The next line the room pushes, or `None` once it has ended.
	pub async fn recv(&mut self) -> Option<Message> {
		self.msg_rx.recv().await
	}

	/// Leave the room: close the connection and let the driver wind down.
	pub async fn leave(self) {
		self.conn.close();
	}
}
