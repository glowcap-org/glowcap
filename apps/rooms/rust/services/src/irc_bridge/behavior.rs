use super::state::{Seat, Shared};
use glowcap::Argument;
use rooms_application::{
	directory::{self, Shape, wire},
	protocol_data,
	room::ArgumentView,
};
use rooms_glowcap::{Value, snapshot::Arguments};
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
		if !matches!(verb, protocol_data::WATCH | directory::WATCH) {
			data(args)?;
		}
		let rich = matches!(verb, directory::LIST | directory::WATCH);
		let shape = if rich { Shape::Publication } else { Shape::Baseline };
		match verb {
			protocol_data::LIST => {
				empty(verb, args)?;
				Ok(wire::rooms::<Arguments>(&[state.room.info()], shape))
			}
			directory::LIST => {
				let after = match args {
					[] => None,
					[Argument::String(cursor)] => Some(
						directory::Cursor::parse(cursor)
							.ok_or("listPublications takes nothing or a page cursor it answered")?,
					),
					_ => return Err("listPublications takes nothing or a page cursor it answered".into()),
				};
				// The bridge lists one channel, held under its publication id.
				let row = state.room.info();
				let key = state.room.publication_id().to_owned();
				let walk = after
					.is_none_or(|cursor| cursor.precedes(row.kind, &key))
					.then_some((key, row));
				Ok(wire::page::<Arguments>(&directory::Page::cut(walk)))
			}
			directory::NAMED => {
				let [Argument::String(name)] = args else {
					return Err("namedPublications takes one public room name".into());
				};
				let row = state.room.info();
				let rows: Vec<_> = row
					.name
					.text()
					.as_str()
					.is_some_and(|listed| listed.to_lowercase() == name.to_lowercase())
					.then_some(row)
					.into_iter()
					.collect();
				Ok(wire::rooms::<Arguments>(&rows, Shape::Publication))
			}
			protocol_data::WATCH | directory::WATCH => {
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
			protocol_data::ENTER | directory::creation::ENTER_PUBLICATION => {
				let expected = if verb == protocol_data::ENTER {
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
			protocol_data::OPEN => Err("an IRC bridge lists channels; it cannot create one".into()),
			_ => Err(format!("IRC bridge directory has no method {verb}")),
		}
	}
}
fn room(shared: Shared) -> impl FnMut(&str, &[Argument]) -> Reply {
	move |verb, args| {
		let mut state = shared.borrow_mut();
		let (id, session) = state.caller()?;
		if verb != protocol_data::SUBSCRIBE {
			data(args)?;
			empty(verb, args)?;
		}
		match verb {
			protocol_data::CALLED => Ok(state.room.name().into()),
			protocol_data::PRIVATE => Ok("listed".into()),
			protocol_data::ROOM_POLICY => Ok(Argument::List(vec!["listed".into(), "open".into(), "open".into()])),
			protocol_data::SUBSCRIBE => {
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
				let kind = state.seat_kind();
				let note = if state.writable {
					format!("messages are relayed to {} as <{nick}>", state.room.channel())
				} else {
					format!("IRC messages from {} are read-only here", state.room.channel())
				};
				let line_bytes = state.room.line_bytes();
				let effects = state
					.room
					.subscribe(id, nick, inbox.clone(), kind, &note, line_bytes, &|_| None)
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
				// No subject facet and no files facet: IRC has no way to
				// carry bytes, and a client that holds nothing draws no control.
				Ok(Argument::List(vec![
					Argument::Reference(seat),
					kind.as_str().into(),
					Argument::Void,
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
			rooms_application::protocol_data::MEMBERSHIP_KIND => {
				empty(verb, args)?;
				Ok(state.seat_kind().as_str().into())
			}
			protocol_data::LEAVE => {
				empty(verb, args)?;
				state.retire(id);
				Ok(Argument::Void)
			}
			protocol_data::AWAY => {
				let [Argument::String(why)] = args else {
					return Err("away needs one reason".into());
				};
				let effects = state.room.away(id, why).map_err(|e| e.reason())?;
				state.apply(effects);
				Ok(Argument::Void)
			}
			protocol_data::POST => {
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
