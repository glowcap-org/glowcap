//! A public membership retains an exact publication, never a room-name lookup.
use super::*;
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
	let irc = {
		let core = state.irc.core.borrow();
		core.by_publication(publication)
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
		)(Some(SUBSCRIBE), &args[1..]);
	}
	if let Some(entrance) = state
		.foreign
		.by_id(publication)
		.filter(|entry| entry.is_live())
		.and_then(|entry| entry.room.clone())
	{
		// The source retains its actual entrance and settles the original answer
		// through the bounded server work queue. No second directory selection is
		// made after a wait, and the source still authorizes subscription itself.
		state.admit_join(connection, publication)?;
		let host = state.host.clone();
		let subscription = args[1..].to_vec();
		return super::super::answer::later(&state, creation::SUBSCRIBE_PUBLICATION, async move {
			host.send(&entrance, SUBSCRIBE, &subscription)
				.await
				.map_err(|error| error.to_string())
		});
	}
	let entrance = state
		.rooms
		.enter_publication(publication, &state.authority)
		.map_err(refusal)?;
	let session = state
		.session(connection)
		.ok_or("a public membership is reachable only over a session")?
		.borrowed();
	subscribe(shared, &mut state, connection, &session, &entrance, &args[1..])
}
