//! A small, friendly client for the rooms chat, built on pancake actors.
//!
//! On the connection API this is barely a layer: connect, fetch the directory by
//! name, ask it to open or enter a room (which hands back a live reference to
//! that room), spawn an inbox the room can call back, subscribe by handing it
//! that capability, and forward the room's callbacks onto a channel. The pancake
//! `Session` owns the peer on a background task, so the application above sees
//! only `recv`/`say`/`leave`.
//!
//!   let dir = Directory::connect(addr).await?;
//!   let mut room = Room::subscribe(dir.session(), dir.enter("general").await?, "alice").await?;
//!   room.say("hello").await;
//!   while let Some(msg) = room.recv().await { println!("{}: {}", msg.from, msg.text); }
//!   room.leave().await;
//!
//! [`Directory::open`] and [`Directory::enter`] mirror the wire one-to-one and
//! stay strict. The friendly "enter, opening it if new" behavior is a CLI
//! convenience and lives in `client.rs`, not here.

use std::rc::Rc;

use pancake::{
	connect, designator_host_port, parse_locator, tcp_locator, Argument, Session,
	HINT_DIRECT_ADDRESSES, TRANSPORT_IROH,
};
use tokio::sync::mpsc;

const DIRECTORY: &str = "directory";

/// Lift a capability a `send` returned (an `Argument::Reference`) into a `Ref`
/// you can `send` to.
fn room_ref(arg: Argument, verb: &str) -> Result<pancake::Ref, String> {
	pancake::Ref::try_from(&arg).map_err(|_| format!("{verb} did not return a room capability"))
}

/// The wire reason a broken `send` carried, so a caller can classify it by the
/// typed code at the front of the reason (`no-such-room` vs `room-exists`); falls
/// back to the debug form when the partner gave no message.
fn reason(err: pancake::Error) -> String {
	err.message()
		.map(str::to_string)
		.unwrap_or_else(|| format!("{err:?}"))
}

/// The directory of rooms: an open connection plus the directory's reference.
/// `connect` dials and fetches it; `open` and `enter` send it the strict verbs,
/// each returning a reference to the room. Both mirror the wire — `open` errs if
/// the name is taken, `enter` errs if there is no such room — and the error
/// string carries the wire reason so a caller can classify it. The friendly
/// enter-or-open is a CLI convenience and lives in `client.rs`.
pub struct Directory {
	session: Rc<Session>,
	directory: pancake::Ref,
}

impl Directory {
	/// Dial `locator`, start the connection's driver, and fetch the directory.
	pub async fn connect(locator: &str) -> Result<Directory, String> {
		// `dial` spawns the connection's driver task, so inbound events are
		// already being served, `fetch`, `send`, and inbox callbacks all work
		// without a separate serve loop.
		let session = Rc::new(dial(locator).await?);
		let directory = session
			.fetch(DIRECTORY)
			.await
			.map_err(|e| format!("fetch directory: {e:?}"))?;
		Ok(Directory { session, directory })
	}

	/// The open connection, for subscribing to a room the directory returns.
	pub fn session(&self) -> Rc<Session> {
		self.session.clone()
	}

	/// Create a new room and return its reference. Errs if the name is taken.
	pub async fn open(&self, name: &str) -> Result<pancake::Ref, String> {
		let arg = self
			.session
			.send(&self.directory, "open", &[name.into()])
			.await
			.map_err(reason)?;
		room_ref(arg, "open")
	}

	/// Return an existing room's reference. Errs if there is no such room.
	pub async fn enter(&self, name: &str) -> Result<pancake::Ref, String> {
		let arg = self
			.session
			.send(&self.directory, "enter", &[name.into()])
			.await
			.map_err(reason)?;
		room_ref(arg, "enter")
	}

