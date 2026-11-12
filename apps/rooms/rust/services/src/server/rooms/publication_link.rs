//! Saving an existing source-owned link selects the exact listed publication.
use super::{
	selection::{self, Selected},
	*,
};
use rooms_application::directory::creation;

pub(in crate::server) fn link_publication(
	shared: &Shared,
	connection: u64,
	args: &[Argument],
) -> Result<Argument, String> {
	let [Argument::String(id)] = args else {
		return Err("linkPublication needs one exact publication ID".into());
	};
	if !rooms_application::fields::Text::<128, true>::accepts_utf16(id.encode_utf16()) {
		return Err("invalid publication ID".into());
	}
	let mut state = shared.borrow_mut();
	match selection::saved(&mut state, connection, id)? {
		Selected::Irc(publication) => {
			let session = selection::session(&state, connection)?;
			drop(state);
			super::super::irc::rooms::call(
				shared,
				&publication,
				rooms_application::room::policy::MembershipKind::Participant,
				connection,
				&session,
				LINK,
				&[],
			)
		}
		Selected::Foreign(entrance) => {
			// Another server's room is answered later, so the call takes its
			// seat and then its charge. The bounded answer owner retains the
			// selected source across this wait. A replacement publication
			// cannot retarget the already accepted request.
			let seat = state.reserve()?;
			state.admit_work(connection, rooms_application::admission::Class::Read, 1)?;
			let host = state.host.clone();
			super::super::answer::later(&state, seat, creation::LINK_PUBLICATION, async move {
				host.send(&entrance, LINK, &[])
					.await
					.map_err(super::super::answer::relayed_refusal)
			})
		}
		Selected::Local(entrance) => {
			let session = selection::session(&state, connection)?;
			super::call(shared, &mut state, connection, &session, &entrance, LINK, &[])
		}
	}
}
