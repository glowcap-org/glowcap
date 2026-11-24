//! Composite file ingress borrows exact source custody beside scalar intent.
mod admission;
mod direct;
mod transfer;
use super::content::refuse;
use super::executor::Ending;
pub(super) use admission::{admit, references};
use glowcap::{Argument, Ref, Result, loam};
pub(super) use rooms_application::content::session::uploads::{Intent, Kind};
use rooms_application::content::session::{
	effects::OBSERVATION_MS,
	uploads::{Description, Outcome},
};
use rooms_application::{
	content::session::{custody, workspace},
	room::{attachment, line::MAX_MESSAGE_FILES},
};
pub(super) enum Pipeline {
	Room(transfer::Pipeline),
	Direct(direct::Pipeline),
}
impl Pipeline {
	pub fn new(
		host: glowcap::Host,
		continuation: loam::Continuation,
		intent: Intent,
		released: std::rc::Rc<std::cell::Cell<bool>>,
		reply_bytes: usize,
		direct: bool,
	) -> Self {
		if direct {
			Self::Direct(direct::Pipeline::new(continuation, intent, reply_bytes))
		} else {
			Self::Room(transfer::Pipeline::new(
				host,
				continuation,
				intent,
				released,
				reply_bytes,
			))
		}
	}
	/// Run the upload to its ending. `Ok(None)` means it had already ended.
	pub async fn advance<P: rooms_glowcap::client::Deadline + Clone + 'static>(
		&mut self,
		platform: &P,
	) -> Result<Option<Ending>> {
		match self {
			Self::Room(pipeline) => pipeline.advance(platform).await,
			Self::Direct(pipeline) => platform
				.within(OBSERVATION_MS, pipeline.advance())
				.await
				.ok_or_else(|| super::executor::paused("upload observation deadline expired"))?,
		}
	}
}
pub(super) struct Request {
	pub intent: Intent,
	pub sources: Vec<Ref>,
}
impl Request {
	/// At most eight descriptions and exact source retains survive admission.
	/// No source bytes are read or assembled here. Shared preparation owns live
	/// source fields before the callback stages the receipt.
	pub fn read(verb: &str, args: &[Argument]) -> Result<Self> {
		let (id, base, conversation, caption, previews, keep, files, kind) = match (verb, args) {
			("sendFiles", [id, base, conversation, caption, previews, files @ ..]) => (
				id,
				base,
				conversation,
				caption,
				Some(previews),
				Vec::new(),
				files,
				Kind::Post,
			),
			("refileLine", [id, base, conversation, line, caption, rest @ ..]) => {
				let line = line
					.as_i64()
					.and_then(|n| u64::try_from(n).ok())
					.filter(|n| rooms_application::room::message::LineId::new(*n).is_some())
					.ok_or_else(|| refuse("positive original line required"))?;
				let at = rest
					.iter()
					.take_while(|arg| matches!(arg, Argument::Integer(_)))
					.count();
				if at > MAX_MESSAGE_FILES {
					return Err(refuse("too many kept files"));
				}
				let mut keep = Vec::with_capacity(at);
				for arg in &rest[..at] {
					let index = arg
						.as_i64()
						.and_then(|n| u32::try_from(n).ok())
						.ok_or_else(|| refuse("invalid kept index"))?;
					if keep.contains(&index) {
						return Err(refuse("duplicate kept index"));
					}
					keep.push(index);
				}
				(
					id,
					base,
					conversation,
					caption,
					None,
					keep,
					&rest[at..],
					Kind::Refile(line),
				)
			}
			_ => return Err(refuse("invalid upload request")),
		};
		let text = super::content::text;
		let id = text(id)?;
		if !rooms_application::session::state::OperationId::accepts_utf16(id.encode_utf16()) {
			return Err(refuse("invalid upload operation id"));
		}
		let base = base
			.as_i64()
			.and_then(|n| u64::try_from(n).ok())
			.filter(|n| rooms_application::session::state::SafeInteger::<false>::new(*n).is_some())
			.ok_or_else(|| refuse("invalid upload revision"))?;
		let conversation = text(conversation)?;
		if !workspace::Id::accepts_utf16(conversation.encode_utf16()) {
			return Err(refuse("invalid upload conversation"));
		}
		let caption = text(caption)?;
		if caption.len() > rooms_application::room::line::MAX_LINE_BYTES {
			return Err(refuse("upload caption exceeds limit"));
		}
		let previews = previews.map(text).transpose()?.unwrap_or("[]");
		let previews = rooms_application::open_graph::Selection::decode(caption, previews)
			.map_err(|_| refuse("invalid upload previews"))?
			.encode();
		if files.len() > MAX_MESSAGE_FILES * attachment::RECORD_SPAN {
			return Err(refuse("upload file records exceed limit"));
		}
		let values: Vec<_> = rooms_glowcap::values(files).collect();
		let attachments = attachment::read_exact(&values, 0).map_err(|_| refuse("invalid upload file records"))?;
		if (kind == Kind::Post && attachments.is_empty()) || attachments.len() + keep.len() > MAX_MESSAGE_FILES {
			return Err(refuse("upload file selection exceeds limit"));
		}
		let mut descriptions = Vec::with_capacity(attachments.len());
		let mut sources = Vec::with_capacity(attachments.len());
		for attachment in attachments {
			descriptions.push(Description::from_file(&attachment.description));
			sources.push(attachment.blob);
		}
		Ok(Self {
			intent: Intent {
				upload: kind,
				operation: id.into(),
				base,
				conversation: conversation.into(),
				caption: caption.into(),
				previews,
				keep: rooms_application::fields::List::new(keep).ok_or_else(|| refuse("too many kept files"))?,
				files: rooms_application::fields::List::new(descriptions)
					.ok_or_else(|| refuse("too many upload source files"))?,
			},
			sources,
		})
	}
}
pub(super) fn matches(data: &str, fields: &[custody::Coordinate]) -> Result<bool> {
	let outcome: Outcome = serde_json::from_str(data).map_err(|_| loam::refusal("invalid upload outcome"))?;
	if outcome.files_complete != outcome.failure.is_none() {
		return Err(refuse("upload outcome completion differs from failure"));
	}
	Ok(match (outcome.line, fields) {
		(None, []) => true,
		(Some(key), [field]) => {
			field.role == custody::Role::Line
				&& field.key.slot() == key.slot()
				&& field.key.generation() == key.generation()
		}
		_ => false,
	})
}

