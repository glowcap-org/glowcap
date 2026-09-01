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
//!   room.say("hello").await?;
//!   while let Some(msg) = room.recv().await { println!("{}: {}", msg.from, msg.text); }
//!   room.leave().await?;
//!
//! [`Directory::open`] and [`Directory::enter`] mirror the wire one-to-one and
//! stay strict. The friendly "enter, opening it if new" behavior is a CLI
//! convenience and lives in `client.rs`, not here.

use std::rc::Rc;

use pancake::{
	designator_host_port, parse_locator, tcp, Argument, ConnectOptions, PendingWork, Runtime, RuntimeConfig, Session,
	TRANSPORT_IROH,
};
#[cfg(feature = "iroh")]
use pancake::{iroh, HINT_DIRECT_ADDRESSES};
use tokio::sync::mpsc;

const DIRECTORY: &str = "directory";
const MAX_UNREAD_LINES: usize = 256;

/// Lift a capability a `send` returned (an `Argument::Reference`) into a `Ref`
/// you can `send` to.
fn room_ref(arg: Argument, verb: &str) -> Result<pancake::Ref, String> {
	pancake::Ref::try_from(&arg).map_err(|_| format!("{verb} did not return a room capability"))
}

/// The wire reason a broken `send` carried, so a caller can classify it by the
/// typed code at the front of the reason (`no-such-room` vs `room-exists`); falls
/// back to the debug form when the partner gave no message.
fn reason(err: pancake::Error) -> String {
	err.message().map(str::to_string).unwrap_or_else(|| format!("{err:?}"))
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
	_runtime: Runtime,
}