	/// The live rooms — the ones with people in them — as `(name, count)`.
	pub async fn list(&self) -> Result<Vec<(String, i64)>, String> {
		let arg = self
			.session
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
			.session
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
			.session
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
/// it differs. A URI carrying direct-addresses dials those directly (relay-less
/// Direct); a node-id-only URI resolves the peer through discovery.
async fn dial(locator: &str) -> Result<Session, String> {
	if locator.contains("://") {
		let loc = parse_locator(locator).map_err(|e| {
			format!("rooms expected an iroh ocapn:// URI, got parse error for {locator}: {e:?}")
		})?;
		if loc.transport != TRANSPORT_IROH {
			return Err(format!(
				"rooms expected an iroh ocapn:// URI, got \"{}\": {locator}",
				loc.transport
			));
		}
		let hints = loc
			.hints
			.get(HINT_DIRECT_ADDRESSES)
			.map(String::as_str)
			.unwrap_or("");
		let reachability = if hints.is_empty() {
			pancake::Reachability::Discovery
		} else {
			pancake::Reachability::Direct
		};
		return connect(locator, Some(reachability), None)
			.await
			.map_err(|e| format!("connect iroh: {e:?}"));
	}
	let (host, port) = designator_host_port(locator).map_err(|e| {
		format!("rooms locator is neither host:port nor an ocapn:// URI: {locator}: {e:?}")
	})?;
	let loc = tcp_locator(&host, port);
	connect(&loc, None, None)
		.await
		.map_err(|e| format!("connect: {e:?}"))
}

/// One line in the room. `system` is true for the room's own announcements (a
/// member joining, your welcome); otherwise `from` is who said it. `presence` is
/// set on a membership-change system line.
#[derive(Debug, Clone)]
pub struct Message {
	pub from: String,
	pub text: String,
	pub system: bool,
	pub presence: Option<Presence>,
}

/// A membership change a system line carries as structured wire args, not prose:
/// the roster on arrival, or a join/leave. `names` is the roster, or the one nick.
#[derive(Debug, Clone)]
pub struct Presence {
	pub kind: String, // "roster" | "join" | "leave"
	pub names: Vec<String>,
}

/// Read the structured presence a room line carries after its display text —
/// `notify("room", text, "roster", names…)` or `notify("room", text, kind, nick)`.
/// Ordinary chat lines carry none.
fn read_presence(args: &[Argument]) -> Option<Presence> {
	match args.get(2).and_then(Argument::as_str) {
		Some("roster") => Some(Presence {
			kind: "roster".to_string(),
			names: args[3..]
				.iter()
				.filter_map(Argument::as_str)
				.map(str::to_string)
				.collect(),
		}),
		Some(kind @ ("join" | "leave")) => {
			let name = args.get(3).and_then(Argument::as_str)?;
			Some(Presence {
				kind: kind.to_string(),
				names: vec![name.to_string()],
			})
		}
		_ => None,
	}
}

/// A membership in a chat room: the connection plus a stream of the lines the
/// room pushes. `recv` for the next line, `say` to talk, `leave` when done.
pub struct Room {
	session: Rc<Session>,
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
		session: Rc<Session>,
		room: pancake::Ref,
		nick: &str,
	) -> Result<Room, String> {
		// The room calls our inbox back with each line; forward it onto a channel.
		// A system line may carry a structured presence change after its text.
		let (msg_tx, msg_rx) = mpsc::unbounded_channel::<Message>();
		let inbox = session
			.spawn(move |verb, args| {
				if verb != "notify" {
					return Err(format!("inbox has no method {verb}"));
				}
				let from = as_str(args.first());
				let text = as_str(args.get(1));
				let presence = read_presence(args);
				let _ = msg_tx.send(Message {
					system: from == "room",
					from,
					text,
					presence,
				});
				Ok(Argument::Void)
			})
			.await
			.map_err(|e| format!("spawn inbox: {e:?}"))?;

		// Subscribe, handing the room a capability to our inbox. Success is the
		// resolution; the room delivers the welcome and roster as our first
		// `notify`, not as a return value.
		session
			.send(&room, "subscribe", &[nick.into(), (&inbox).into()])
			.await
			.map_err(|e| format!("subscribe: {e:?}"))?;

		Ok(Room {
			session,
			room,
			msg_rx,
		})
	}

	/// Say a line to everyone in the room.
	pub async fn say(&self, text: &str) {
		let _ = self.session.send(&self.room, "post", &[text.into()]).await;
	}

	/// The next line the room pushes, or `None` once it has ended.
	pub async fn recv(&mut self) -> Option<Message> {
		self.msg_rx.recv().await
	}

	/// Leave the room: close the connection and let the driver wind down.
	pub async fn leave(self) {
		self.session.close();
	}
}
