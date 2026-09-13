//! The operator's view and exact retirement acts for host IRC owners.
use super::super::operations::document::Store;
use super::*;
use rooms_application::server::operations::operator::inventory::irc::{Face, Member};

pub(in crate::server) fn faces(state: &State) -> Result<Vec<Face<u64>>, String> {
	let caller = glowcap::current_session().ok().flatten();
	let locator = state.advertised_locator(caller.as_ref());
	let core = state.irc.core.borrow();
	state
		.irc
		.publications
		.values()
		.filter(|publication| publication.active.get())
		.map(|publication| {
			let bridge = core.bridge(&publication.key).ok_or_else(retired)?;
			let stewardship = authority::row(state, publication, &locator)?;
			let seats = publication.seats.borrow();
			let members = bridge
				.room
				.members()
				.filter_map(|(connection, nick)| {
					let member = seats.get(&connection)?;
					Some(Member {
						id: member.id,
						connection,
						nick: nick.into(),
						state: core
							.view(&publication.key, connection)
							.map_or_else(|| "observer".into(), |view| view.phase.wire().into()),
					})
				})
				.collect();
			Ok(Face {
				stewardship,
				steward_token: authority::token(publication),
				origin: bridge.room.origin().into(),
				members,
			})
		})
		.collect()
}
fn publication(state: &State, id: &str) -> Result<Rc<Publication>, String> {
	state
		.irc
		.publications
		.values()
		.find(|publication| publication.id == id && publication.active.get())
		.cloned()
		.ok_or_else(retired)
}
pub(in crate::server) fn contains(state: &State, id: &str) -> bool {
	publication(state, id).is_ok()
}

pub(in crate::server) async fn remove(shared: &Shared, store: &Store, id: &str) -> Result<(), String> {
	let held = publication(&shared.borrow(), id)?;
	let (network, channel) = {
		let state = shared.borrow();
		let core = state.irc.core.borrow();
		let bridge = core.bridge(&held.key).ok_or_else(retired)?;
		(
			state.irc.networks.get(&bridge.network).cloned().ok_or_else(retired)?,
			bridge.room.channel().to_owned(),
		)
	};
	let gate = shared.borrow_mut().irc.gate(&network.key);
	let _held = gate.lock_owned().await;
	if !held.active.get() {
		return Err(retired());
	}
	current(&shared.borrow(), &network)?;
	commands::part(shared, store, &network, channel).await.map(|_| ())
}
pub(in crate::server) async fn revoke(shared: &Shared, store: &Store, id: &str, token: &str) -> Result<(), String> {
	let publication = publication(&shared.borrow(), id)?;
	authority::update(shared, store, &publication, Some(token)).await
}
pub(in crate::server) fn release(state: &mut State, id: &str, membership: u64) -> Result<(), String> {
	let publication = publication(state, id)?;
	let connection = publication
		.seats
		.borrow()
		.iter()
		.find(|(_, seat)| seat.id == membership)
		.map(|(connection, _)| *connection)
		.ok_or("that IRC membership has ended")?;
	members::retire(
		state,
		&publication,
		connection,
		Some("An operator ended this IRC membership."),
	);
	Ok(())
}