impl Directory {
	/// Dial `locator`, start the connection's driver, and fetch the directory.
	pub async fn connect(locator: &str) -> Result<Directory, String> {
		// `dial` spawns the connection's driver task, so inbound events are
		// already being served, `fetch`, `send`, and inbox callbacks all work
		// without a separate serve loop.
		let (runtime, session) = dial(locator).await?;
		let session = Rc::new(session);
		let directory = session
			.fetch(DIRECTORY)
			.await
			.map_err(|e| format!("fetch directory: {e:?}"))?;
		Ok(Directory {
			session,
			directory,
			_runtime: runtime,
		})
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

	/// The directory's exact live local and foreign room publications.
	pub async fn list(&self) -> Result<Vec<RoomInfo>, String> {
		let arg = self
			.session
			.send(&self.directory, "listPublications", &[])
			.await
			.map_err(reason)?;
		parse_rooms(&arg)
	}

	/// Follow the live room list: spawn an observer the directory calls back with
	/// each change, register it, and return the current snapshot as a baseline.
	/// `on_event(kind, room)` receives the exact publication record.
	pub async fn watch<F>(&self, on_event: F) -> Result<Vec<RoomInfo>, String>
	where
		F: Fn(String, RoomInfo) + 'static,
	{
		let observer = self
			.session
			.spawn(move |verb, args| {
				if verb != "notify" {
					return Err(format!("watch inbox has no method {verb}"));
				}
				if let Some((kind, room)) = parse_watch_event(args)? {
					on_event(kind, room);
				}
				Ok(Argument::Void)
			})
			.map_err(|e| format!("spawn watch inbox: {e:?}"))?;
		let arg = self
			.session
			.send(&self.directory, "watchPublications", &[(&observer).into()])
			.await
			.map_err(reason)?;
		parse_watch_rooms(&arg)
	}
}

#[derive(Clone, Debug)]
pub struct RoomInfo {
	pub name: String,
	pub count: Option<i64>,
	pub id: String,
	pub kind: String,
	pub origin: String,
	pub proof: String,
	pub offers: Option<String>,
}

fn parse_room(fields: &[Argument]) -> Option<RoomInfo> {
	if fields.len() != 7 {
		return None;
	}
	let count = if fields[1].is_void() {
		None
	} else {
		Some(fields[1].as_i64().filter(|count| *count >= 0)?)
	};
	let offers = if fields[6].is_void() {
		None
	} else {
		let kind = fields[6].as_str()?;
		if kind != "observer" && kind != "participant" {
			return None;
		}
		Some(kind.to_string())
	};
	Some(RoomInfo {
		name: fields[0].as_str()?.to_string(),
		count,
		id: fields[2].as_str()?.to_string(),
		kind: fields[3].as_str()?.to_string(),
		origin: fields[4].as_str()?.to_string(),
		proof: fields[5].as_str()?.to_string(),
		offers,
	})
}

fn parse_rooms(arg: &Argument) -> Result<Vec<RoomInfo>, String> {
	let rows = arg
		.as_list()
		.ok_or_else(|| "the directory answered a room list that is not a list".to_string())?;
	let mut out = Vec::new();
	for item in rows {
		let room = item
			.as_list()
			.and_then(parse_room)
			.ok_or_else(|| "the directory answered a malformed room publication".to_string())?;
		out.push(room);
	}
	Ok(out)
}

fn parse_watch_rooms(arg: &Argument) -> Result<Vec<RoomInfo>, String> {
	let fields = arg
		.as_list()
		.filter(|fields| fields.len() == 3)
		.ok_or_else(|| "the directory answered a malformed watch snapshot".to_string())?;
	let registrations = fields[1]
		.as_list()
		.ok_or_else(|| "the directory answered malformed registration rows".to_string())?;
	if registrations.iter().any(|row| {
		row.as_list()
			.map(|values| {
				values.len() != 2
					|| values[0].as_str().map(str::is_empty).unwrap_or(true)
					|| values[1].as_str().map(str::is_empty).unwrap_or(true)
			})
			.unwrap_or(true)
	}) {
		return Err("the directory answered malformed registration rows".to_string());
	}
	if fields[2].as_i64().filter(|omitted| *omitted >= 0).is_none() {
		return Err("the directory answered an invalid watch omission count".to_string());
	}
	parse_rooms(&fields[0])
}

fn valid_registration_id(value: &str) -> bool {
	let bytes = value.as_bytes();
	if bytes.len() != 36 || [8, 13, 18, 23].iter().any(|at| bytes[*at] != b'-') {
		return false;
	}
	for (at, byte) in bytes.iter().enumerate() {
		if [8, 13, 18, 23].contains(&at) {
			continue;
		}
		if !byte.is_ascii_hexdigit() {
			return false;
		}
	}
	matches!(bytes[14], b'1'..=b'8') && matches!(bytes[19].to_ascii_lowercase(), b'8' | b'9' | b'a' | b'b')
}

/// Parse every supported watcher shape. Registration and truncation events are
/// valid but carry no room row for this small terminal client to print.
fn parse_watch_event(args: &[Argument]) -> Result<Option<(String, RoomInfo)>, String> {
	let kind = args
		.first()
		.and_then(Argument::as_str)
		.ok_or_else(|| "the directory sent a malformed watch notification".to_string())?;
	match kind {
		"opened" | "closed" | "count" => {
			let room = parse_room(&args[1..])
				.ok_or_else(|| "the directory sent a malformed room watch notification".to_string())?;
			Ok(Some((kind.to_string(), room)))
		}
		"registered" | "unregistered" => {
			let valid = args.len() == 4
				&& args[1].as_str().map(|name| !name.is_empty()).unwrap_or(false)
				&& args[2].as_i64().map(|count| count >= 0).unwrap_or(false)
				&& args[3].as_str().map(valid_registration_id).unwrap_or(false);
			if !valid {
				return Err("the directory sent a malformed member watch notification".to_string());
			}
			Ok(None)
		}
		"truncated" => {
			if args.len() != 2 || args[1].as_i64().map(|count| count >= 0) != Some(true) {
				return Err("the directory sent a malformed watch truncation".to_string());
			}
			Ok(None)
		}
		_ => Err(format!("the directory sent an unknown watch event {kind}")),
	}
}

/// Dial a transport-neutral rooms locator: an `ocapn://…iroh` URI joins over
/// iroh (when this client is built with the `iroh` feature), a bare `host:port`
/// over TCP. The room's wire is identical either way; only how a member reaches
/// it differs. A URI carrying direct-addresses dials those directly (relay-less
/// Direct); a node-id-only URI resolves the peer through discovery.
async fn dial(locator: &str) -> Result<(Runtime, Session), String> {
	if locator.contains("://") {
		let loc = parse_locator(locator)
			.map_err(|e| format!("rooms expected an iroh ocapn:// URI, got parse error for {locator}: {e:?}"))?;
		if loc.transport != TRANSPORT_IROH {
			return Err(format!(
				"rooms expected an iroh ocapn:// URI, got \"{}\": {locator}",
				loc.transport
			));
		}
		#[cfg(not(feature = "iroh"))]
		return Err("rooms client was built without iroh support".to_string());
		#[cfg(feature = "iroh")]
		{
			let hints = loc
				.string_hint(HINT_DIRECT_ADDRESSES)
				.map_err(|e| format!("rooms iroh locator has invalid direct-addresses: {e:?}"))?
				.unwrap_or("");
			let reachability = if hints.is_empty() {
				iroh::Reachability::Discovery
			} else {
				iroh::Reachability::Direct
			};
			let runtime = Runtime::open(
				RuntimeConfig::providers([iroh::provider(iroh::Config::new(reachability))]).adopt_host(&rooms_host()?),
			)
			.await
			.map_err(|e| format!("runtime iroh: {e:?}"))?;
			let session = runtime
				.connect(&loc, ConnectOptions::default())
				.await
				.map_err(|e| format!("connect iroh: {e:?}"))?;
			return Ok((runtime, session));
		}
	}
	let (host, port) = designator_host_port(locator)
		.map_err(|e| format!("rooms locator is neither host:port nor an ocapn:// URI: {locator}: {e:?}"))?;
	let loc = tcp::locator(&host, port);
	let runtime =
		Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]).adopt_host(&rooms_host()?))
			.await
			.map_err(|e| format!("runtime: {e:?}"))?;
	let session = runtime
		.connect(&loc, ConnectOptions::default())
		.await
		.map_err(|e| format!("connect: {e:?}"))?;
	Ok((runtime, session))
}

