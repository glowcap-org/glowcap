//! What holding a line's reference lets somebody do to it, and the same one
//! level up for the room's topic. Neither asks who is calling: possession
//! already answered the question. The topic persists before it is announced
//! when the room has a durable name.
use super::{
	authority, history, rooms,
	state::{Shared, State},
};
use glowcap::Argument;
use rooms_application::{
	room::{ArgumentView, membership::SET_TOPIC},
	server::rooms::{LineKey, RoomKey},
};
use rooms_glowcap::Value;
use std::{cell::Cell, rc::Rc};

/// Own the two-element post reply until CapTP consumes it. The notification ID
/// and line capability must settle together so a sender can acquire exact edit
/// authority without correlating callback arrival or text. One fixed list spine
/// carries a scalar ID and moves the existing capability occurrence; neither
/// payload nor capability custody is copied. Text and file posts share it.
pub(super) fn posted_reply(state: &State, key: LineKey, actor: glowcap::Ref) -> Argument {
	let id = state
		.rooms
		.line_id(key)
		.expect("published line owns its notification identity");
	Argument::List(vec![(id.get() as i64).into(), Argument::Reference(actor)])
}

/// The line capability `post` answers: `edit`, `refile`, and `withdraw`.
pub(super) fn line(
	shared: Shared,
	key: Rc<Cell<Option<LineKey>>>,
) -> impl FnMut(&str, &[Argument]) -> Result<Argument, String> {
	move |verb, args| {
		let values: Vec<Value<'_>> = args.iter().map(Value).collect();
		let mut state = shared.borrow_mut();
		let (connection, _) = rooms::caller(&mut state)?;
		let key = key.get().ok_or("that line has not been published")?;
		let now = state.now();
		history::mutate(&mut state, |rooms| {
			rooms
				.line_verb(connection, key, verb, &values, now)
				.map(|mutation| ((), mutation))
		})?;
		Ok(Argument::Void)
	}
}

/// What this room is about, as a capability every participant holds.
pub(super) fn topic(shared: Shared, room: RoomKey) -> impl FnMut(&str, &[Argument]) -> Result<Argument, String> {
	move |verb, args| {
		if args.iter().any(|arg| Value(arg).contains_capability()) {
			return Err("a room topic does not take capability arguments".into());
		}
		if verb != SET_TOPIC {
			return Err(format!("a topic has no method {verb}"));
		}
		let (Some(said), 1) = (args.first().and_then(Argument::as_str), args.len()) else {
			return Err("setTopic needs one text value".into());
		};
		let state = shared.borrow();
		match state
			.rooms
			.prepare_topic(&room, said, &state.authority)
			.map_err(|refusal| refusal.reason())?
		{
			None => Ok(Argument::Void),
			// The topic persists before the room announces it, so a topic a
			// member hears is one a restart will tell the next arrival.
			Some(successor) => {
				let (room, said) = (room.clone(), said.to_owned());
				authority::submit(
					&state,
					rooms_application::protocol_data::SET_TOPIC,
					move |_| Ok(successor),
					move |state: &mut State, _| {
						let effects = state.rooms.commit_topic(&room, &said);
						state.apply_rooms(effects);
						Ok(Argument::Void)
					},
				)
			}
		}
	}
}
