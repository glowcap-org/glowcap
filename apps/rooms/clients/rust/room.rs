//! A small, friendly client for the rooms chat, built on glowcap actors.
//!
//! On the connection API this is barely a layer: connect, fetch the directory by
//! name, ask it to open or enter a room (which hands back a live reference to
//! that room), spawn an inbox the room can call back, subscribe by handing it
//! that capability, and forward the room's callbacks onto a channel. The glowcap
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
//!
//! The verbs this sends, and the sender name a room's own lines carry, come from
//! `protocol_gen.rs` beside this file, generated from
//! `tools/gen/rooms_protocol.zig` and shared with every sibling client. Reading
//! the values a directory or room answers with, against those same tables, is
//! `wire.rs`.

use std::cell::RefCell;
use std::rc::Rc;

use glowcap::{
	Argument, ConnectOptions, PendingWork, Runtime, RuntimeConfig, Session, TRANSPORT_IROH, designator_host_port,
	parse_locator, tcp,
};
#[cfg(feature = "iroh")]
use glowcap::{HINT_DIRECT_ADDRESSES, iroh};
use tokio::sync::mpsc;

// The one grammar every rooms client switches on, and this language's reading of it.
use crate::protocol_gen::{
	DIRECTORY, ENTER, LIST_PUBLICATIONS, MEMBERSHIP_ENDED, NOTIFY, OPEN, POST, ROOM_SENDER, SUBSCRIBE,
	WATCH_PUBLICATIONS,
};
use crate::wire::{
	Presence, RoomInfo, RoomPage, membership_ended_fits, membership_seat, parse_room_page, parse_watch_event,
	parse_watch_rooms, read_presence,
};

/// The most lines the room may retain for a reader that has stopped reading.
/// This is the client's own back pressure, not part of the wire grammar.
const MAX_UNREAD_LINES: usize = 256;

/// Lift a capability a `send` returned (an `Argument::Reference`) into a `Ref`
/// you can `send` to.
fn room_ref(arg: Argument, verb: &str) -> Result<glowcap::Ref, String> {
	glowcap::Ref::try_from(&arg).map_err(|_| format!("{verb:?} did not return a room capability"))
}

/// The wire reason a broken `send` carried, so a caller can classify it by the
/// typed code at the front of the reason (`no-such-room` vs `room-exists`). Falls
/// back to the debug form when the partner gave no message.
fn reason(err: glowcap::Error) -> String {
	err.message().map(str::to_string).unwrap_or_else(|| format!("{err:?}"))
}

/// The directory of rooms: an open connection plus the directory's reference.
/// `connect` dials and fetches it; `open` and `enter` send it the strict verbs,
/// each returning a reference to the room. Both mirror the wire (`open` errs if
/// the name is taken, `enter` errs if there is no such room) and the error
/// string carries the wire reason so a caller can classify it. The friendly
/// enter-or-open is a CLI convenience and lives in `client.rs`.
pub struct Directory {
	session: Rc<Session>,
	directory: glowcap::Ref,
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
	pub async fn open(&self, name: &str) -> Result<glowcap::Ref, String> {
		let arg = self
			.session
			.send(&self.directory, OPEN, &[name.into()])
			.await
			.map_err(reason)?;
		room_ref(arg, OPEN)
	}

	/// Return an existing room's reference. Errs if there is no such room.
	pub async fn enter(&self, name: &str) -> Result<glowcap::Ref, String> {
		let arg = self
			.session
			.send(&self.directory, ENTER, &[name.into()])
			.await
			.map_err(reason)?;
		room_ref(arg, ENTER)
	}

	/// One page of the directory's live local and foreign room publications.
	/// Pass nothing for the first page and the page's `next` for the one after.
	pub async fn list(&self, cursor: Option<&str>) -> Result<RoomPage, String> {
		let args: Vec<Argument> = cursor.map(Into::into).into_iter().collect();
		let arg = self
			.session
			.send(&self.directory, LIST_PUBLICATIONS, &args)
			.await
			.map_err(reason)?;
		parse_room_page(&arg)
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
				if verb != Some(NOTIFY) {
					return Err(format!("watch inbox has no method {verb:?}"));
				}
				if let Some((kind, room)) = parse_watch_event(args)? {
					on_event(kind, room);
				}
				Ok(Argument::Void)
			})
			.map_err(|e| format!("spawn watch inbox: {e:?}"))?;
		let arg = self
			.session
			.send(&self.directory, WATCH_PUBLICATIONS, &[(&observer).into()])
			.await
			.map_err(reason)?;
		parse_watch_rooms(&arg)
	}
}

