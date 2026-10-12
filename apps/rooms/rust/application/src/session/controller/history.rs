//! Fair, bounded history reconciliation. Invalidating an in-flight read makes
//! its result stale and schedules one successor. Failures retry on observation.
use crate::{
	archive::{ConversationKind, change::Change},
	session::checkpoint::Checkpoint,
	text::DocumentText,
};
use alloc::{rc::Rc, vec::Vec};

pub const CONCURRENCY: usize = 4;
#[derive(Clone, PartialEq, Eq)]
pub struct Target {
	pub kind: ConversationKind,
	pub directory: DocumentText,
	pub conversation: DocumentText,
	identity: [Option<DocumentText>; 2],
	archive_peer: Option<DocumentText>,
	held: bool,
}
struct Wanted<'a> {
	kind: ConversationKind,
	directory: &'a DocumentText,
	conversation: &'a DocumentText,
	identity: [Option<&'a DocumentText>; 2],
	archive_peer: Option<&'a DocumentText>,
	held: bool,
}
impl Wanted<'_> {
	fn matches(&self, target: &Target) -> bool {
		self.kind == target.kind
			&& *self.directory == target.directory
			&& *self.conversation == target.conversation
			&& self.held == target.held
			&& self.identity[0] == target.identity[0].as_ref()
			&& self.identity[1] == target.identity[1].as_ref()
			&& self.archive_peer == target.archive_peer.as_ref()
	}
	fn owned(self) -> Target {
		Target {
			kind: self.kind,
			directory: self.directory.clone(),
			conversation: self.conversation.clone(),
			identity: self.identity.map(|value| value.cloned()),
			archive_peer: self.archive_peer.cloned(),
			held: self.held,
		}
	}
}
#[derive(Clone, Copy)]
enum Phase {
	Dirty,
	Ready,
	Failed,
}
struct Row {
	target: Rc<Target>,
	version: u64,
	seen: u64,
	active: Option<u64>,
	phase: Phase,
}
#[derive(Default)]
pub struct History {
	rows: Vec<Row>,
	generation: u64,
	running: usize,
	cursor: usize,
}
/// Consumed exactly once by finish. Adapters close the coordinator when its
/// owner cancels all workers. No detached observer controls a read's lifetime.
pub struct Read {
	pub target: Rc<Target>,
	version: u64,
}
impl History {
	fn generation(&mut self) -> Result<u64, &'static str> {
		self.generation = self
			.generation
			.checked_add(1)
			.ok_or("Rooms history generation exhausted")?;
		Ok(self.generation)
	}
	pub fn observe(&mut self, checkpoint: &Checkpoint) -> Result<(), &'static str> {
		let generation = self.generation()?;
		let archive_peer = checkpoint.archive_peer();
		let rooms = checkpoint.rooms().map(|room| Wanted {
			kind: ConversationKind::Room,
			directory: room.directory.text(),
			conversation: room.id.text(),
			identity: [Some(room.name.text()), room.publication_id.map(|id| id.text())],
			archive_peer,
			held: room.held,
		});
		let directs = checkpoint.directs().map(|direct| Wanted {
			kind: ConversationKind::Direct,
			directory: direct.directory.text(),
			conversation: direct.id.text(),
			identity: [Some(direct.peer.text()), Some(direct.registration.text())],
			archive_peer,
			held: false,
		});
		for wanted in rooms.chain(directs) {
			if let Some(row) = self
				.rows
				.iter_mut()
				.find(|row| row.target.conversation == *wanted.conversation)
			{
				row.seen = generation;
				if !wanted.matches(&row.target) {
					row.target = Rc::new(wanted.owned());
					row.active = None;
					row.phase = Phase::Dirty;
					row.version = generation;
				} else if matches!(row.phase, Phase::Failed) {
					row.phase = Phase::Dirty;
					row.version = generation;
				}
			} else {
				self.rows.push(Row {
					target: Rc::new(wanted.owned()),
					version: generation,
					seen: generation,
					active: None,
					phase: Phase::Dirty,
				});
			}
		}
		self.rows.retain(|row| row.seen == generation);
		Ok(())
	}
	pub fn invalidate(&mut self, change: &Change) -> Result<(), &'static str> {
		let generation = self.generation()?;
		for row in &mut self.rows {
			let matches = match change {
				Change::All => true,
				Change::Conversation {
					kind,
					directory,
					conversation,
				} => {
					*kind == row.target.kind
						&& *directory == row.target.directory
						&& *conversation == row.target.conversation
				}
			};
			if matches {
				row.version = generation;
				row.phase = Phase::Dirty;
			}
		}
		Ok(())
	}
	pub fn next_read(&mut self) -> Option<Read> {
		if self.running >= CONCURRENCY {
			return None;
		}
		let count = self.rows.len();
		for offset in 0..count {
			let index = (self.cursor + offset) % count;
			let row = &mut self.rows[index];
			if row.active.is_some() || !matches!(row.phase, Phase::Dirty) {
				continue;
			}
			self.cursor = index + 1;
			row.active = Some(row.version);
			self.running += 1;
			return Some(Read {
				target: row.target.clone(),
				version: row.version,
			});
		}
		None
	}
	/// Returns true only for a current result. Stale completions free capacity
	/// but cannot mark a newer intent loaded or overwrite its displayed history.
	pub fn finish(&mut self, read: Read, succeeded: bool) -> bool {
		self.running = self.running.saturating_sub(1);
		let Some(row) = self.rows.iter_mut().find(|row| Rc::ptr_eq(&row.target, &read.target)) else {
			return false;
		};
		if row.active != Some(read.version) {
			return false;
		}
		row.active = None;
		if row.version != read.version {
			return false;
		}
		row.phase = if succeeded { Phase::Ready } else { Phase::Failed };
		true
	}
	/// Cancel targets while admitted reads retire through finish. Their slots
	/// still count toward the four-read bound until the effects end.
	pub fn clear(&mut self) {
		self.rows.clear();
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::session::checkpoint::{
		Routes,
		commands::{Command, CommandRoutes},
	};
	use alloc::string::String;

	struct Addresses;
	impl Routes for Addresses {
		fn locator_authority(&self, value: &str) -> Option<String> {
			Some(value.into())
		}
		fn sturdyref_authority(&self, value: &str) -> Option<String> {
			Some(value.into())
		}
	}
	impl CommandRoutes for Addresses {
		fn authority_token(&self, value: &str) -> Option<String> {
			Some(value.into())
		}
	}

	fn direct_checkpoint() -> Checkpoint {
		let checkpoint = Checkpoint::empty()
			.for_page_directory("directory", None, &Addresses)
			.unwrap();
		Command::OpenDirect
			.apply(
				&checkpoint,
				&[r#"{"kind":"direct","id":"conversation","directory":"directory","peer":"bob","peerRegistrationId":"00000000-0000-0000-0000-000000000000","closed":false,"draft":""}"#.into()],
				&Addresses,
				&(),
			)
			.unwrap()
	}

	#[test]
	fn archive_selection_is_part_of_every_history_read_intent() {
		let checkpoint = direct_checkpoint();
		let mut history = History::default();
		history.observe(&checkpoint).unwrap();
		let initial = history.next_read().unwrap();
		assert!(history.finish(initial, true));
		assert!(history.next_read().is_none());

		let selected = Command::SelectArchive
			.apply(&checkpoint, &["ocapn://archive/s/capability".into()], &Addresses, &())
			.unwrap();
		history.observe(&selected).unwrap();
		assert!(history.next_read().is_some());
	}
}
