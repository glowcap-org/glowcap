//! Operations on one live room seat. The capability identifies the
//! membership. No nickname, account, or calling-session lookup authorizes an
//! act. The seat is minted before its membership is filed, so it answers
//! nothing until the policy has named it.
use super::{
	history, invitations, lines,
	state::{Shared, State},
};
use glowcap::{Argument, current_session};
use rooms_application::{
	bridge,
	failure::FailureCode,
	room::{
		ArgumentView,
		history::VERB as HISTORY,
		invitation::MINT,
		membership::{AWAY, LEAVE, TYPING},
		policy::MembershipKind,
	},
	server::rooms::{MembershipKey, RoomKey},
};
use rooms_glowcap::Value;
use std::{cell::Cell, rc::Rc};

const KIND: &str = rooms_application::protocol_data::MEMBERSHIP_KIND;
const POST: &str = rooms_application::protocol_data::POST;

pub(super) fn refusal(refusal: rooms_application::server::rooms::Refusal) -> String {
	refusal.reason()
}

/// The membership a call on one of its facets is for, and the session it
/// arrived on. Shared by the seat and the files facet, so both refuse a
/// capability argument, an ended membership, and a sessionless caller in
/// the same words. `what` names the facet in those refusals.
pub(super) fn admitted(
	membership: &Cell<Option<MembershipKey>>,
	what: &str,
	verb: &str,
	args: &[Argument],
) -> Result<(MembershipKey, glowcap::Session), String> {
	if args.iter().any(|arg| Value(arg).contains_capability()) {
		return Err(format!("{what} {verb} does not take capability arguments"));
	}
	let Some(membership) = membership.get() else {
		return Err(FailureCode::NotRoomMember.line("this room membership has ended"));
	};
	let session = current_session()
		.map_err(|e| e.to_string())?
		.ok_or_else(|| format!("a {what} is reachable only over a session"))?;
	Ok((membership, session))
}

