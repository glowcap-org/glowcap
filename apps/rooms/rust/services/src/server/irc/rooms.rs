//! A bridged channel's durable entrance and exact membership capabilities.
use super::*;
use glowcap::Argument;
use rooms_application::room::{
	authority::LINK,
	membership::SUBSCRIBE,
	policy::MembershipKind,
	queries::{CALLED, POLICY, PRIVATE},
};

pub(super) fn publish(shared: &Shared, publication: &Rc<Publication>) -> Result<(), String> {
	let entropy = rooms_application::server::irc::model::entropy_bytes(&publication.authority.borrow().room_entropy)
		.ok_or("invalid IRC room entropy")?;
	let held = publication.clone();
	let state = shared.borrow();
	let shared = shared.clone();
	let swiss = state
		.host
		.publish_durable_with_entropy(entropy, move || {
			Box::new(entrance(shared, held, MembershipKind::Participant))
		})
		.map_err(|e| format!("IRC channel is saved; publishing its entrance failed: {e}"))?;
	*publication.swiss.borrow_mut() = Some(swiss);
	Ok(())
}
pub(in crate::server) fn entrance(
	shared: Shared,
	publication: Rc<Publication>,
	kind: MembershipKind,
) -> impl FnMut(&str, &[Argument]) -> Result<Argument, String> {
	gated_entrance(shared, publication, kind, None)
}
pub(super) fn gated_entrance(
	shared: Shared,
	publication: Rc<Publication>,
	kind: MembershipKind,
	admission: Option<Rc<RefCell<rooms_application::server::invitation::Admission>>>,
) -> impl FnMut(&str, &[Argument]) -> Result<Argument, String> {
	move |verb, args| {
		if !publication.active.get() || shared.borrow().irc.stopping {
			return Err(retired());
		}
		if admission
			.as_ref()
			.is_some_and(|admission| !admission.borrow().is_open())
		{
			return Err("this room invitation entrance has ended".into());
		}
		if verb != SUBSCRIBE && super::super::operations::carries_capability(args) {
			return Err(format!("IRC room {verb} does not take capabilities"));
		}
		if verb == SUBSCRIBE {
			let result = subscribe(&shared, &publication, kind, args)?;
			if let Some(admission) = &admission {
				admission.borrow_mut().admit()?;
			}
			return Ok(result);
		}
		if !args.is_empty() {
			return Err(format!("{verb} takes no arguments"));
		}
		let mut state = shared.borrow_mut();
		let (caller, _) = super::super::rooms::caller(&mut state)?;
		state.ingress(caller)?;
		state.admit_work(caller, rooms_application::admission::Class::Read, 1)?;
		let core = state.irc.core.borrow();
		let bridge = core.bridge(&publication.key).ok_or_else(retired)?;
		match verb {
			CALLED => Ok(bridge.room.name().into()),
			PRIVATE => Ok("listed".into()),
			POLICY => Ok(Argument::List(vec!["listed".into(), "open".into(), "open".into()])),
			LINK => state
				.link(publication.swiss.borrow().as_deref().ok_or_else(retired)?)
				.map(Argument::from),
			_ => Err(format!("IRC room has no method {verb}")),
		}
	}
}
fn subscribe(
	shared: &Shared,
	publication: &Rc<Publication>,
	kind: MembershipKind,
	args: &[Argument],
) -> Result<Argument, String> {
	let [Argument::String(nick), Argument::Reference(inbox)] = args else {
		return Err("subscribe needs one name and inbox capability".into());
	};
	let mut state = shared.borrow_mut();
	let (connection, session) = super::super::rooms::caller(&mut state)?;
	state
		.irc
		.core
		.borrow()
		.bridge(&publication.key)
		.ok_or_else(retired)?
		.room
		.admit_reader(connection, nick)
		.map_err(|e| e.reason())?;
	state.ingress(connection)?;
	state.admit_join(connection, &publication.id)?;
	state.irc.next_member = state
		.irc
		.next_member
		.checked_add(1)
		.ok_or("IRC membership identities exhausted")?;
	let seat = Rc::new(members::Seat::new(state.irc.next_member, connection, kind));
	let capability = session
		.spawn_owned(members::behavior(shared.clone(), publication.clone(), seat.clone()))
		.map_err(|e| e.to_string())?;
	let core = state.irc.core.clone();
	let effects = core
		.borrow_mut()
		.subscribe_reader(&publication.key, connection, nick, inbox.clone(), kind)?;
	members::replace(&mut state, publication, &seat);
	let enabled = {
		let mut core = core.borrow_mut();
		core.seat_reader(&publication.key, connection, nick, seat.id);
		kind == MembershipKind::Participant
			&& core
				.bridge(&publication.key)
				.and_then(|bridge| core.identity(connection, &bridge.network))
				.is_some_and(|identity| identity.enabled)
	};
	if let Err(reason) = apply(&state, &publication.key, effects) {
		trouble(&state, "starting an IRC room subscription", reason);
	}
	members::show(&state, publication, connection);
	if enabled {
		members::start(&mut state, publication.clone(), seat);
	}
	// No topic authority and no files facet: IRC has no way to carry a file,
	// and a client that holds nothing there draws no attach control.
	Ok(Argument::List(vec![
		Argument::Reference(capability),
		kind.as_str().into(),
		Argument::Void,
		Argument::Void,
	]))
}