/// Dial a transport-neutral rooms locator: an `ocapn://…iroh` URI joins over
/// iroh (when this client is built with the `iroh` feature), a bare `host:port`
/// over TCP. The room's wire is identical either way. Only how a member reaches
/// it differs. A URI carrying direct-addresses dials those directly (relay-less
/// Direct). A node-id-only URI resolves the peer through discovery.
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
/// Every rooms peer selects the core-authored glowcap profile. Rust's `connect`
/// takes no profile argument, so the host is what names it.
///
/// Minting one draws the Host's identity seed from the system, which can fail,
/// so this answers with the failure rather than panicking inside a client whose
/// callers already carry their own errors.
fn rooms_host() -> Result<glowcap::Host, String> {
	glowcap::Host::with_options(glowcap::HostOptions::with_profile(glowcap::HostProfile::Glowcap))
		.map_err(|e| format!("rooms host: {e:?}"))
}

/// One line in the room. `system` is true for the room's own announcements (a
/// member joining, your welcome). Otherwise `from` is who said it. `presence` is
/// set on a membership-change system line.
#[derive(Debug, Clone)]
pub struct Message {
	pub from: String,
	pub text: String,
	pub system: bool,
	pub presence: Option<Presence>,
}

/// A membership in a chat room: the connection plus a stream of the lines the
/// room pushes. `recv` for the next line, `say` to talk, `leave` when done.
pub struct Room {
	session: Rc<Session>,
	/// The membership seat the room answered `subscribe` with. Every later
	/// membership verb goes here, never to the room it was answered for.
	membership: glowcap::Ref,
	msg_rx: mpsc::Receiver<Message>,
	/// The reason the room gave when it ended this membership, shared with the
	/// inbox that hears it.
	ended: Rc<RefCell<Option<String>>>,
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

/// One `notify` on the room inbox: a chat or system line goes onto the channel.
/// A `membershipEnded` tail is the room's last word to this inbox (a steward's
/// kick, say): the reason is the last line, `ended` keeps it, and the sender
/// drops so `recv` ends after what the channel already holds. Its shape is held
/// strictly, the way a watch notification's is.
fn deliver_notify(
	msg_tx: &mut Option<mpsc::Sender<Message>>,
	ended: &RefCell<Option<String>>,
	args: &[Argument],
) -> Result<(), String> {
	let sender = msg_tx.as_ref().ok_or_else(|| "the room inbox is closed".to_string())?;
	let from = as_str(args.first());
	let text = as_str(args.get(1));
	if args.get(2).and_then(Argument::as_str) == Some(MEMBERSHIP_ENDED) {
		if !membership_ended_fits(&from, &text, args) {
			return Err("membership-ended notify takes one reason".to_string());
		}
		enqueue_line(
			sender,
			Message {
				from,
				text: text.clone(),
				system: true,
				presence: None,
			},
		)?;
		*ended.borrow_mut() = Some(text);
		*msg_tx = None;
		return Ok(());
	}
	let presence = read_presence(&from, &text, args);
	enqueue_line(
		sender,
		Message {
			system: from == ROOM_SENDER,
			from,
			text,
			presence,
		},
	)
}

impl Room {
	/// Subscribe to a room you already hold a reference to, on the directory's
	/// open connection, as `nick`. Call inside a `LocalSet` (the peer is
	/// `!Send`).
	pub async fn subscribe(session: Rc<Session>, room: glowcap::Ref, nick: &str) -> Result<Room, String> {
		// The room calls our inbox back with each line; forward it onto a channel.
		// A system line may carry a structured presence change after its text.
		let (msg_tx, msg_rx) = message_channel();
		let mut msg_tx = Some(msg_tx);
		let ended = Rc::new(RefCell::new(None));
		let heard_ended = ended.clone();
		let inbox = session
			.spawn(move |verb, args| {
				if verb != Some(NOTIFY) {
					return Err(format!("inbox has no method {verb:?}"));
				}
				deliver_notify(&mut msg_tx, &heard_ended, args)?;
				Ok(Argument::Void)
			})
			.map_err(|e| format!("spawn inbox: {e:?}"))?;

		// Subscribe, handing the room a capability to our inbox. The room answers
		// with the membership seat; the welcome and roster arrive as our first
		// `notify`, not as part of that answer.
		let answer = session
			.send(&room, SUBSCRIBE, &[nick.into(), (&inbox).into()])
			.await
			.map_err(|e| format!("subscribe: {e:?}"))?;
		let membership = membership_seat(&answer)
			.ok_or_else(|| "the room answered subscribe without one membership capability".to_string())?;

		Ok(Room {
			session,
			membership,
			msg_rx,
			ended,
		})
	}

