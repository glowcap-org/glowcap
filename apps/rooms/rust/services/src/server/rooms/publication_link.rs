//! Saving an existing source-owned link selects the exact listed publication.
use super::*;
use rooms_application::directory::creation;

pub(in crate::server) fn link_publication(shared: &Shared, args: &[Argument]) -> Result<Argument, String> {
	let [Argument::String(id)] = args else {
		return Err("linkPublication needs one exact publication ID".into());
	};
	if !rooms_application::fields::Text::<128, true>::accepts_utf16(id.encode_utf16()) {
		return Err("invalid publication ID".into());
	}
	let state = shared.borrow();
	let irc = {
		let core = state.irc.core.borrow();
		core.by_publication(id)
			.and_then(|(key, _)| state.irc.publications.get(key))
			.filter(|publication| publication.active.get())
			.cloned()
	};
	if let Some(publication) = irc {
		drop(state);
		return super::super::irc::rooms::entrance(
			shared.clone(),
			publication,
			rooms_application::room::policy::MembershipKind::Participant,
		)(LINK, &[]);
	}
	if let Some(entrance) = state
		.foreign
		.by_id(id)
		.filter(|entry| entry.is_live())
		.and_then(|entry| entry.room.clone())
	{
		// The bounded answer owner retains the selected source across this wait.
		// A replacement publication cannot retarget the already accepted request.
		let host = state.host.clone();
		return super::super::answer::later(&state, creation::LINK_PUBLICATION, async move {
			host.send(&entrance, LINK, &[]).await.map_err(|error| error.to_string())
		});
	}
	let entrance = state.rooms.enter_publication(id, &state.authority).map_err(refusal)?;
	drop(state);
	super::entrance(shared.clone(), entrance)(LINK, &[])
}
