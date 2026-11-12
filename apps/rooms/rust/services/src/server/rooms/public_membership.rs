//! A public membership retains an exact publication, never a room-name lookup.
use super::{
	selection::{self, Selected},
	*,
};
use rooms_application::directory::creation;

pub(in crate::server) fn subscribe_publication(
	shared: &Shared,
	connection: u64,
	args: &[Argument],
) -> Result<Argument, String> {
	let [
		Argument::String(publication),
		Argument::String(nick),
		Argument::Reference(_),
	] = args
	else {
		return Err("subscribePublication needs a publication, nickname and inbox capability".into());
	};
	if !rooms_application::fields::Text::<128, true>::accepts_utf16(publication.encode_utf16())
		|| !rooms_application::room::inbox::valid_nick(nick)
	{
		return Err("invalid public membership selection".into());
	}
	let mut state = shared.borrow_mut();
	match selection::saved(&mut state, connection, publication)? {
		Selected::Irc(publication) => {
			let session = selection::session(&state, connection)?;
			drop(state);
			super::super::irc::rooms::call(
				shared,
				&publication,
				rooms_application::room::policy::MembershipKind::Participant,
				connection,
				&session,
				SUBSCRIBE,
				&args[1..],
			)
		}
		Selected::Foreign(entrance) => {
			// The source retains its actual entrance and settles the original
			// answer through the bounded server work queue. No second directory
			// selection is made after a wait, and the source still authorizes
			// subscription itself.
			let seat = state.reserve()?;
			state.admit_join(connection, publication)?;
			let host = state.host.clone();
			let subscription = args[1..].to_vec();
			super::super::answer::later(&state, seat, creation::SUBSCRIBE_PUBLICATION, async move {
				host.send(&entrance, SUBSCRIBE, &subscription)
					.await
					.map_err(super::super::answer::relayed_refusal)
			})
		}
		Selected::Local(entrance) => {
			let session = selection::session(&state, connection)?;
			subscribe(shared, &mut state, connection, &session, &entrance, &args[1..])
		}
	}
}
