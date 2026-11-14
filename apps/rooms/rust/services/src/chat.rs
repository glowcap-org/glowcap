//! Interactive host Rooms application over the shared typed clients.
mod terminal;
use glowcap::{PendingWork, Runtime, RuntimeConfig};
use rooms_application::directory::{Event, RoomChange, RoomInfo};
use rooms_glowcap::client::{
	Client,
	directory::Directory,
	room::{Messages, Room, SubscribeOptions},
};
use rooms_platform::HostPlatform;
use rooms_runtime::cleanup;
use terminal::Terminal;

pub const HELP: &str = "usage: rooms-chat <locator> <room> <nick>\n\nLocator: host:port or an ocapn:// TCP or iroh URI.\nCommands: /list /open <name> /enter <name> /leave /help\nCtrl-D, Ctrl-C, or SIGTERM closes the session.\n";

/// One room line as the terminal shows it. A peer's text may hold newlines,
/// so every line after the first is marked as a continuation of this speaker's
/// line and never begins as a line of its own.
fn peer_line(from: &str, text: &str) -> String {
	let text = text.replace('\n', "\n  | ");
	if from == rooms_application::room::inbox::ROOM {
		format!("* {text}")
	} else {
		format!("{}: {text}", terminal::one_line(from))
	}
}

struct Chat {
	directory: Directory<HostPlatform>,
	room: Option<Room<HostPlatform>>,
	messages: Option<Messages>,
	nick: String,
}
impl Chat {
	async fn enter(&mut self, name: &str, open: bool) -> Result<(), String> {
		let reference = if open {
			self.directory.open(name).await
		} else {
			self.directory.enter(name).await
		}
		.map_err(|e| e.to_string())?;
		let (next, messages) = Room::subscribe(
			self.directory.client().clone(),
			reference,
			&self.nick,
			SubscribeOptions::default(),
		)
		.await
		.map_err(|e| e.to_string())?;
		// Admission succeeded. Install the new membership even if retiring the
		// previous one reports a failure; both capabilities retain a close owner.
		let old = self.room.replace(next);
		self.messages = Some(messages);
		if let Some(old) = old {
			old.leave().await.map_err(|e| e.to_string())?;
		}
		Ok(())
	}
	async fn initial(&mut self, name: &str) -> Result<(), String> {
		let reached = rooms_glowcap::client::directory::entry::enter_or_open(
			|bytes| rooms_platform::entropy::fill(bytes).map_err(|e| e.to_string()),
			&self.directory,
			name,
		)
		.await?;
		let (room, messages) = Room::subscribe(
			self.directory.client().clone(),
			reached.reference,
			&self.nick,
			SubscribeOptions::default(),
		)
		.await
		.map_err(|e| e.to_string())?;
		self.room = Some(room);
		self.messages = Some(messages);
		Ok(())
	}

