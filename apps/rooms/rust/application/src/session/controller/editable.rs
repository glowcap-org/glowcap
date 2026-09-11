//! Bounded edit targets from admitted session events. Rendered history does not
//! confer edit rights; the session checks its held line authority on invocation.
use crate::{room::message::ChangeKind, session::event::Event};
use alloc::{collections::VecDeque, string::String};

const MAX_LINES: usize = 2000;
const MAX_BYTES: usize = 256 * 1024;
#[derive(Default)]
pub struct Editable {
	source: Option<String>,
	lines: VecDeque<(String, u64)>,
	bytes: usize,
}
impl Editable {
	pub fn receive<C>(&mut self, event: &Event<C>) {
		if self.source.as_deref() != Some(&event.source) {
			self.clear();
			self.source = Some(event.source.clone());
		}
		let Some(line) = event.line_id else { return };
		let existing = self
			.lines
			.iter()
			.position(|(conversation, id)| conversation == &event.conversation_id && *id == line);
		if !event.editable || event.change == Some(ChangeKind::Withdrawn) {
			if let Some(index) = existing {
				self.remove(index);
			}
			return;
		}
		// Editing an older line must not turn it into the newest posted line.
		if existing.is_some() || event.conversation_id.len() > MAX_BYTES {
			return;
		}
		while self.lines.len() >= MAX_LINES || self.bytes + event.conversation_id.len() > MAX_BYTES {
			self.remove(0);
		}
		self.bytes += event.conversation_id.len();
		self.lines.push_back((event.conversation_id.clone(), line));
	}
	pub fn last(&self, conversation: &str) -> Option<u64> {
		self.lines
			.iter()
			.rev()
			.find_map(|(held, line)| (held == conversation).then_some(*line))
	}
	pub fn clear(&mut self) {
		self.source = None;
		self.lines.clear();
		self.bytes = 0;
	}
	fn remove(&mut self, index: usize) {
		if let Some((conversation, _)) = self.lines.remove(index) {
			self.bytes -= conversation.len();
		}
	}
}
