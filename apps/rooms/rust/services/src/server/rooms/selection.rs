//! Which room a directory verb names. A bridged IRC channel, another server's
//! listed room, and a room this server holds are looked for in that one order.
use super::*;
use crate::server::irc::Publication;

/// How a caller names a room: by the name it is listed under, or by the exact
/// publication it saved.
#[derive(Clone, Copy)]
pub(super) enum By<'a> {
	Name(&'a str),
	Publication(&'a str),
}

pub(super) enum Selected {
	Irc(Rc<Publication>),
	/// The capability the room's own server published, never a proxy through
	/// this process.
	Foreign(Ref),
	Local(Entrance),
}

/// The room `by` names, or the refusal that it names none. Selecting reads
/// tables and changes nothing, so the caller charges for what it does next.
pub(super) fn select(state: &State, by: By<'_>) -> Result<Selected, String> {
	let irc = {
		let core = state.irc.core.borrow();
		match by {
			By::Name(name) => core.by_room_name(name),
			By::Publication(id) => core.by_publication(id),
		}
		.and_then(|(key, _)| state.irc.publications.get(key))
		.filter(|publication| publication.active.get())
		.cloned()
	};
	if let Some(publication) = irc {
		return Ok(Selected::Irc(publication));
	}
	let foreign = match by {
		By::Name(name) => state.foreign.by_name(name),
		By::Publication(id) => state.foreign.by_id(id).filter(|entry| entry.is_live()),
	};
	if let Some(room) = foreign.and_then(|entry| entry.room.clone()) {
		return Ok(Selected::Foreign(room));
	}
	match by {
		By::Name(name) => state.rooms.enter(name, &state.authority),
		By::Publication(id) => state.rooms.enter_publication(id, &state.authority),
	}
	.map(Selected::Local)
	.map_err(refusal)
}

/// The session a directory verb answers, which holds what the verb spawns.
pub(super) fn session(state: &State, connection: u64) -> Result<glowcap::Session, String> {
	state
		.session(connection)
		.map(glowcap::Session::borrowed)
		.ok_or_else(|| "a room is reachable only over a session".into())
}

/// The room a saved publication names, for a verb the room itself answers
/// and charges. Naming no room is the directory's own answer, charged one read.
pub(super) fn saved(state: &mut State, connection: u64, id: &str) -> Result<Selected, String> {
	select(state, By::Publication(id)).or_else(|missing| {
		state.admit_work(connection, rooms_application::admission::Class::Read, 1)?;
		Err(missing)
	})
}
