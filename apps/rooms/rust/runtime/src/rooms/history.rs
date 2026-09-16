//! Bounded attachment facts across all memberships. Sparse edits preserve the
//! authoritative selection even when preview admission previously refused it.
use crate::{Error, files::media_files::PreviousFile};
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
	/// A delegated refile can reorder the peer's selection before its queued
	/// callback reaches us. Protect every known file until that callback folds.
	pub fn attachments(&self, key: &Key) -> Vec<Ref> {
		self.0
			.get(key)
			.map(|line| line.attachments.iter().map(|file| file.blob.clone()).collect())
			.unwrap_or_default()
	}
	pub fn fold(&mut self, key: Key, message: &mut Message<String, Ref>) -> Result<&mut Vec<PreviousFile>, Error> {
		let edited = message.marker.is_some_and(|marker| marker.kind == ChangeKind::Edited);
		if edited && !self.0.contains_key(&key) {
			return Err(Error::stale(
				"the edited line's attachment history is no longer retained",
			));
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