/// An acknowledged post, ready to be settled. Building it checks everything
/// settling needs, so [`Posted::finish`] cannot fail: it holds the outcome of
/// a complete upload and the outcome that stands in when a failure's own
/// text is not admitted.
pub(super) struct Posted {
	outcome: Outcome,
	second: Argument,
	complete: String,
	standing: String,
}
impl Posted {
	/// One outcome contract for accepted room uploads and direct reader
	/// delivery.
	pub(super) fn read(
		settlement: super::results::Settlement,
		reply: rooms_application::session::effect::Reply,
	) -> Result<Self> {
		let Argument::List(mut fields) = settlement.0 else {
			return Err(refuse("invalid file settlement"));
		};
		let (Some(second), Some(data), true) = (fields.pop(), fields.pop(), fields.is_empty()) else {
			return Err(refuse("invalid file settlement fields"));
		};
		let (line, id, history) = if reply == rooms_application::session::effect::Reply::Line {
			let posted = serde_json::from_str::<rooms_application::content::session::results::PostedLine>(
				data.as_str().ok_or_else(|| refuse("invalid file line"))?,
			)
			.map_err(|_| refuse("invalid file line result"))?;
			(posted.line, posted.id, posted.history)
		} else {
			(None, None, None)
		};
		let mut outcome = Outcome {
			line,
			id,
			history,
			files_complete: true,
			failure: None,
		};
		let complete = serde_json::to_string(&outcome).map_err(|_| refuse("invalid file outcome"))?;
		outcome.files_complete = false;
		outcome.failure = Some(
			rooms_application::fields::Text::new("the line stands, but its files could not be completed".into())
				.ok_or_else(|| refuse("upload failure text is not admitted"))?,
		);
		let standing = serde_json::to_string(&outcome).map_err(|_| refuse("invalid file outcome"))?;
		Ok(Self {
			outcome,
			second,
			complete,
			standing,
		})
	}
	/// The settlement of the line with its files complete, or with them
	/// incomplete for `failure`, which stands in words of its own when the
	/// session admits them as text.
	pub(super) fn finish(mut self, failure: Option<String>) -> super::results::Settlement {
		let data = match failure {
			None => self.complete,
			Some(failure) => match rooms_application::fields::Text::new(failure.into()) {
				Some(text) => {
					self.outcome.failure = Some(text);
					serde_json::to_string(&self.outcome).unwrap_or(self.standing)
				}
				None => self.standing,
			},
		};
		super::results::Settlement(Argument::List(vec![data.into(), self.second]))
	}
}
