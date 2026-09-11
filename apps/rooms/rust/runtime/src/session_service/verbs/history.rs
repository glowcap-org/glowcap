//! `readHistory` answers from the session-owned archive, never a remote peer.
use crate::session_service::authority::{Authority, HistoryAccess};
use crate::session_service::error::Error;
use crate::session_service::facet::Facet;
use crate::session_service::Platform;
use glowcap::Argument;
use rooms_application::{
	archive::{ConversationKind, Filter},
	session::verbs,
	text::DocumentText,
};
use rooms_glowcap::archive::record_row;

const SHAPE: &str = "readHistory takes a conversation kind, directory, and conversation";

pub(in crate::session_service) fn read<P: Platform>(
	facet: &Facet<P>,
	authority: &Authority,
	verb: &str,
	args: &[Argument],
) -> Result<Argument, Error> {
	let access = HistoryAccess::new(facet, authority)?;
	let [Argument::String(kind), Argument::String(directory), Argument::String(conversation)] = args else {
		return Err(Error::refused(SHAPE));
	};
	let kind = match kind.as_str() {
		"room" => ConversationKind::Room,
		"direct" => ConversationKind::Direct,
		_ => return Err(Error::refused(SHAPE)),
	};
	let filter = Filter {
		conversation_kind: Some(kind),
		directory: Some(DocumentText::from(directory.as_str())),
		conversation: Some(DocumentText::from(conversation.as_str())),
		..Filter::default()
	};
	let archive = facet.0.archive.clone();
	let combined = verb == verbs::READ_HISTORY_VIEW;
	let answer_verb = if combined {
		verbs::READ_HISTORY_VIEW
	} else {
		verbs::READ_HISTORY
	};
	facet.answer(answer_verb, async move {
		if combined {
			let view = archive
				.read_view(filter)
				.map_err(Error::runtime)?
				.wait()
				.await
				.map_err(Error::runtime)?;
			access.check()?;
			return Ok(Argument::List(vec![
				Argument::Boolean(view.local),
				Argument::Boolean(view.peer),
				Argument::List(view.records.iter().map(|row| record_row(&row.record)).collect()),
			]));
		}
		let rows = archive
			.read(filter)
			.map_err(Error::runtime)?
			.wait()
			.await
			.map_err(Error::runtime)?;
		access.check()?;
		Ok(Argument::List(rows.iter().map(|row| record_row(&row.record)).collect()))
	})
}
