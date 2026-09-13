//! Room file retry material binds the intended room, line incarnation, ordered
//! selection and immutable bytes. None of these values creates a capability.
use crate::{files::identity::Identity, room::message::LineId, text::DocumentText};

pub struct Context<'a> {
	pub directory: &'a str,
	pub conversation: &'a str,
	pub room: &'a str,
	pub held: bool,
	/// A handed room is selected by its entry authority, independently of its name.
	pub entry: Option<&'a DocumentText>,
}
#[derive(Clone, Copy)]
pub struct Line {
	pub incarnation: [u8; 16],
	pub membership: u64,
	pub id: LineId,
}
pub enum Command<'a> {
	Send {
		caption: &'a str,
		previews: &'a crate::open_graph::Selection,
		files: &'a [Identity<'a>],
	},
	Refile {
		line: Line,
		caption: &'a str,
		keep: &'a [u32],
		files: &'a [Identity<'a>],
	},
}
impl Command<'_> {
	pub fn material(&self, context: Context<'_>) -> Result<DocumentText, serde_json::Error> {
		if let Self::Send {
			caption,
			previews,
			files,
		} = self && !previews.is_empty()
		{
			return serde_json::to_string(&(
				"sendFiles",
				"room-v2",
				context.directory,
				context.conversation,
				context.room,
				context.held,
				context.entry,
				Option::<([u8; 16], u64, u64)>::None,
				caption,
				previews.urls(),
				&[] as &[u32],
				files,
			))
			.map(Into::into);
		}
		let (verb, line, caption, keep, files) = match self {
			Self::Send { caption, files, .. } => ("sendFiles", None, *caption, &[][..], *files),
			Self::Refile {
				line,
				caption,
				keep,
				files,
			} => ("refileLine", Some(*line), *caption, *keep, *files),
		};
		serde_json::to_string(&(
			verb,
			"room-v1",
			context.directory,
			context.conversation,
			context.room,
			context.held,
			context.entry,
			line.map(|line| (line.incarnation, line.membership, line.id.get())),
			caption,
			keep,
			files,
		))
		.map(Into::into)
	}
}
