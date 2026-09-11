use super::state::{Seat, Shared};
use glowcap::Argument;
use rooms_application::{
	directory::{self, wire, Shape},
	room::{policy::MembershipKind, ArgumentView},
};
use rooms_glowcap::{snapshot::Arguments, Value};
type Reply = Result<Argument, String>;

fn data(args: &[Argument]) -> Result<(), String> {
	if args.iter().any(|arg| Value(arg).contains_capability()) {
		Err("this IRC bridge method takes only data".into())
	} else {
		Ok(())
	}
}
fn empty(verb: &str, args: &[Argument]) -> Result<(), String> {
	if args.is_empty() {
		Ok(())
	} else {
		Err(format!("{verb} takes no arguments"))
	}
}
pub(super) fn directory(shared: Shared) -> impl FnMut(&str, &[Argument]) -> Reply {
	move |verb, args| {
		let mut state = shared.borrow_mut();
		let (id, session) = state.caller()?;
		if !matches!(verb, "watch" | directory::WATCH) {
			data(args)?;
		}
		let rich = matches!(verb, directory::LIST | directory::WATCH);
		let shape = if rich { Shape::Publication } else { Shape::Baseline };
		match verb {
			"list" | directory::LIST => {
				empty(verb, args)?;
				Ok(wire::rooms::<Arguments>(&[state.room.info()], shape))
			}
			"watch" | directory::WATCH => {
				let [Argument::Reference(inbox)] = args else {
					return Err("watch needs one inbox capability".into());
				};
				let row = state.room.info();
				let (snapshot, replaced) = state
					.directory
					.watch(id, inbox.clone(), shape, [row].into_iter())
					.map_err(|e| e.reason())?;
				if let Some(old) = replaced {
					state.release(old.connection, old.capability);
				}
				Ok(wire::snapshot::<Arguments>(&snapshot, shape))
			}
			"enter" | directory::creation::ENTER_PUBLICATION => {
				let expected = if verb == "enter" {
					state.room.name()
				} else {
					state.room.publication_id()
				};
				if args.len() != 1 || args[0].as_str() != Some(expected) {
					return Err("no-such-room: that IRC room publication is not current".into());
				}
				session
					.spawn_owned(room(shared.clone()))
					.map(Argument::Reference)
					.map_err(|e| e.to_string())
			}
			"open" => Err("an IRC bridge lists channels; it cannot create one".into()),
			_ => Err(format!("IRC bridge directory has no method {verb}")),
		}
	}
}
fn room(shared: Shared) -> impl FnMut(&str, &[Argument]) -> Reply {
	move |verb, args| {
		let mut state = shared.borrow_mut();
		let (id, session) = state.caller()?;
		if verb != "subscribe" {
			data(args)?;
			empty(verb, args)?;
		}
		match verb {
			"called" => Ok(state.room.name().into()),
			"private" => Ok("listed".into()),
			"roomPolicy" => Ok(Argument::List(vec!["listed".into(), "open".into(), "open".into()])),
			"subscribe" => {
				let [Argument::String(nick), Argument::Reference(inbox)] = args else {
					return Err("subscribe needs one name and inbox capability".into());
				};
				state.room.admit_reader(id, nick).map_err(|e| e.reason())?;
				let generation = state
					.generation
					.checked_add(1)
					.ok_or("bridge membership generations exhausted")?;
				let seat = session
					.spawn_owned(membership(shared.clone(), id, generation))
					.map_err(|e| e.to_string())?;
				let note = if state.writable {
					format!("messages are relayed to {} as <{nick}>", state.room.channel())
				} else {
					format!("IRC messages from {} are read-only here", state.room.channel())
				};
				let line_bytes = state.room.line_bytes();
				let effects = state
					.room
					.subscribe(
						id,
						nick,
						inbox.clone(),
						MembershipKind::Participant,
						&note,
						line_bytes,
						&|_| None,
					)
					.map_err(|e| e.reason())?;
				state.generation = generation;
				if let Some(old) = state.seats.insert(
					id,
					Seat {
						generation,
						capability: seat.clone(),
					},
				) {
					state.release(id, old.capability);
				}
				state.apply(effects);
				Ok(Argument::List(vec![
					Argument::Reference(seat),
					"participant".into(),
					Argument::Void,
				]))
			}
			_ => Err(format!("IRC bridge room has no method {verb}")),
		}
	}
}
fn membership(shared: Shared, id: u64, generation: u64) -> impl FnMut(&str, &[Argument]) -> Reply {
	move |verb, args| {
		data(args)?;
		let mut state = shared.borrow_mut();
		let (_, session) = state.caller()?;
		if state.seats.get(&id).is_none_or(|seat| seat.generation != generation) {
			return Err("not-room-member: this IRC bridge membership has ended".into());
		}
		match verb {
			"membershipKind" => {
				empty(verb, args)?;
				Ok("participant".into())
			}
			"leave" => {
				empty(verb, args)?;
				state.retire(id);
				Ok(Argument::Void)
			}
			"away" => {
				let [Argument::String(why)] = args else {
					return Err("away needs one reason".into());
				};
				let effects = state.room.away(id, why).map_err(|e| e.reason())?;
				state.apply(effects);
				Ok(Argument::Void)
			}
			"post" => {
				if !state.writable {
					return Err("this IRC bridge is read-only; posting outward has not been granted".into());
				}
				let [Argument::String(text)] = args else {
					return Err("an IRC bridge post needs exactly one text line".into());
				};
				let post = state.room.prepare_post(id, text).map_err(|e| e.reason())?;
				let answer = state
					.posts
					.post(&session, post, state.room.channel(), state.room.line_bytes())?;
				state.demand();
				Ok(answer)
			}
			_ => Err(format!("IRC bridge membership has no method {verb}")),
		}
	}
}
