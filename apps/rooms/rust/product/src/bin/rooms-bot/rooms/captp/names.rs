//! The nicknames the session's workspace gives, which a line alone does not
//! carry. A room line names its sender, and a nickname belongs to a
//! directory, so the name this member answers to in a room comes from the
//! workspace. A direct line from the other person names no sender, so their
//! nickname in the directory the conversation belongs to comes from there too.
use super::super::{Batch, Body, Kind, Line, Sender};
use crate::bot::conversations::MAX_CONVERSATIONS;
use rooms_application::{content::session::workspace::Conversation, room::inbox::same_nick};
use rooms_services::session::attached::Snapshot;
use std::{
	cell::RefCell,
	collections::{BTreeMap, BTreeSet},
	time::Duration,
};

/// How many times one read asks the workspace again for a private sender's
/// name before it takes the line with no name.
pub const MAX_PEER_WAITS: u32 = 3;
/// How long a read waits before it first asks again. Each later wait doubles.
pub const PEER_WAIT: Duration = Duration::from_secs(1);

#[derive(Default)]
pub struct Names {
	/// This member's nickname in each room, by room id.
	own: BTreeMap<String, String>,
	/// The other person's nickname in each direct conversation, by its id.
	peers: BTreeMap<String, String>,
}

impl Names {
	pub fn of(snapshot: &Snapshot) -> Self {
		let intent = &snapshot.intent;
		let mut names = Self::default();
		for conversation in intent.conversations.as_slice() {
			match conversation {
				Conversation::Room(room) => {
					let directory = intent
						.directories
						.as_slice()
						.iter()
						.find(|row| row.id == room.directory);
					let nick =
						directory.and_then(|row| row.assigned_nick.as_ref().unwrap_or(&row.nick).text().as_str());
					if let (Some(id), Some(nick)) = (room.id.text().as_str(), nick) {
						names.own.insert(id.to_owned(), nick.to_owned());
					}
				}
				Conversation::Direct(direct) => {
					if let (Some(id), Some(peer)) = (direct.id.text().as_str(), direct.peer.text().as_str()) {
						names.peers.insert(id.to_owned(), peer.to_owned());
					}
				}
			}
		}
		names
	}

	/// Whether `from` is this member's nickname in `room`, as Rooms compares
	/// nicknames.
	pub fn is_own(&self, room: &str, from: &str) -> bool {
		self.own.get(room).is_some_and(|nick| same_nick(nick, from))
	}

	/// The other person's nickname in the direct conversation `id`.
	pub fn peer(&self, id: &str) -> Option<String> {
		self.peers.get(id).cloned()
	}
}

fn unnamed(batch: &mut Batch) -> impl Iterator<Item = (&str, &mut Sender)> {
	batch.events.iter_mut().filter_map(|event| match &mut event.body {
		Body::Line(Line {
			sender: sender @ Sender::Peer(None),
			..
		}) if event.kind == Kind::Direct => Some((event.conversation.as_str(), sender)),
		_ => None,
	})
}

/// Name the private senders the workspace did not name when `batch` was read,
/// asking `names` for a newer workspace after a wait, at most
/// [`MAX_PEER_WAITS`] times. An allow list declines a sender it cannot name,
/// so taking the line too soon would lose an allowed person's message. A
/// sender still unnamed after the last wait is taken with no name, and its
/// conversation joins `waited`, so a later read takes that conversation's
/// lines at once instead of stalling every conversation behind the same
/// wait. `waited` holds at most [`MAX_CONVERSATIONS`] ids and starts over
/// past that. Only a workspace that cannot be read fails, so a directory
/// that has not named someone yet never looks like a session that does not
/// answer.
pub async fn name_unnamed<E>(
	batch: &mut Batch,
	waited: &RefCell<BTreeSet<String>>,
	mut names: impl AsyncFnMut() -> Result<Names, E>,
) -> Result<(), E> {
	let mut wait = PEER_WAIT;
	for _ in 0..MAX_PEER_WAITS {
		let pending = {
			let waited = waited.borrow();
			unnamed(batch).any(|(conversation, _)| !waited.contains(conversation))
		};
		if !pending {
			return Ok(());
		}
		tokio::time::sleep(wait).await;
		wait *= 2;
		let names = names().await?;
		for (conversation, sender) in unnamed(batch) {
			*sender = Sender::Peer(names.peer(conversation));
		}
	}
	let mut waited = waited.borrow_mut();
	if waited.len() >= MAX_CONVERSATIONS {
		waited.clear();
	}
	waited.extend(unnamed(batch).map(|(conversation, _)| conversation.to_owned()));
	Ok(())
}

