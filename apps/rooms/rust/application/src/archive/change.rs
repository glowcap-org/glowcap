//! History invalidation carries scope, never a record or file authority. A
//! consumer subscribes before reading and repeats a read invalidated in flight.
use super::{records::bounded_text, ConversationKind, Error, Record, MAX_CONTEXT_BYTES, MAX_CONVERSATION_BYTES};
use crate::{room::ArgumentView, text::DocumentText};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Change {
	All,
	Conversation {
		kind: ConversationKind,
		directory: DocumentText,
		conversation: DocumentText,
	},
}
impl Change {
	pub fn of(record: &Record) -> Option<Self> {
		Some(Self::Conversation {
			kind: record.conversation_kind()?,
			directory: record.directory().clone(),
			conversation: record.conversation().clone(),
		})
	}
	/// No arguments invalidate the whole account; three identify one
	/// conversation. Admission bounds material before copying any field.
	pub fn read(args: &[impl ArgumentView]) -> Result<Self, Error> {
		if args.is_empty() {
			return Ok(Self::All);
		}
		let [kind, directory, conversation] = args else {
			return Err(Error::Filter);
		};
		let kind = match kind.text() {
			Some("room") => ConversationKind::Room,
			Some("direct") => ConversationKind::Direct,
			_ => return Err(Error::Filter),
		};
		let directory = directory.document(MAX_CONTEXT_BYTES).ok_or(Error::Filter)?;
		let conversation = conversation.document(MAX_CONVERSATION_BYTES).ok_or(Error::Filter)?;
		bounded_text(&directory, MAX_CONTEXT_BYTES, false)?;
		bounded_text(&conversation, MAX_CONVERSATION_BYTES, false)?;
		Ok(Self::Conversation {
			kind,
			directory,
			conversation,
		})
	}
}
