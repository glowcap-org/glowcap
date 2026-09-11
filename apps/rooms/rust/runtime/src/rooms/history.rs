//! Bounded attachment facts across all memberships. Sparse edits preserve the
//! authoritative selection even when preview admission previously refused it.
use crate::media_files::PreviousFile;
use glowcap::Ref;
use rooms_application::room::{attachment::Attachment, inbox::Message, message::ChangeKind};
use std::collections::BTreeMap;

// The session view and media selection retain at most this many lines.
const MAX_LINES: usize = 2000;
type Key = (String, u64);
#[derive(Default)]
pub(super) struct History(BTreeMap<Key, Line>);
#[derive(Default)]
struct Line {
	attachments: Vec<Attachment<Ref>>,
	captures: Vec<PreviousFile>,
}
impl History {
	pub fn fold(&mut self, key: Key, message: &mut Message<String, Ref>) -> Result<&mut Vec<PreviousFile>, String> {
		let edited = message.marker.is_some_and(|marker| marker.kind == ChangeKind::Edited);
		if edited && !self.0.contains_key(&key) {
			return Err("the edited line's attachment history is no longer retained".into());
		}
		if !self.0.contains_key(&key) && self.0.len() == MAX_LINES {
			self.0.pop_first();
		}
		let line = self.0.entry(key).or_default();
		if edited {
			message.attachments.clone_from(&line.attachments);
		} else {
			line.attachments.clone_from(&message.attachments);
		}
		Ok(&mut line.captures)
	}
	pub fn forget(&mut self, room: &str) {
		self.0.retain(|(held, _), _| held != room);
	}
}
