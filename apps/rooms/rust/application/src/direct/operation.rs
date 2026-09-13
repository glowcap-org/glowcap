//! Stable direct-operation material. File identity describes frozen content,
//! and a displayed line number is qualified by its producing event generation.
use crate::files::identity::Identity;
use crate::{room::message::LineId, text::DocumentText};
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LineKey {
	pub generation: [u8; 16],
	pub line: LineId,
}
pub struct Context<'a> {
	pub directory: &'a DocumentText,
	pub conversation: &'a DocumentText,
	pub peer: &'a DocumentText,
	pub registration: &'a str,
}
pub enum Command<'a> {
	Send {
		text: &'a str,
		previews: &'a crate::open_graph::Selection,
		files: &'a [Identity<'a>],
	},
	Edit {
		line: LineKey,
		text: &'a str,
	},
	Refile {
		line: LineKey,
		text: &'a str,
		keep: &'a [u32],
		files: &'a [Identity<'a>],
	},
	Withdraw {
		line: LineKey,
	},
}
impl Command<'_> {
	pub fn material(&self, context: Context<'_>) -> Result<DocumentText, serde_json::Error> {
		if let Self::Send { text, previews, files } = self
			&& !previews.is_empty()
		{
			return serde_json::to_string(&(
				if files.is_empty() { "say" } else { "sendFiles" },
				"direct-v2",
				context.directory,
				context.conversation,
				context.peer,
				context.registration,
				Option::<([u8; 16], u64)>::None,
				text,
				previews.urls(),
				&[] as &[u32],
				files,
			))
			.map(Into::into);
		}
		let (verb, line, text, keep, files) = match self {
			Self::Send { text, files, .. } => (
				if files.is_empty() { "say" } else { "sendFiles" },
				None,
				*text,
				&[][..],
				*files,
			),
			Self::Edit { line, text } => ("editLine", Some(*line), *text, &[][..], &[][..]),
			Self::Refile {
				line,
				text,
				keep,
				files,
			} => ("refileLine", Some(*line), *text, *keep, *files),
			Self::Withdraw { line } => ("withdrawLine", Some(*line), "", &[][..], &[][..]),
		};
		serde_json::to_string(&(
			verb,
			"direct-v1",
			context.directory,
			context.conversation,
			context.peer,
			context.registration,
			line.map(|key| (key.generation, key.line.get())),
			text,
			keep,
			files,
		))
		.map(Into::into)
	}
}