	async fn leave(&mut self) -> Result<(), String> {
		self.messages = None;
		if let Some(room) = self.room.take() {
			room.leave().await.map_err(|e| e.to_string())?;
		}
		Ok(())
	}
	async fn command(&mut self, text: &str, rooms: &[RoomInfo], terminal: &Terminal) -> Result<(), String> {
		if text.is_empty() {
			return Ok(());
		}
		if !text.starts_with('/') {
			let room = self.room.as_ref().ok_or("not in a room; /enter or /open one first")?;
			room.say(text).await.map_err(|e| e.to_string())?;
			return Ok(());
		}
		let (command, name) = text.split_once(char::is_whitespace).unwrap_or((text, ""));
		let name = name.trim();
		match command {
			"/help" => {
				terminal
					.print("* /list  /open <name>  /enter <name>  /leave  /help".into())
					.await?
			}
			"/list" => {
				if rooms.is_empty() {
					terminal.print("* no rooms yet, /open one".into()).await?;
				}
				let mut rows: Vec<_> = rooms.iter().collect();
				rows.sort_by(|a, b| {
					b.count
						.as_ref()
						.map(|n| n.get())
						.cmp(&a.count.as_ref().map(|n| n.get()))
						.then_with(|| a.name.text().as_str().cmp(&b.name.text().as_str()))
				});
				for row in rows {
					terminal
						.print(room_row(
							row.name.text().as_str().unwrap_or(""),
							&row.count
								.as_ref()
								.map_or_else(|| "unknown".into(), |n| n.get().to_string()),
						))
						.await?;
				}
			}
			"/enter" | "/open" => {
				if name.is_empty() {
					return Err(format!("usage: {command} <name>"));
				}
				self.enter(name, command == "/open").await?;
				terminal.print(format!("(in {name:?} as {:?})", self.nick)).await?;
			}
			"/leave" => {
				self.leave().await?;
				terminal
					.print("* left; /enter or /open a room to talk again".into())
					.await?;
			}
			_ => return Err(format!("unknown command {command} (try /help)")),
		}
		Ok(())
	}
	async fn interact(&mut self, initial: &str, terminal: &mut Terminal) -> Result<(), String> {
		let (snapshot, mut updates) = self.directory.watch().await.map_err(|e| e.to_string())?.into_parts();
		let mut rooms = snapshot.rooms;
		self.initial(initial).await?;
		terminal.print(format!("(in {initial:?} as {:?})", self.nick)).await?;
		terminal
			.print("(type a line to talk, /help for commands, Ctrl-D to quit)".into())
			.await?;
		loop {
			tokio::select! {
				input = terminal.next() => {
					let Some(input) = input else { return Ok(()); };
					let result = match input {
						Ok(line) => self.command(&line, &rooms, terminal).await,
						Err(error) => Err(error),
					};
					if let Err(error) = result { terminal.print(error_line(&error)).await?; }
				}
				next = async {
					match &mut self.messages {
						Some(messages) => messages.next().await,
						None => std::future::pending().await,
					}
				} => match next {
					Ok(Some(message)) => {
						// Control bytes in peer text must not become terminal escape sequences.
						terminal.print(peer_line(&message.from, &message.text)).await?;
					}
					Ok(None) => { self.messages = None; terminal.print("* room membership ended".into()).await?; }
					Err(error) => { self.messages = None; terminal.print(error_line(&format!("message stream: {error}"))).await?; }
				},
				event = updates.next() => match event.map_err(|e| e.to_string())? {
					Some(Event::Room { kind, entry }) => {
						let position = rooms.iter().position(|row| row.id == entry.id);
						match (kind, position) {
							(RoomChange::Closed, Some(index)) => { rooms.remove(index); }
							(RoomChange::Closed, None) => {}
							(_, Some(index)) => rooms[index] = entry,
							(_, None) if rooms.len() < rooms_application::directory::MAX_ROWS => rooms.push(entry),
							_ => return Err("directory listing exceeded its retained row budget".into()),
						}
					}
					Some(Event::Truncated(count)) => terminal.print(format!("* directory omitted {count} entries")).await?,
					Some(Event::Member { .. }) => {}
					None => return Err("directory connection ended".into()),
				},
			}
		}
	}
}
/// Chat in a room until the person leaves or the connection ends. The error
/// can carry what a server said, so it is one escaped line, ready for the
/// terminal the chat ends on.
pub async fn run(locator: &str, room: &str, nick: &str) -> Result<(), String> {
	session(locator, room, nick)
		.await
		.map_err(|cause| terminal::one_line(&cause))
}

