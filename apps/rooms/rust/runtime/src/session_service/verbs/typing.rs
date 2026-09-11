//! `typing`: forward the member's typing state to the live room or direct
//! partner, and let the session's other attached views see it too.
use super::effects::conversation_kind;
use crate::session_service::error::Error;
use crate::session_service::facet::Facet;
use crate::session_service::facet::Rights;
use crate::session_service::Platform;
use glowcap::Argument;
use rooms_application::archive::ConversationKind;

/// How a typing notice from one attached view is attributed to the others:
/// they share the member, so it is neither the member nor a partner typing.
const ANOTHER_VIEW: &str = "Another attached view";

pub fn typing<P: Platform>(facet: &Facet<P>, rights: &Rights, args: &[Argument]) -> Result<Argument, Error> {
	if !rights.may_interact() {
		return Err(Error::refused("this Rooms session facet cannot send typing"));
	}
	let (conversation, on) = match args {
		[Argument::String(conversation), Argument::Boolean(on)] => (conversation.as_str(), *on),
		_ => return Err(Error::refused("typing takes a conversation id and one boolean")),
	};
	let caller = glowcap::current_session()?;
	send(facet, conversation, on, caller.as_ref(), None)?;
	Ok(Argument::Void)
}

pub(in crate::session_service) fn send<P: Platform>(
	facet: &Facet<P>,
	conversation: &str,
	on: bool,
	remote: Option<&glowcap::Session>,
	local: Option<u64>,
) -> Result<(), Error> {
	match conversation_kind(&facet.0.commands.view(), conversation)? {
		ConversationKind::Room => {
			if !facet.0.rooms.connected(conversation) {
				return Ok(());
			}
			facet.0.rooms.typing(conversation, on).map_err(Error::runtime)?;
		}
		ConversationKind::Direct => {
			let context = facet.0.routes.conversation(conversation).map_err(Error::runtime)?;
			facet.0.routes.typing(&context, on).map_err(Error::runtime)?;
		}
	}
	let at = facet
		.0
		.platform
		.unix_millis()
		.map_err(|error| Error::runtime(error.to_string()))?;
	let event = crate::rooms::typing(conversation.to_owned(), ANOTHER_VIEW, on, at);
	facet.deliver_event_excluding(&event, remote, local);
	Ok(())
}
