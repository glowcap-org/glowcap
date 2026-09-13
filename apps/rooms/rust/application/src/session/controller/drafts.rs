//! View-local drafts retain an edit until its matching save settles. A late
//! save may release its own edit, never a newer edit of the same conversation.
use super::Error;
use crate::text::DocumentText;
use alloc::collections::BTreeMap;

const MAX_DRAFTS: usize = 256;
const MAX_BYTES: usize = 4 * 1024 * 1024;
/// Delay after the latest edit before a durable draft save starts.
pub const SAVE_DEBOUNCE_MS: u32 = 150;
struct Draft {
	token: u64,
	text: DocumentText,
}
#[derive(Default)]
pub struct Drafts {
	rows: BTreeMap<DocumentText, Draft>,
	next: u64,
	bytes: usize,
	closed: bool,
}
impl Drafts {
	pub fn stage(&mut self, conversation: DocumentText, text: DocumentText) -> Result<u64, Error> {
		if self.closed {
			return Err(Error::Closed);
		}
		let prior = self.rows.get_key_value(&conversation);
		let old = prior.map_or(0, |(key, draft)| key.heap_bytes() + draft.text.heap_bytes());
		// BTreeMap retains the original key when an equal key is inserted.
		let key_bytes = prior.map_or_else(|| conversation.heap_bytes(), |(key, _)| key.heap_bytes());
		let bytes = self.bytes - old + key_bytes + text.heap_bytes();
		if bytes > MAX_BYTES || (prior.is_none() && self.rows.len() >= MAX_DRAFTS) {
			return Err(Error::Full);
		}
		let token = self.next.checked_add(1).ok_or(Error::Full)?;
		self.rows.insert(conversation, Draft { token, text });
		self.bytes = bytes;
		self.next = token;
		Ok(token)
	}
	pub fn cancel_save(&mut self, conversation: &DocumentText) -> Result<(), Error> {
		if self.closed {
			return Err(Error::Closed);
		}
		if let Some(draft) = self.rows.get_mut(conversation) {
			self.next = self.next.checked_add(1).ok_or(Error::Full)?;
			draft.token = self.next;
		}
		Ok(())
	}
	pub fn pending(&self, conversation: &DocumentText) -> Option<&DocumentText> {
		self.rows.get(conversation).map(|draft| &draft.text)
	}
	pub fn token(&self, conversation: &DocumentText) -> Option<u64> {
		self.rows.get(conversation).map(|draft| draft.token)
	}
	pub fn finish(&mut self, conversation: &DocumentText, token: u64) {
		if self.token(conversation) == Some(token) {
			self.retire(conversation);
		}
	}
	pub fn retire(&mut self, conversation: &DocumentText) {
		if let Some((key, draft)) = self.rows.remove_entry(conversation) {
			self.bytes -= key.heap_bytes() + draft.text.heap_bytes();
		}
	}
	pub fn close(&mut self) {
		self.closed = true;
		self.rows.clear();
		self.bytes = 0;
	}
}
