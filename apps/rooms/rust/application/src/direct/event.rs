//! Direct conversation content distinguishes durable line changes from transient
//! typing levels. Adapters supply ordering, timestamps and conversation custody.
use crate::room::{
	attachment::Attachment,
	message::{ChangeKind, LineId},
};
use alloc::{string::String, vec::Vec};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Direction {
	Incoming,
	Outgoing,
}

pub struct Line<R> {
	pub line: LineId,
	pub text: String,
	pub kind: ChangeKind,
	pub previews: crate::open_graph::Selection,
	/// Said/refiled carry current files; edited preserves the receiver's files
	/// and withdrawn removes them. Bytes remain with their capability owner.
	pub files: Vec<Attachment<R>>,
}
pub enum Content<R> {
	Line(Line<R>),
	Typing { on: bool },
}
impl<R> Content<R> {
	/// Only line changes can contribute an archive record. Typing has neither
	/// a line identity nor attachment custody.
	pub fn line(&self) -> Option<&Line<R>> {
		match self {
			Self::Line(line) => Some(line),
			Self::Typing { .. } => None,
		}
	}
}
