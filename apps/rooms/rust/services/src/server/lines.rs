//! What holding a line's reference lets somebody do to it, and the same one
//! level up for the room's subject. Neither asks who is calling: possession
//! already answered the question. The subject persists before it is announced
//! when the room has a durable name.
use super::{
	authority, history, rooms,
	state::{Shared, State},
};
use glowcap::Argument;
use rooms_application::{
	room::{ArgumentView, membership::SET_SUBJECT, subject::Subject},
	server::rooms::{LineKey, RoomKey},
};
use rooms_glowcap::Value;
use std::{cell::Cell, rc::Rc};

/// Own the two-element post reply until CapTP consumes it. The notification ID
/// and line capability must settle together so a sender can acquire exact edit
/// authority without correlating callback arrival or text. One fixed list spine
/// carries a scalar ID and moves the existing capability occurrence. Neither
/// payload nor capability custody is copied. Text and file posts share it.
pub(super) fn posted_reply(state: &State, key: LineKey, actor: glowcap::Ref) -> Result<Argument, String> {
	let id = state
		.rooms
		.line_id(key)
		.ok_or("published line has no notification identity")?;
	Ok(Argument::List(vec![
		(id.get() as i64).into(),
		Argument::Reference(actor),
	]))
}

/// The line capability `post` answers: `edit`, `refile`, and `withdraw`.
pub(super) fn line(
	shared: Shared,
	key: Rc<Cell<Option<LineKey>>>,
) -> impl FnMut(Option<&str>, &[Argument]) -> Result<Argument, String> {
	move |verb, args| {
		let verb = verb.ok_or("direct invocation is not supported")?;
		let values: Vec<Value<'_>> = args.iter().map(Value).collect();
		let mut state = shared.borrow_mut();
		let (connection, _) = rooms::caller(&mut state)?;
		if verb != rooms_application::protocol_data::WITHDRAW {
			state.ingress(connection)?;
			state.admit_message(connection, args.first().and_then(Argument::as_str).map_or(0, str::len))?;
		}
		if verb == rooms_application::protocol_data::WITHDRAW {
			state.admit_work(connection, rooms_application::admission::Class::Cleanup, 1)?;
		}
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
/// `setSubject(description, link?)` takes the subject exactly or refuses it,
/// and the room keeps a link without ever calling it.
pub(super) fn subject(
	shared: Shared,
	room: RoomKey,
) -> impl FnMut(Option<&str>, &[Argument]) -> Result<Argument, String> {
	move |verb, args| {
		let verb = verb.ok_or("direct invocation is not supported")?;
		if args.iter().any(|arg| Value(arg).contains_capability()) {
			return Err("a room subject does not take capability arguments".into());
		}
		if verb != SET_SUBJECT {
			return Err(format!("a subject has no method {verb}"));
		}
		let subject = read_subject(args)?;
		let mut state = shared.borrow_mut();
		let (connection, _) = rooms::caller(&mut state)?;
		state.ingress(connection)?;
		state.admit_message(
			connection,
			subject.description().len() + subject.link().map_or(0, str::len),
		)?;
		match state
			.rooms
			.prepare_subject(&room, &subject, &state.authority)
			.map_err(|refusal| refusal.reason())?
		{
			None => Ok(Argument::Void),
			// The subject persists before the room announces it, so a subject
			// a member hears is one a restart will tell the next arrival. The
			// writer prepares from the authority it holds when this job's turn
			// comes, so a change queued ahead of this one is never overwritten.
			Some(_) => {
				let (prepared, room) = ((room.clone(), subject.clone()), room.clone());
				authority::submit(
					&state,
					SET_SUBJECT,
					move |state| {
						let (room, subject) = prepared;
						Ok(state
							.rooms
							.prepare_subject(&room, &subject, &state.authority)
							.map_err(|refusal| refusal.reason())?
							.flatten())
					},
					move |state: &mut State, _| {
						let effects = state.rooms.commit_subject(&room, subject);
						state.apply_rooms(effects);
						Ok(Argument::Void)
					},
				)
			}
		}
	}
}

/// A description and an optional link, the link a sturdyref this build can
/// parse. The room only checks a link's shape, so the full parse is here, at
/// the service that holds the OCapN library.
fn read_subject(args: &[Argument]) -> Result<Subject, String> {
	const USAGE: &str = "setSubject needs a description and an optional link, both text";
	let text = |arg: &Argument| arg.as_str().map(str::to_owned).ok_or(USAGE);
	let (description, link) = match args {
		[description] => (text(description)?, None),
		[description, link] => (text(description)?, Some(text(link)?)),
		_ => return Err(USAGE.into()),
	};
	let subject = Subject::new(description, link)?;
	if let Some(link) = subject.link() {
		glowcap::parse_sturdyref(link, glowcap::CaptpVersion::V1_0)
			.map_err(|_| String::from(rooms_application::room::subject::Invalid::LinkUnreadable))?;
	}
	Ok(subject)
}
