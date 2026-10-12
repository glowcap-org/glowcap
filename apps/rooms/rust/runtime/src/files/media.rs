//! Bounded custody of the media a conversation's lines carry. Each line's
//! selection leases its files from one pool. A file shared by sibling lines
//! expires only after its final selection retires. Actors borrow this owner
//! weakly. Selections never keep their line actors alive through a Host cycle.
use crate::{
	Error,
	files::media_files::{FileView, MediaFiles, PreviousFile, Selection},
};
use glowcap::{Ref, Session};
use rooms_application::room::attachment::Attachment;
use rooms_glowcap::client::Deadline;
use std::collections::BTreeMap;

// Matches the view scrollback contract in lib/limits.ts.
const MAX_LINES: usize = 2000;

/// `K` names a line uniquely within this owner: a line id where ids are one
/// namespace, a conversation-qualified pair where several rooms share a pool.
pub struct Media<K: Ord, P: Deadline + Clone + 'static> {
	pool: MediaFiles<P>,
	lines: BTreeMap<K, Vec<Selection>>,
}

impl<K: Ord, P: Deadline + Clone + Default + 'static> Default for Media<K, P> {
	fn default() -> Self {
		Self::new(P::default())
	}
}
impl<K: Ord, P: Deadline + Clone + 'static> Media<K, P> {
	pub fn new(platform: P) -> Self {
		Self {
			pool: MediaFiles::new(platform),
			lines: BTreeMap::new(),
		}
	}
}

impl<K: Ord + Clone, P: Deadline + Clone + 'static> Media<K, P> {
	pub fn uploads(
		&self,
		session: &Session,
		uploads: Vec<(Ref, rooms_glowcap::client::files::capture::Captured)>,
		protected: &[Ref],
	) -> Result<Vec<crate::files::media_files::UploadCapture>, Error> {
		self.pool.uploads(session, uploads, protected)
	}
	/// Admit a line's current attachments, retaining any the line already held
	/// so an edit keeps the bytes it kept. `previous` is updated to what the
	/// line now carries.
	pub fn receive(
		&mut self,
		line: K,
		session: &Session,
		attachments: Vec<Attachment<Ref>>,
		previous: &mut Vec<PreviousFile>,
	) -> Result<Vec<FileView>, Error> {
		let files = self.pool.receive_retaining(session, attachments.clone(), previous)?;
		let selection = files.iter().cloned().map(FileView::select).collect();
		*previous = attachments
			.iter()
			.zip(&files)
			.map(|(attachment, file)| file.previous(attachment.blob.clone()))
			.collect();
		// Acquire new selection leases before releasing the previous set. A file
		// shared by sibling lines expires only after its final selection retires.
		if attachments.is_empty() {
			self.lines.remove(&line);
		} else {
			self.lines.insert(line, selection);
			while self.lines.len() > MAX_LINES {
				self.lines.pop_first();
			}
		}
		Ok(files)
	}
	/// Release every selection whose key `retire` names, when a conversation
	/// leaves this owner.
	pub fn forget(&mut self, retire: impl Fn(&K) -> bool) {
		self.lines.retain(|key, _| !retire(key));
	}
	pub async fn close(&mut self) -> Result<(), Error> {
		self.lines.clear();
		self.pool.close().await
	}
}
