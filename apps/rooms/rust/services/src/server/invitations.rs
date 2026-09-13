//! A one-claim entrance. Copies race on one stateful object; the winning
//! receipt may retry without creating a second claim after a lost answer.
use super::{rooms, state::Shared};
use glowcap::{Argument, current_session};
use rooms_application::{
	room::{ArgumentView, invitation::CLAIM},
	server::rooms::InvitationKey,
};
use rooms_glowcap::Value;

pub(super) fn invitation(
	shared: Shared,
	key: InvitationKey,
) -> impl FnMut(&str, &[Argument]) -> Result<Argument, String> {
	move |verb, args| {
		if args.iter().any(|arg| Value(arg).contains_capability()) {
			return Err("a room invitation does not take capability arguments".into());
		}
		if verb != CLAIM {
			return Err(format!("a room invitation has no method {verb}"));
		}
		let (Some(receipt), 1) = (args.first().and_then(Argument::as_str), args.len()) else {
			return Err("claimInvitation takes one 128-bit lowercase hexadecimal receipt".into());
		};
		let session = current_session()
			.map_err(|e| e.to_string())?
			.ok_or("a room invitation is reachable only during a session turn")?;
		let entrance = shared
			.borrow_mut()
			.rooms
			.claim_invitation(key, receipt)
			.map_err(|refusal| refusal.reason())?;
		Ok(Argument::Reference(rooms::invitation_entrance(
			&shared, &session, entrance,
		)?))
	}
}
