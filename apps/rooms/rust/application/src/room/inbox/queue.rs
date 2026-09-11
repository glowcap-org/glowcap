//! Bounded unread messages. One consumer polls; dropping it closes this queue.
use super::{metadata::Presence, Message};
use alloc::{collections::VecDeque, string::String};

pub const MAX_MESSAGES: usize = 256;
pub const MAX_MESSAGE_BYTES: usize = 2 * 1024 * 1024;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
	Overflow,
	Closed,
}
impl core::fmt::Display for Error {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		f.write_str(match self {
			Self::Overflow => "room message backlog exceeded its line or byte limit",
			Self::Closed => "room message stream is closed",
		})
	}
}
impl core::error::Error for Error {}

pub struct Queue<C> {
	unread: VecDeque<(Message<String, C>, usize)>,
	bytes: usize,
	terminal: Option<Error>,
}
impl<C> Default for Queue<C> {
	fn default() -> Self {
		Self {
			unread: VecDeque::new(),
			bytes: 0,
			terminal: None,
		}
	}
}
impl<C> Queue<C> {
	/// Account before copying retained text. Attachment descriptions already
	/// came through their small fixed record bounds; original wire custody
	/// remains in the binding until this call returns.
	pub fn push(&mut self, message: Message<&str, C>) -> Result<(), Error> {
		if let Some(error) = self.terminal {
			return Err(error);
		}
		let bytes = retained_bytes(&message);
		if self.unread.len() == MAX_MESSAGES || bytes > MAX_MESSAGE_BYTES.saturating_sub(self.bytes) {
			self.finish(Error::Overflow);
			return Err(Error::Overflow);
		}
		self.bytes += bytes;
		self.unread.push_back((message.into_owned(), bytes));
		Ok(())
	}
	pub fn pop(&mut self) -> Result<Option<Message<String, C>>, Error> {
		if let Some((message, bytes)) = self.unread.pop_front() {
			self.bytes -= bytes;
			return Ok(Some(message));
		}
		if let Some(error) = self.terminal {
			return Err(error);
		}
		Ok(None)
	}
	pub fn close(&mut self) {
		if self.terminal.is_none() {
			self.finish(Error::Closed);
		}
	}
	fn finish(&mut self, reason: Error) {
		self.terminal = Some(reason);
		self.unread = VecDeque::new();
		self.bytes = 0;
	}
}
fn retained_bytes<C>(message: &Message<&str, C>) -> usize {
	// Each copied string requests exactly its UTF-8 length. Include the owned
	// struct, retained vector slots, descriptions and capability handles.
	let mut bytes = core::mem::size_of::<Message<String, C>>() + message.from.len() + message.text.len();
	if let Some(presence) = &message.presence {
		presence.visit(|text| bytes = bytes.saturating_add(text.len()));
		if matches!(presence, Presence::Seat(_)) {
			bytes = bytes.saturating_add(core::mem::size_of::<super::metadata::Seat<String>>());
		}
		if let Presence::Roster { names } = presence {
			bytes = bytes.saturating_add(names.len().saturating_mul(core::mem::size_of::<String>()));
		}
	}
	if let Some(facts) = &message.facts {
		facts.visit(|text| bytes = bytes.saturating_add(text.len()));
		if facts.bridge.is_some() {
			bytes = bytes.saturating_add(core::mem::size_of::<super::metadata::Bridge<String>>());
		}
	}
	bytes = bytes.saturating_add(
		message
			.attachments
			.capacity()
			.saturating_mul(core::mem::size_of::<super::Attachment<C>>()),
	);
	for file in &message.attachments {
		bytes = bytes.saturating_add(file.description.retained_bytes());
	}
	bytes
}
