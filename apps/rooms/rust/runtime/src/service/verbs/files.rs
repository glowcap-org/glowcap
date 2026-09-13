//! `sendFiles` and `refileLine` admit file mutations from an attached view.
//! Commands capture bytes from that view before preparing a durable effect.
use super::effects::{conversation_kind, direct_line, send_direct};
use crate::direct::commands::Command;
use crate::rooms::FileCommand;
use crate::service::Platform;
use crate::service::error::Error;
use crate::service::facet::Facet;
use crate::service::facet::Rights;
use glowcap::Argument;
use rooms_application::{
	archive::ConversationKind,
	room::ArgumentView,
	session::{state::OperationId, verbs},
};
use rooms_glowcap::{
	Value,
	client::{Client, files::File, sources::Source},
};
use std::{collections::HashSet, rc::Rc};

const SEND_SHAPE: &str =
	"sendFiles takes an operation id, base revision, conversation, caption, preview selection, and file records";
const REFILE_SHAPE: &str =
	"refileLine takes an operation id, base revision, conversation, line id, caption, kept indices, and file records";

pub fn send<P: Platform>(facet: &Facet<P>, rights: &Rights, args: &[Argument]) -> Result<Argument, Error> {
	if !rights.may_interact() {
		return Err(Error::refused("this Rooms session facet cannot change files"));
	}
	let [id, base, conversation, caption, encoded, records @ ..] = args else {
		return Err(Error::invalid(SEND_SHAPE));
	};
	let id = operation(id)?;
	let base = revision(base).ok_or_else(|| Error::invalid(SEND_SHAPE))?;
	let conversation = conversation.as_str().ok_or_else(|| Error::invalid(SEND_SHAPE))?;
	let caption = caption.as_str().ok_or_else(|| Error::invalid(SEND_SHAPE))?;
	let previews = rooms_application::open_graph::Selection::decode(
		caption,
		encoded.as_str().ok_or_else(|| Error::invalid(SEND_SHAPE))?,
	)
	.map_err(Error::invalid_by)?;
	let files = sources(facet.0.platform.clone(), records)?;
	if files.is_empty() {
		return Err(Error::invalid("sendFiles takes at least one valid file record"));
	}
	prepare(
		facet,
		id,
		base,
		conversation,
		FileCommand::Send {
			caption: caption.into(),
			previews,
			files,
		},
	)?
	.wire(facet, verbs::SEND_FILES)
}

pub fn refile<P: Platform>(facet: &Facet<P>, rights: &Rights, args: &[Argument]) -> Result<Argument, Error> {
	if !rights.may_interact() {
		return Err(Error::refused("this Rooms session facet cannot change files"));
	}
	let [id, base, conversation, line, caption, rest @ ..] = args else {
		return Err(Error::invalid(REFILE_SHAPE));
	};
	let id = operation(id)?;
	let base = revision(base).ok_or_else(|| Error::invalid(REFILE_SHAPE))?;
	let conversation = conversation
		.as_str()
		.ok_or_else(|| Error::invalid("refileLine takes a conversation id"))?;
	let line = revision(line).ok_or_else(|| Error::invalid("refileLine takes a positive line id"))?;
	let caption = caption
		.as_str()
		.ok_or_else(|| Error::invalid("refileLine takes a caption"))?;
	let mut keep = Vec::new();
	let mut seen = HashSet::new();
	let mut at = 0;
	while let Some(Argument::Integer(index)) = rest.get(at) {
		let index = u32::try_from(*index).map_err(|_| Error::invalid("refileLine has invalid kept indices"))?;
		if !seen.insert(index) {
			return Err(Error::invalid("refileLine has invalid kept indices"));
		}
		keep.push(index);
		at += 1;
	}
	let files = sources(facet.0.platform.clone(), &rest[at..])?;
	prepare(
		facet,
		id,
		base,
		conversation,
		FileCommand::Refile {
			line,
			caption: caption.into(),
			keep,
			files,
		},
	)?
	.wire(facet, verbs::REFILE_LINE)
}

pub(in crate::service) fn prepare<P: Platform>(
	facet: &Facet<P>,
	id: OperationId,
	base: u64,
	conversation: &str,
	command: FileCommand,
) -> Result<crate::service::revision::Revision, Error> {
	use crate::service::revision::Revision;
	if matches!(&command, FileCommand::Send { files, .. } if files.is_empty()) {
		return Err(Error::invalid("sendFiles takes at least one valid file record"));
	}
	match conversation_kind(&facet.0.commands.view(), conversation)? {
		ConversationKind::Direct => {
			let command = match command {
				FileCommand::Send {
					caption,
					previews,
					files,
				} => Command::Send {
					text: caption,
					previews,
					files,
				},
				FileCommand::Refile {
					line,
					caption,
					keep,
					files,
				} => Command::Refile {
					line: direct_line(facet, line)?,
					text: caption,
					keep,
					files,
				},
			};
			send_direct(facet, id, base, conversation, command)
		}
		ConversationKind::Room => {
			let admission = facet.0.rooms.prepare_files(id, base, conversation, command)?;
			Ok(Revision::new(async move { admission.run().await }))
		}
	}
}

fn operation(value: &Argument) -> Result<OperationId, Error> {
	super::checkpoint::operation_id(
		value
			.as_str()
			.ok_or_else(|| Error::invalid("invalid session operation id"))?,
	)
}

fn revision(value: &Argument) -> Option<u64> {
	ArgumentView::integer(&Value(value)).and_then(|n| u64::try_from(n).ok())
}

/// The file records an attached view sent, each readable back over the
/// view's own session.
fn sources<P: Platform>(platform: P, args: &[Argument]) -> Result<Vec<Source>, Error> {
	let views: Vec<_> = args.iter().map(Value).collect();
	let attachments = rooms_application::room::attachment::read_exact(&views, 0)
		.map_err(|refusal| Error::invalid(format!("{refusal:?}")))?;
	let session =
		glowcap::current_session()?.ok_or_else(|| Error::invalid("sendFiles is reachable only over a session"))?;
	let client = Client::new(session, platform);
	Ok(attachments
		.into_iter()
		.map(|attachment| {
			Source::reader(
				attachment.description.clone(),
				BlobRead(Rc::new(File::received(client.clone(), attachment))),
			)
		})
		.collect())
}

struct BlobRead<P: Platform>(Rc<File<P>>);
impl<P: Platform> rooms_glowcap::client::sources::Reader for BlobRead<P> {
	fn read(
		&self,
		offset: usize,
		length: usize,
	) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<Vec<u8>, String>>>> {
		let file = self.0.clone();
		Box::pin(async move {
			file.read(offset as u64, length)
				.await
				.map_err(|error| Error::peer(error).into_refusal())
		})
	}
}