	/// The reason the room gave when it ended this membership, or `None` while
	/// it stands. Set before `recv` returns `None` for that reason.
	pub fn ended(&self) -> Option<String> {
		self.ended.borrow().clone()
	}

	/// Say a line to everyone in the room, on the membership seat. Fails if the
	/// room rejects the line or the session is gone. A caller that drops the
	/// error is silently dropping the message.
	pub async fn say(&self, text: &str) -> Result<(), String> {
		self.session
			.send(&self.membership, POST, &[text.into()])
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
	// The room line this inbox is fed is the shape `wire` reads, so its fixture
	// builds one here too.
	use crate::wire::fixtures::notify;

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
	fn membership_ended_is_the_last_line_and_ends_the_stream() {
		let (sender, mut receiver) = message_channel();
		let mut sender = Some(sender);
		let ended = RefCell::new(None);
		let notice = notify(
			ROOM_SENDER,
			"kicked by the steward",
			vec![Argument::from(MEMBERSHIP_ENDED)],
		);
		deliver_notify(&mut sender, &ended, &notice).expect("the notice is admitted");
		let last = receiver.try_recv().expect("the reason is the last line");
		assert!(last.system && last.text == "kicked by the steward");
		assert!(receiver.try_recv().is_err(), "the stream ends after the reason");
		assert_eq!(ended.borrow().as_deref(), Some("kicked by the steward"));

		// The generated tail admits nothing else: no blank reason, no sender but
		// the room, and no argument after the tag.
		for refused in [
			notify(ROOM_SENDER, "", vec![Argument::from(MEMBERSHIP_ENDED)]),
			notify("ada", "bye", vec![Argument::from(MEMBERSHIP_ENDED)]),
			notify(
				ROOM_SENDER,
				"bye",
				vec![Argument::from(MEMBERSHIP_ENDED), Argument::from("extra")],
			),
		] {
			let (sender, _receiver) = message_channel();
			let refusal =
				deliver_notify(&mut Some(sender), &RefCell::new(None), &refused).expect_err("a malformed notice");
			assert!(refusal.contains("membership-ended notify takes one reason"));
		}
	}

	#[test]
	fn a_line_carrying_a_presence_tail_reaches_the_reader_with_it() {
		let (sender, mut receiver) = message_channel();
		let mut sender = Some(sender);
		let welcome = notify(
			ROOM_SENDER,
			"welcome",
			vec![Argument::from("roster"), Argument::from("ada")],
		);
		deliver_notify(&mut sender, &RefCell::new(None), &welcome).expect("the welcome is admitted");
		let system = receiver.try_recv().expect("the welcome is a line");
		assert!(system.system);
		assert_eq!(system.presence.expect("a roster presence").names, ["ada".to_string()]);

		// An ordinary chat line is nobody's membership change.
		let said = notify("ada", "hi", vec![]);
		deliver_notify(&mut sender, &RefCell::new(None), &said).expect("the line is admitted");
		let chat = receiver.try_recv().expect("the chat line");
		assert!(!chat.system && chat.presence.is_none());
	}
}
