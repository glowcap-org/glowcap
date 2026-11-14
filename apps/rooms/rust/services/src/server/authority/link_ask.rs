//! Asking for a room's link. The asker is resolved inside the authority job,
//! from what the live rooms and the authority hold when the job runs, so a
//! room recorded, forgotten, renamed, or moderated while the job waited
//! answers as it stands then.
use super::{
	super::{rooms, state::State},
	queue::{Seat, submit_resolved},
	require_manager,
};
use glowcap::Argument;
use rooms_application::{
	protocol_data,
	server::links::{Authority, LinkMaker},
};

/// Who asks for a room's link, and so what the ask may change.
pub(in crate::server) enum Asker {
	/// The manager of this generation of `name`, who makes the link again
	/// after revoking it.
	Manager { name: String, generation: u64 },
	/// The holder of the room's root authority, its private recovery key or
	/// its managed id, who makes a revoked link again.
	Key(String),
	/// Anyone who knows a listed name.
	Name(String),
}

/// A link job's prepare half: the successor authority, and the durable name
/// the link files under, which the commit publishes.
pub(in crate::server) fn prepare_link(
	asker: Asker,
) -> impl FnOnce(&State) -> Result<(Option<Authority>, String), String> {
	move |state| {
		let name = match asker {
			Asker::Manager { name, generation } => {
				require_manager(state, &name, generation)?;
				name
			}
			Asker::Key(name) => name,
			Asker::Name(listed) => listed_link_name(state, &listed)?,
		};
		Ok((state.authority.remembered(&name, false, false, None)?, name))
	}
}

/// `link` from the directory or a manager: persist, publish, answer.
pub(in crate::server) fn link(seat: Seat, asker: Asker) -> Result<Argument, String> {
	submit_resolved(seat, protocol_data::LINK, prepare_link(asker), |state, caller, name| {
		let swiss = state.publish_room(&name)?;
		Ok(state.link_for(&swiss, Some(caller)).map_err(|e| e.to_string())?.into())
	})
}

/// The durable name a listed name's link files under, or why the name is not
/// told the link. The name resolves as `enter` resolves it, and the
/// membership it offers the public decides whether the link is told. A link
/// that was revoked stays revoked while the room has a manager or a key,
/// and that manager or the holder of that key makes the next one.
pub(in crate::server) fn listed_link_name(state: &State, listed: &str) -> Result<String, String> {
	let entrance = state
		.rooms
		.enter(listed, &state.authority)
		.map_err(|refusal| refusal.reason())?;
	rooms::may_tell_link(entrance.kind)?;
	let durable = rooms::room_durable_name(state, &entrance.room, entrance.durable.as_deref());
	let maker = state.authority.room_link_maker(&durable);
	if maker != LinkMaker::Name && state.authority.room_link_revoked(&durable) {
		return Err(no_link(maker).into());
	}
	Ok(durable)
}

/// What a room with no link answers an asker who does not make one.
pub(in crate::server) fn no_link(maker: LinkMaker) -> &'static str {
	match maker {
		LinkMaker::Manager => "this room has no link, and its manager makes the next one",
		LinkMaker::KeyHolder => "this room has no link, and the holder of its room key makes the next one",
		LinkMaker::Name => "this room has no link, and asking the directory for it by name makes one",
	}
}
