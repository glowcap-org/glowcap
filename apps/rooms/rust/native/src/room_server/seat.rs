//! Operations on one live room seat. The capability identifies the
//! membership; no nickname, account, or calling-session lookup authorizes an
//! act. The seat is minted before its membership is filed, so it answers
//! nothing until the policy has named it.
use super::{
	files, history, invitations, lines,
	state::{Shared, State},
};
use glowcap::{current_session, Argument};
use rooms_application::{
	bridge,
	failure::FailureCode,
	room::{
		history::VERB as HISTORY,
		invitation::MINT,
		membership::{AWAY, LEAVE, TYPING},
		policy::MembershipKind,
		ArgumentView,
	},
	server::rooms::{MembershipKey, RoomKey},
};
use rooms_glowcap::Value;
use std::{cell::Cell, rc::Rc};

const KIND: &str = "membershipKind";
const POST: &str = "post";
const POST_FILES: &str = "postFiles";
const ATTACH: &str = "attach";

fn refusal(refusal: rooms_application::server::rooms::Refusal) -> String {
	refusal.reason()
}

/// One observer or participant facet for one exact membership.
pub(super) fn seat(
	shared: Shared,
	room: RoomKey,
	membership: Rc<Cell<Option<MembershipKey>>>,
) -> impl FnMut(&str, &[Argument]) -> Result<Argument, String> {
	move |verb, args| {
		if args.iter().any(|arg| Value(arg).contains_capability()) {
			return Err(format!("room membership {verb} does not take capability arguments"));
		}
		let Some(membership) = membership.get() else {
			return Err(format!(
				"{}: this room membership has ended",
				FailureCode::NotRoomMember.wire()
			));
		};
		let session = current_session()
			.map_err(|e| e.to_string())?
			.ok_or("a room membership is reachable only over a session")?;
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
			POST_FILES => {
				let (Some(caption), 1) = (text(0), args.len()) else {
					return Err(format!(
						"{}: postFiles needs one caption",
						FailureCode::BadAttachment.wire()
					));
				};
				let key = Rc::new(Cell::new(None));
				let actor = session
					.spawn_owned(lines::line(shared.clone(), key.clone()))
					.map_err(|e| e.to_string())?;
				let now = state.now();
				let line = history::mutate(&mut state, |rooms| {
					rooms.post_files(&room, membership, caption, State::wall_clock(), now)
				})?;
				key.set(Some(line));
				Ok(Argument::Reference(actor))
			}
			ATTACH => {
				let description =
					rooms_application::server::rooms::wire::attachment(args.len(), |at| args.get(at).map(Value))
						.map_err(refusal)?;
				let now = state.now();
				let key = state
					.rooms
					.attach(&room, membership, description, now)
					.map_err(refusal)?;
				state.upload_admitted.notify_one();
				let upload = session
					.spawn_owned(files::upload(shared.clone(), key))
					.map_err(|e| e.to_string())?;
				Ok(Argument::Reference(upload))
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
								line.from.into(),
								line.text.into(),
								Argument::Integer(line.at as i64),
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
