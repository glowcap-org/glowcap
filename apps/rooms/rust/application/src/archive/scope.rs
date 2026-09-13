//! Archive filters select records by source, conversation, and digest.
use super::{
	ConversationKind, Error, Kind, Record, ShareKind,
	records::{self, Body},
};
use crate::text::DocumentText;
use alloc::string::String;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Filter {
	#[serde(deserialize_with = "Option::deserialize")]
	pub source: Option<DocumentText>,
	#[serde(deserialize_with = "Option::deserialize")]
	pub generation: Option<DocumentText>,
	#[serde(deserialize_with = "Option::deserialize")]
	pub kind: Option<Kind>,
	#[serde(deserialize_with = "Option::deserialize")]
	pub conversation_kind: Option<ConversationKind>,
	#[serde(deserialize_with = "Option::deserialize")]
	pub directory: Option<DocumentText>,
	#[serde(deserialize_with = "Option::deserialize")]
	pub conversation: Option<DocumentText>,
	#[serde(deserialize_with = "Option::deserialize")]
	pub digest: Option<String>,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Access {
	Read,
	ReadWrite,
}
impl Filter {
	pub fn retained_bytes(&self) -> usize {
		[&self.source, &self.generation, &self.directory, &self.conversation]
			.into_iter()
			.flatten()
			.map(DocumentText::heap_bytes)
			.sum::<usize>()
			+ self.digest.as_ref().map_or(0, String::capacity)
	}
	pub fn validate(&self) -> Result<(), Error> {
		for id in [&self.source, &self.generation].into_iter().flatten() {
			records::opaque(id)?;
		}
		if let Some(directory) = &self.directory {
			records::bounded_text(directory, super::MAX_CONTEXT_BYTES, false)?;
		}
		if let Some(conversation) = &self.conversation {
			records::bounded_text(conversation, super::MAX_CONVERSATION_BYTES, false)?;
		}
		if self.digest.as_deref().is_some_and(|digest| !records::digest(digest)) {
			return Err(Error::Filter);
		}
		Ok(())
	}
	pub fn matches(&self, record: &Record) -> bool {
		self.source.as_ref().is_none_or(|s| s == &record.coordinates().source)
			&& self
				.generation
				.as_ref()
				.is_none_or(|s| s == &record.coordinates().generation)
			&& self.kind.is_none_or(|kind| kind == record.kind())
			&& self
				.conversation_kind
				.is_none_or(|kind| Some(kind) == record.conversation_kind())
			&& self.directory.as_ref().is_none_or(|s| s == record.directory())
			&& self.conversation.as_ref().is_none_or(|s| s == record.conversation())
			&& self.digest.as_deref().is_none_or(|digest| match record.body() {
				Body::Line { attachments, .. } => attachments.iter().any(|a| a.blob() == Some(digest)),
				_ => false,
			})
	}
	/// None is the empty intersection, distinct from the unrestricted filter.
	pub fn intersect(&self, asked: &Self) -> Option<Self> {
		fn dimension<T: Clone + PartialEq>(held: &Option<T>, asked: &Option<T>) -> Option<Option<T>> {
			match (held, asked) {
				(None, v) | (v, None) => Some(v.clone()),
				(Some(a), Some(b)) if a == b => Some(Some(a.clone())),
				_ => None,
			}
		}
		let next = Self {
			source: dimension(&self.source, &asked.source)?,
			generation: dimension(&self.generation, &asked.generation)?,
			kind: dimension(&self.kind, &asked.kind)?,
			conversation_kind: dimension(&self.conversation_kind, &asked.conversation_kind)?,
			directory: dimension(&self.directory, &asked.directory)?,
			conversation: dimension(&self.conversation, &asked.conversation)?,
			digest: dimension(&self.digest, &asked.digest)?,
		};
		if next.kind == Some(Kind::Standing) && (next.conversation_kind.is_some() || next.digest.is_some()) {
			None
		} else {
			Some(next)
		}
	}
	pub fn shared(kind: ShareKind, directory: DocumentText, conversation: Option<DocumentText>) -> Result<Self, Error> {
		let (kind, conversation_kind) = match kind {
			ShareKind::Standing => (Kind::Standing, None),
			ShareKind::Room | ShareKind::Direct => {
				if conversation.is_none() {
					return Err(Error::Filter);
				}
				(
					Kind::Line,
					Some(if kind == ShareKind::Room {
						ConversationKind::Room
					} else {
						ConversationKind::Direct
					}),
				)
			}
		};
		let scope = Self {
			kind: Some(kind),
			conversation_kind,
			directory: Some(directory),
			conversation,
			..Self::default()
		};
		scope.validate()?;
		Ok(scope)
	}
}
pub struct Facet {
	scope: Filter,
	access: Access,
}
impl Facet {
	pub fn new(scope: Filter, access: Access) -> Result<Self, Error> {
		scope.validate()?;
		Ok(Self { scope, access })
	}
	pub fn scope(&self) -> &Filter {
		&self.scope
	}
	pub fn access(&self) -> Access {
		self.access
	}
	pub fn permits_put(&self, record: &Record) -> bool {
		self.access == Access::ReadWrite && self.scope.matches(record)
	}
	pub fn narrow(&self, asked: &Filter, access: Access) -> Result<Self, Error> {
		asked.validate()?;
		if self.access == Access::Read && access == Access::ReadWrite {
			return Err(Error::Access);
		}
		Ok(Self {
			scope: self.scope.intersect(asked).ok_or(Error::Filter)?,
			access,
		})
	}
}
