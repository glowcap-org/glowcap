//! IRC room invitations reuse the host room's portable claim/admission state.
use super::*;
use glowcap::{Argument, current_session};
use rooms_application::{
	failure::FailureCode,
	room::{invitation::CLAIM, policy::MembershipKind},
	server::{invitation::Admission, rooms::MAX_ROOM_INVITATIONS},
};

pub(super) fn mint(
	shared: &Shared,
	publication: &Rc<Publication>,
	minter: MembershipKind,
	args: &[Argument],
) -> Result<Argument, String> {
	if minter != MembershipKind::Participant {
		return Err(FailureCode::ReadOnlyMembership.line("an observer membership cannot invite"));
	}
	let kind = match args {
		[Argument::String(kind)] => MembershipKind::parse(kind),
		_ => None,
	}
	.ok_or("mintInvitation takes one observer or participant membership kind")?;
	if publication.invitations.borrow().len() >= MAX_ROOM_INVITATIONS {
		return Err(format!(
			"this IRC bridge already holds {MAX_ROOM_INVITATIONS} live invitations"
		));
	}
	let session = current_session()
		.map_err(|e| e.to_string())?
		.ok_or("an invitation needs a calling session")?;
	let admission = Rc::new(RefCell::new(Admission::default()));
	let (shared, held, claim) = (shared.clone(), publication.clone(), admission.clone());
	let capability = session
		.spawn_owned(move |verb, args| {
			if !held.active.get() || shared.borrow().irc.stopping {
				return Err(retired());
			}
			if verb != Some(CLAIM) {
				return Err(format!("a room invitation has no method {verb:?}"));
			}
			let [Argument::String(receipt)] = args else {
				return Err("claimInvitation takes one 128-bit lowercase hexadecimal receipt".into());
			};
			let session = current_session()
				.map_err(|e| e.to_string())?
				.ok_or("an invitation claim needs a calling session")?;
			{
				let mut state = shared.borrow_mut();
				let (caller, _) = super::super::rooms::caller(&mut state)?;
				state.ingress(caller)?;
				state.admit_work(caller, rooms_application::admission::Class::Read, 1)?;
			}
			claim.borrow_mut().claim(receipt)?;
			session
				.spawn_owned(rooms::gated_entrance(
					shared.clone(),
					held.clone(),
					kind,
					Some(claim.clone()),
				))
				.map(Argument::Reference)
				.map_err(|e| e.to_string())
		})
		.map_err(|e| e.to_string())?;
	publication.invitations.borrow_mut().push(admission);
	Ok(Argument::Reference(capability))
}
