//! Bounded unread messages. One consumer polls. Dropping it closes this queue.
use super::{Message, metadata::Presence};
use alloc::{collections::VecDeque, string::String, vec::Vec};

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
	pending: usize,
	terminal: Option<Error>,
}
impl<C> Default for Queue<C> {
	fn default() -> Self {
		Self {
			unread: VecDeque::new(),
			bytes: 0,
			pending: 0,
			terminal: None,
		}
	}
}
impl<C> Queue<C> {
	/// Account before copying retained text. Attachment descriptions already
	/// came through their small fixed record bounds. Original wire custody
	/// remains in the binding until this call returns.
	pub fn push(&mut self, message: Message<&str, C>) -> Result<(), Error> {
		// The exact-size name iterator creates a new vector with no spare slots.
		let bytes = retained_bytes(&message, |text: &&str| text.len(), Vec::len);
		self.admit(bytes)?;
		self.unread.push_back((message.into_owned(), bytes));
		Ok(())
	}
	/// Adopt reconstructed text directly, charging actual retained capacity.
	pub fn push_owned(&mut self, message: Message<String, C>) -> Result<(), Error> {
		let bytes = retained_bytes(&message, String::capacity, Vec::capacity);
		self.admit(bytes)?;
		self.unread.push_back((message, bytes));
		Ok(())
	}
	fn admit(&mut self, bytes: usize) -> Result<(), Error> {
		if let Some(error) = self.terminal {
			return Err(error);
		}
		if self.unread.len() + self.pending >= MAX_MESSAGES || bytes > MAX_MESSAGE_BYTES.saturating_sub(self.bytes) {
			self.finish(Error::Overflow);
			return Err(Error::Overflow);
		}
		self.bytes += bytes;
		Ok(())
	}
	/// Retained outgoing payloads and unread events spend one shared budget.
	pub fn reserve(&mut self, bytes: usize) -> Result<(), Error> {
		if self.terminal.is_some() {
			return Err(Error::Closed);
		}
		if self.unread.len() + self.pending >= MAX_MESSAGES || bytes > MAX_MESSAGE_BYTES.saturating_sub(self.bytes) {
			return Err(Error::Overflow);
		}
		self.pending += 1;
		self.bytes += bytes;
		Ok(())
	}
	pub fn release(&mut self, bytes: usize) {
		if self.terminal.is_none() {
			self.pending -= 1;
			self.bytes -= bytes;
		}
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
		self.pending = 0;
	}
}
fn retained_bytes<T, C>(
	message: &Message<T, C>,
	size: impl Fn(&T) -> usize,
	name_slots: impl Fn(&Vec<T>) -> usize,
) -> usize {
	// Each copied string requests exactly its UTF-8 length. Include the owned
	// struct, retained vector slots, descriptions and capability handles.
	let mut bytes = core::mem::size_of::<Message<String, C>>() + size(&message.from) + size(&message.text);
	if let Some(presence) = message.presence() {
		presence.visit(|text| bytes = bytes.saturating_add(size(text)));
		if matches!(presence, Presence::Seat(_)) {
			bytes = bytes.saturating_add(core::mem::size_of::<super::metadata::Seat<String>>());
		}
		if let Presence::Roster { names } | Presence::Offline { names } = presence {
			bytes = bytes.saturating_add(name_slots(names).saturating_mul(core::mem::size_of::<String>()));
		}
	}
	if let Some(facts) = message.facts() {
		facts.visit(|text| bytes = bytes.saturating_add(size(text)));
		if facts.bridge.is_some() {
			bytes = bytes.saturating_add(core::mem::size_of::<super::metadata::Bridge<String>>());
		}
	}
	bytes = bytes.saturating_add(message.previews.retained_bytes());
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

#[cfg(test)]
mod tests {
	use super::*;
	use crate::room::inbox::metadata::Metadata;
	use alloc::vec::Vec;

	fn reserved_name<T>(name: T) -> Vec<T> {
		let mut names = Vec::with_capacity(MAX_MESSAGE_BYTES / core::mem::size_of::<T>() + 1);
		names.push(name);
		names
	}
	fn message<T>(presence: Presence<T>, from: T, text: T) -> Message<T, ()> {
		Message {
			from,
			text,
			metadata: Some(Metadata::Presence(presence)),
			marker: None,
			previews: Default::default(),
			attachments: Vec::new(),
		}
	}

	#[test]
	fn owned_presence_charges_unused_name_capacity() {
		for presence in [
			Presence::Roster {
				names: reserved_name(String::from("Ada")),
			},
			Presence::Offline {
				names: reserved_name(String::from("Ada")),
			},
		] {
			let mut queue = Queue::default();
			assert_eq!(
				queue.push_owned(message(presence, "room".into(), "".into())),
				Err(Error::Overflow)
			);
			assert!(matches!(queue.pop(), Err(Error::Overflow)));
		}
	}

	#[test]
	fn copied_presence_does_not_retain_the_borrowed_vectors_spare_capacity() {
		for presence in [
			Presence::Roster {
				names: reserved_name("Ada"),
			},
			Presence::Offline {
				names: reserved_name("Ada"),
			},
		] {
			let mut queue = Queue::default();
			queue.push(message(presence, "room", "")).unwrap();
			let copied = queue.pop().unwrap().unwrap();
			let Some(Presence::Roster { names } | Presence::Offline { names }) = copied.presence() else {
				panic!("presence must survive the copy");
			};
			assert_eq!(names.capacity(), 1, "the copied list reserves only its exact length");
			assert_eq!(queue.bytes, 0, "popping releases the copied message's charge");
		}
	}
}