/// Mint a Host for a rooms peer.
///
/// Every rooms peer selects the core-authored native profile. Rust's `connect`
/// takes no profile argument, so the host is what names it.
///
/// Minting one draws the Host's identity seed from the system, which can fail,
/// so this answers with the failure rather than panicking inside a client whose
/// callers already carry their own errors.
fn rooms_host() -> Result<pancake::Host, String> {
	pancake::Host::with_options(pancake::HostOptions::with_profile(pancake::HostProfile::Native))
		.map_err(|e| format!("rooms host: {e:?}"))
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
	msg_rx: mpsc::Receiver<Message>,
}

fn message_channel() -> (mpsc::Sender<Message>, mpsc::Receiver<Message>) {
	mpsc::channel(MAX_UNREAD_LINES)
}

fn enqueue_line(sender: &mpsc::Sender<Message>, message: Message) -> Result<(), String> {
	match sender.try_send(message) {
		Ok(()) => Ok(()),
		Err(mpsc::error::TrySendError::Full(_)) => {
			Err(format!("the room retained its maximum {MAX_UNREAD_LINES} unread lines"))
		}
		Err(mpsc::error::TrySendError::Closed(_)) => Err("the room inbox is closed".to_string()),
	}
}

fn as_str(arg: Option<&Argument>) -> String {
	arg.and_then(Argument::as_str).unwrap_or_default().to_string()
}

impl Room {
	/// Subscribe to a room you already hold a reference to, on the directory's
	/// open connection, as `nick`. Call inside a `LocalSet` (the peer is
	/// `!Send`).
	pub async fn subscribe(session: Rc<Session>, room: pancake::Ref, nick: &str) -> Result<Room, String> {
		// The room calls our inbox back with each line; forward it onto a channel.
		// A system line may carry a structured presence change after its text.
		let (msg_tx, msg_rx) = message_channel();
		let inbox = session
			.spawn(move |verb, args| {
				if verb != "notify" {
					return Err(format!("inbox has no method {verb}"));
				}
				let from = as_str(args.first());
				let text = as_str(args.get(1));
				let presence = read_presence(args);
				enqueue_line(
					&msg_tx,
					Message {
						system: from == "room",
						from,
						text,
						presence,
					},
				)?;
				Ok(Argument::Void)
			})
			.map_err(|e| format!("spawn inbox: {e:?}"))?;

		// Subscribe, handing the room a capability to our inbox. Success is the
		// resolution; the room delivers the welcome and roster as our first
		// `notify`, not as a return value.
		session
			.send(&room, "subscribe", &[nick.into(), (&inbox).into()])
			.await
			.map_err(|e| format!("subscribe: {e:?}"))?;

		Ok(Room { session, room, msg_rx })
	}

	/// Say a line to everyone in the room. Fails if the room rejects the line or
	/// the session is gone; a caller that drops the error is silently dropping
	/// the message.
	pub async fn say(&self, text: &str) -> Result<(), String> {
		self.session
			.send(&self.room, "post", &[text.into()])
			.await
			.map(|_| ())
			.map_err(|err| format!("say: {err}"))
	}

	/// The next line the room pushes, or `None` once it has ended.
	pub async fn recv(&mut self) -> Option<Message> {
		self.msg_rx.recv().await
	}

	/// Leave the room: close the connection and let the driver wind down.
	pub async fn leave(self) -> Result<(), String> {
		self.session
			.close(PendingWork::Cancel)
			.await
			.map_err(|err| format!("leave: {err}"))
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	fn line(number: usize) -> Message {
		Message {
			from: "peer".to_string(),
			text: number.to_string(),
			system: false,
			presence: None,
		}
	}

	#[test]
	fn unread_lines_stop_at_the_named_ceiling() {
		let (sender, _receiver) = message_channel();
		for at in 0..MAX_UNREAD_LINES {
			enqueue_line(&sender, line(at)).expect("an admitted unread line");
		}
		let refusal = enqueue_line(&sender, line(MAX_UNREAD_LINES)).expect_err("overflow must be refused");
		assert!(refusal.contains(&MAX_UNREAD_LINES.to_string()));
	}

	#[test]
	fn malformed_watch_callbacks_are_refused() {
		let malformed = [Argument::from("opened"), Argument::from("only-a-name")];
		assert!(parse_watch_event(&malformed).is_err());
		let registration = [
			Argument::from("registered"),
			Argument::from("ada"),
			Argument::from(1_i64),
			Argument::from("00000000-0000-4000-8000-000000000001"),
		];
		assert!(matches!(parse_watch_event(&registration), Ok(None)));
	}
}