async fn session(locator: &str, room: &str, nick: &str) -> Result<(), String> {
	if let Some(error) = rooms_application::room::inbox::nick_refusal(nick) {
		return Err(error);
	}
	let locator = rooms_glowcap::routes::locator(locator).ok_or("invalid Rooms directory locator")?;
	let providers = match locator.transport.as_str() {
		glowcap::TRANSPORT_TCP | glowcap::TRANSPORT_KEYED_TCP | glowcap::TRANSPORT_NOISE_TCP => {
			vec![glowcap::tcp::provider(rooms_platform::serving::tcp_config([locator
				.transport
				.as_str()]))]
		}
		glowcap::TRANSPORT_IROH => vec![glowcap::iroh::provider(rooms_platform::serving::iroh_config(
			glowcap::iroh::Reachability::Direct,
		))],
		_ => return Err("rooms-chat supports TCP and iroh directory locators".into()),
	};
	let mut interrupt =
		tokio::signal::unix::signal(tokio::signal::unix::SignalKind::interrupt()).map_err(|e| e.to_string())?;
	let mut terminate =
		tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).map_err(|e| e.to_string())?;
	let runtime = Runtime::open(RuntimeConfig::providers(providers))
		.await
		.map_err(|e| e.to_string())?;
	let mut terminal = match Terminal::open() {
		Ok(terminal) => terminal,
		Err(error) => {
			return Err(cleanup::failed(
				error,
				runtime.close(PendingWork::Cancel).await.map_err(|e| e.to_string()),
			));
		}
	};
	let mut chat = None;
	let work = async {
		let session = runtime
			.connect(&locator, Default::default())
			.await
			.map_err(|e| e.to_string())?;
		let directory = Directory::fetch(Client::new(session, HostPlatform))
			.await
			.map_err(|e| e.to_string())?;
		chat.insert(Chat {
			directory,
			room: None,
			messages: None,
			nick: nick.into(),
		})
		.interact(room, &mut terminal)
		.await
	};
	let mut result =
		tokio::select! { result = work => result, _ = interrupt.recv() => Ok(()), _ = terminate.recv() => Ok(()) };
	if let Some(mut chat) = chat {
		cleanup::retain(&mut result, chat.leave().await);
	}
	cleanup::retain(
		&mut result,
		runtime.close(PendingWork::Cancel).await.map_err(|e| e.to_string()),
	);
	cleanup::retain(&mut result, terminal.close().await);
	result
}

/// One row of the room list.
fn room_row(name: &str, count: &str) -> String {
	format!("* {} ({count})", terminal::one_line(name))
}

/// A refusal or failure the client reports. Its text came from the server.
fn error_line(error: &str) -> String {
	format!("* {}", terminal::one_line(error))
}

#[cfg(test)]
mod tests {
	use super::{
		error_line, peer_line, room_row,
		terminal::{escaped, one_line},
	};

	fn shown_lines(record: String) -> usize {
		escaped(&record).unwrap().lines().count()
	}

	#[test]
	fn a_room_name_a_speaker_name_and_an_error_each_stay_on_their_own_line() {
		assert_eq!(shown_lines(room_row("Lounge\n* Bob left", "3")), 1);
		assert_eq!(shown_lines(peer_line("Mallory\nAlice", "hi")), 1);
		assert_eq!(shown_lines(error_line("refused\n* room membership ended")), 1);
		assert_eq!(shown_lines(room_row("a\tb", "1")), 1);
		assert!(escaped(&room_row("a\tb", "1")).unwrap().contains("\\t"));
	}

	#[test]
	fn a_failure_that_ends_the_chat_prints_as_one_escaped_line() {
		let shown = one_line("no-such-room: x\n* room membership ended\u{1b}[2J\u{202e}");
		assert_eq!(shown.lines().count(), 1);
		assert!(!shown.chars().any(|c| c.is_control() || c == '\u{202e}'), "{shown:?}");
		assert_eq!(one_line("plain refusal"), "plain refusal");
	}

	#[test]
	fn a_newline_in_a_line_cannot_pose_as_another_speaker_or_the_room() {
		let shown = peer_line("Mallory", "hi\nAlice: I agree\n* Alice left");
		for (n, line) in shown.lines().enumerate().skip(1) {
			assert!(
				line.starts_with("  | "),
				"continuation {n} reads as its own line: {line:?}"
			);
		}
		assert_eq!(shown.lines().count(), 3);
		assert_eq!(peer_line("room", "a\nb"), "* a\n  | b");
		assert_eq!(peer_line("Bob", "one line"), "Bob: one line");
	}

	#[test]
	fn direction_characters_in_a_name_or_text_are_written_out() {
		let shown = escaped(&peer_line("Eve\u{202e}", "evil\u{2066}text\u{200f}")).unwrap();
		assert!(
			shown
				.chars()
				.all(|c| !rooms_application::text::is_control_or_direction(c) || c == '\n')
		);
		assert!(shown.contains("\\u{202e}"), "{shown}");
	}
}