#[cfg(test)]
mod tests {
	use super::super::super::{Change, ConversationId, Cursor, Incoming, Mentions};
	use super::*;

	fn batch(sender: Sender) -> Batch {
		Batch {
			events: vec![Incoming {
				cursor: Cursor::new("c1").unwrap(),
				conversation: ConversationId::new("d"),
				kind: Kind::Direct,
				body: Body::Line(Line {
					id: "1".into(),
					sender,
					change: Change::Said,
					text: "hi".into(),
					files: Vec::new(),
					mentions: Mentions::default(),
				}),
			}],
			cursor: Cursor::new("c1").unwrap(),
			gap: false,
			unavailable: false,
			unreadable: 0,
		}
	}

	fn named(peer: &str) -> Names {
		let mut names = Names::default();
		names.peers.insert("d".into(), peer.into());
		names
	}

	fn sender(batch: &Batch) -> &Sender {
		match &batch.events[0].body {
			Body::Line(line) => &line.sender,
			_ => unreachable!(),
		}
	}

	#[tokio::test(start_paused = true)]
	async fn an_unnamed_private_sender_is_named_by_a_later_workspace_without_failing_the_read() {
		let mut unnamed = batch(Sender::Peer(None));
		let mut asked = 0;
		let started = tokio::time::Instant::now();
		let named = name_unnamed(&mut unnamed, &RefCell::default(), async || {
			asked += 1;
			Ok::<_, ()>(if asked < 2 { Names::default() } else { named("ann") })
		})
		.await;
		assert_eq!(named, Ok(()));
		assert_eq!(sender(&unnamed), &Sender::Peer(Some("ann".into())));
		assert_eq!(asked, 2);
		assert_eq!(started.elapsed(), PEER_WAIT * 3);
	}

	#[tokio::test(start_paused = true)]
	async fn a_sender_never_named_is_taken_with_no_name_after_the_last_wait() {
		let mut unnamed = batch(Sender::Peer(None));
		let mut asked = 0;
		let waited = RefCell::default();
		let named = name_unnamed(&mut unnamed, &waited, async || {
			asked += 1;
			Ok::<_, ()>(Names::default())
		})
		.await;
		assert_eq!(named, Ok(()));
		assert_eq!(sender(&unnamed), &Sender::Peer(None));
		assert_eq!(asked, MAX_PEER_WAITS);
		let started = tokio::time::Instant::now();
		let mut again = batch(Sender::Peer(None));
		let named = name_unnamed(&mut again, &waited, async || Err::<Names, _>(())).await;
		assert_eq!(
			named,
			Ok(()),
			"a conversation already waited for is not waited for again"
		);
		assert_eq!(started.elapsed(), Duration::ZERO);
	}

	#[tokio::test(start_paused = true)]
	async fn a_named_batch_asks_nothing_and_a_failed_workspace_read_fails() {
		let mut named = batch(Sender::Peer(Some("ann".into())));
		let asked = name_unnamed(&mut named, &RefCell::default(), async || Err::<Names, _>("asked")).await;
		assert_eq!(asked, Ok(()));
		let mut unnamed = batch(Sender::Peer(None));
		assert_eq!(
			name_unnamed(&mut unnamed, &RefCell::default(), async || Err::<Names, _>("gone")).await,
			Err("gone")
		);
	}
}