/// One observer or participant facet for one exact membership. Files go
/// through the separate facet `files::facet` answers, handed over at
/// subscribe only where the room can hold them.
pub(super) fn seat(
	shared: Shared,
	room: RoomKey,
	membership: Rc<Cell<Option<MembershipKey>>>,
) -> impl FnMut(&str, &[Argument]) -> Result<Argument, String> {
	move |verb, args| {
		let (membership, session) = admitted(&membership, "room membership", verb, args)?;
		let mut state = shared.borrow_mut();
		let connection = state.admit(session.borrowed());
		let posting = matches!(
			verb,
			POST | rooms_application::open_graph::ROOM_POST_VERB
				| rooms_application::room::receipt::POST
				| rooms_application::room::correlation::POST
		);
		if verb != LEAVE && !posting {
			state.ingress(connection)?;
		}
		if verb == LEAVE {
			state.admit_work(connection, rooms_application::admission::Class::Cleanup, 1)?;
		}
		let text = |at: usize| args.get(at).and_then(Argument::as_str);
		match verb {
			bridge::ASK if args.is_empty() => Ok(Argument::Void),
			KIND => {
				if !args.is_empty() {
					return Err("membershipKind takes no arguments".into());
				}
				Ok(state
					.rooms
					.membership_kind(&room, membership)
					.map_err(refusal)?
					.as_str()
					.into())
			}
			MINT => {
				let (Some(kind), 1) = (text(0).and_then(MembershipKind::parse), args.len()) else {
					return Err("mintInvitation takes one observer or participant membership kind".into());
				};
				state.rooms.require_participant(&room, membership).map_err(refusal)?;
				state.admit_work(connection, rooms_application::admission::Class::Create, 1)?;
				let key = state.rooms.mint_invitation(&room, membership, kind).map_err(refusal)?;
				let invitation = session
					.spawn_owned(invitations::invitation(shared.clone(), key))
					.map_err(|e| e.to_string())?;
				Ok(Argument::Reference(invitation))
			}
			POST
			| rooms_application::open_graph::ROOM_POST_VERB
			| rooms_application::room::receipt::POST
			| rooms_application::room::correlation::POST => {
				let retained = verb == rooms_application::room::receipt::POST;
				let correlation = if verb == rooms_application::room::correlation::POST {
					Some((
						state
							.connection_of(&session)
							.ok_or("post needs a live calling connection")?,
						text(2)
							.filter(|value| rooms_application::room::correlation::valid(value))
							.ok_or("post needs its bounded operation identity")?,
					))
				} else {
					None
				};
				super::receipts::post(
					&mut state,
					&room,
					membership,
					&session,
					args,
					retained,
					|state, delivery| {
						state.ingress(connection)?;
						let previews = verb != POST;
						if verb == POST && args.len() > 1 {
							return Err(FailureCode::BadAttachment
								.line("post carries trailing args; attach a file with attach()"));
						}
						let expected = if retained || correlation.is_some() {
							3
						} else if previews {
							2
						} else {
							1
						};
						let said = text(0)
							.filter(|_| args.len() == expected)
							.ok_or("post needs text and the selected delivery fields")?;
						let previews = if previews && !(retained && matches!(args[1], Argument::Boolean(false))) {
							rooms_application::open_graph::Selection::decode(
								said,
								text(1).ok_or("post needs one preview selection")?,
							)
							.map_err(|e| e.to_string())?
						} else {
							Default::default()
						};
						let key = Rc::new(Cell::new(None));
						state.rooms.require_participant(&room, membership).map_err(refusal)?;
						state.admit_message(connection, said.len())?;
						let actor = session
							.spawn_owned(lines::line(shared.clone(), key.clone()))
							.map_err(|e| e.to_string())?;
						let line = history::mutate(state, |rooms| {
							let (line, mut mutation) = rooms.post_delivered(
								&room,
								membership,
								said,
								previews,
								State::wall_clock(),
								delivery,
							)?;
							if let Some((caller, operation)) = correlation {
								rooms.correlate(&room, membership, caller, operation, &mut mutation);
							}
							Ok((line, mutation))
						})?;
						key.set(Some(line));
						lines::posted_reply(state, line, actor)
					},
				)
			}
			TYPING => {
				let (Some(on), 1) = (args.first().and_then(Argument::as_bool), args.len()) else {
					return Err("typing needs one boolean".into());
				};
				let now = state.now();
				if !state.rooms.typing_needed(&room, membership, on, now).map_err(refusal)? {
					state
						.admission
						.coalesced(rooms_application::admission::Class::RoomTransient);
					return Ok(Argument::Void);
				}
				state.admit_transient(connection, &room)?;
				let effects = state.rooms.typing_at(&room, membership, on, now).map_err(refusal)?;
				state.apply_rooms(effects);
				Ok(Argument::Void)
			}
			HISTORY => {
				if !args.is_empty() {
					return Err("history takes no arguments".into());
				}
				state.admit_work(connection, rooms_application::admission::Class::Read, 1)?;
				let lines = state.rooms.history(&room, membership).map_err(refusal)?;
				Ok(Argument::List(
					lines
						.into_iter()
						.map(|line| {
							Argument::List(vec![
								line.from.clone().into(),
								line.text.clone().into(),
								Argument::Integer(line.at as i64),
								line.previews.encode().into(),
							])
						})
						.collect(),
				))
			}
			AWAY => {
				let (Some(why), 1) = (text(0), args.len()) else {
					return Err("away needs one reason".into());
				};
				if !state.rooms.away_needed(&room, membership, why).map_err(refusal)? {
					state
						.admission
						.coalesced(rooms_application::admission::Class::RoomTransient);
					return Ok(Argument::Void);
				}
				state.admit_transient(connection, &room)?;
				let effects = state.rooms.away(&room, membership, why).map_err(refusal)?;
				state.apply_rooms(effects);
				Ok(Argument::Void)
			}
			LEAVE => {
				if !args.is_empty() {
					return Err("leave takes no arguments".into());
				}
				let effects = state.rooms.retire_membership(&room, membership);
				state.apply_rooms(effects);
				Ok(Argument::Void)
			}
			_ => Err(format!("room membership has no method {verb}")),
		}
	}
}
