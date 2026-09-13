//! Operations on one live room seat. The capability identifies the
//! membership; no nickname, account, or calling-session lookup authorizes an
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
		return Err(format!(
			"{}: this room membership has ended",
			FailureCode::NotRoomMember.wire()
		));
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
				let key = state.rooms.mint_invitation(&room, membership, kind).map_err(refusal)?;
				let invitation = session
					.spawn_owned(invitations::invitation(shared.clone(), key))
					.map_err(|e| e.to_string())?;
				Ok(Argument::Reference(invitation))
			}
			POST => {
				if args.len() > 1 {
					return Err(format!(
						"{}: post carries trailing args; attach a file with attach()",
						FailureCode::BadAttachment.wire()
					));
				}
				let (Some(said), 1) = (text(0), args.len()) else {
					return Err("post needs exactly one text line".into());
				};
				let key = Rc::new(Cell::new(None));
				let actor = session
					.spawn_owned(lines::line(shared.clone(), key.clone()))
					.map_err(|e| e.to_string())?;
				let line = history::mutate(&mut state, |rooms| {
					rooms.post(&room, membership, said, State::wall_clock())
				})?;
				key.set(Some(line));
				Ok(Argument::Reference(actor))
			}
			rooms_application::open_graph::ROOM_POST_VERB => {
				let (Some(said), Some(encoded), 2) = (text(0), text(1), args.len()) else {
					return Err("postWithPreviews needs text and one preview selection".into());
				};
				let previews = rooms_application::open_graph::Selection::decode(said, encoded)
					.map_err(|error| error.to_string())?;
				let key = Rc::new(Cell::new(None));
				let actor = session
					.spawn_owned(lines::line(shared.clone(), key.clone()))
					.map_err(|e| e.to_string())?;
				let line = history::mutate(&mut state, |rooms| {
					rooms.post_with_previews(&room, membership, said, previews, State::wall_clock())
				})?;
				key.set(Some(line));
				Ok(Argument::Reference(actor))
			}
			TYPING => {
				let (Some(on), 1) = (args.first().and_then(Argument::as_bool), args.len()) else {
					return Err("typing needs one boolean".into());
				};
				let effects = state.rooms.typing(&room, membership, on).map_err(refusal)?;
				state.apply_rooms(effects);
				Ok(Argument::Void)
			}
			HISTORY => {
				if !args.is_empty() {
					return Err("history takes no arguments".into());
				}
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
				let effects = state.rooms.away(&room, membership, why).map_err(refusal)?;
				state.apply_rooms(effects);
				Ok(Argument::Void)
			}
			LEAVE => {
				if !args.is_empty() {
					return Err("leave takes no arguments".into());
				}
				let effects = state.rooms.leave(&room, membership).map_err(refusal)?;
				state.apply_rooms(effects);
				Ok(Argument::Void)
			}
			_ => Err(format!("room membership has no method {verb}")),
		}
	}
}
