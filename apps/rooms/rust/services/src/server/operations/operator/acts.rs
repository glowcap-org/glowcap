//! Performing what an operator row's act names: ending memberships and
//! registrations, letting go of held inboxes and exchanges, closing
//! sessions, removing rooms, and the resets that do those across a scope.
use super::super::super::{
	authority, irc,
	state::{Shared, State},
};
use super::super::document::Store;
use glowcap::PendingWork;
use std::{future::Future, pin::Pin};
pub(super) type Pending = Pin<Box<dyn Future<Output = Result<(), String>>>>;
use rooms_application::{room::stewardship::Kind, server::operations::operator::inventory::Act};

const MEMBERSHIP_ENDED: &str = "An operator ended this room membership.";
const ROOM_REMOVED: &str = "room-retired: An operator removed this room.";

/// Prepare the complete batch without yielding. Immediate acts run now;
/// durable acts capture the exact token and wait for writer capacity only
/// when polled. Session closes retain their exact session in the same way.
pub(super) fn prepare(shared: &Shared, store: &Store, connection: u64, act: Act) -> Pending {
	match act {
		Act::RevokeSteward(name) => revoke(&shared.borrow(), Kind::Steward, &name),
		Act::RevokeRoomLink(name) => revoke(&shared.borrow(), Kind::Room, &name),
		Act::Disconnect(id) => disconnect(shared, connection, &id),
		Act::RemoveIrc(id) => {
			let (shared, store) = (shared.clone(), store.clone());
			Box::pin(async move { irc::operator::remove(&shared, &store, &id).await })
		}
		Act::RevokeIrcSteward { publication, token } => {
			let (shared, store) = (shared.clone(), store.clone());
			Box::pin(async move { irc::operator::revoke(&shared, &store, &publication, &token).await })
		}
		act => {
			let outcome = immediate(&mut shared.borrow_mut(), act);
			Box::pin(std::future::ready(outcome))
		}
	}
}
fn revoke(state: &State, kind: Kind, name: &str) -> Pending {
	match state.links.swiss(kind, name) {
		Some(token) => observe(authority::request_revoke(state, kind, token.into())),
		None => Box::pin(std::future::ready(Err(
			"that durable authority is no longer present".into()
		))),
	}
}
fn observe(reply: impl Future<Output = Result<glowcap::Argument, String>> + 'static) -> Pending {
	Box::pin(async move { reply.await.map(|_| ()) })
}
fn immediate(state: &mut State, act: Act) -> Result<(), String> {
	match act {
		Act::RevokeSteward(_)
		| Act::RevokeRoomLink(_)
		| Act::RevokeIrcSteward { .. }
		| Act::RemoveIrc(_)
		| Act::Disconnect(_) => {
			unreachable!("asynchronous acts are prepared above")
		}
		Act::EndIrcMembership {
			publication,
			membership,
		} => irc::operator::release(state, &publication, membership),
		Act::RevokeRegistration(nick) => {
			let effects = state.policy.revoke_registration(&nick);
			state.apply(effects);
			Ok(())
		}
		Act::RemoveRoom(id) => {
			if remove_room(state, &id) {
				Ok(())
			} else {
				Err("that room generation is no longer present".into())
			}
		}
		Act::RemoveForeign(id) => {
			if state.foreign.by_id(&id).is_none() {
				return Err("that room generation is no longer present".into());
			}
			super::super::peering::forget(state, &id);
			state.changed();
			Ok(())
		}
		Act::EndMembership { room, membership } => {
			let effects = state.rooms.end_membership(&room, membership, MEMBERSHIP_ENDED);
			state.apply_rooms(effects);
			Ok(())
		}
		Act::ReleaseOffered { nick, peer } => {
			let release = state
				.policy
				.release_offered(&nick, &peer)
				.ok_or("that retained reference is no longer present")?;
			state.give_back(release.connection, release.capability);
			state.changed();
			Ok(())
		}
		Act::ReleaseSignaling(nick) => {
			let release = state
				.policy
				.release_signaling(&nick)
				.ok_or("that retained reference is no longer present")?;
			state.give_back(release.connection, release.capability);
			state.changed();
			Ok(())
		}
		Act::DropExchange(id) => {
			let dropped = state
				.policy
				.drop_exchange(&id)
				.ok_or("that retained reference is no longer present")?;
			state.reject(dropped);
			state.changed();
			Ok(())
		}
	}
}

/// Capture the selected session before the batch yields. The command owns
/// its close directly, without one additional work-queue job per connection.
fn disconnect(shared: &Shared, caller: u64, id: &str) -> Pending {
	let selected = {
		let state = shared.borrow();
		state
			.connection_by_operator_id(id)
			.filter(|id| *id != caller)
			.and_then(|id| state.session(id).map(|session| (id, session.borrowed())))
	};
	let shared = shared.clone();
	Box::pin(async move {
		let (connection, session) = selected.ok_or("that session is absent or is this operator")?;
		let outcome = session.close(PendingWork::Cancel).await;
		// Retirement has one idempotent owner, shared with the accept task.
		if !session.is_open() {
			shared.borrow_mut().closed(connection);
		}
		match outcome {
			Ok(()) => Ok(()),
			Err(error) if rooms_platform::serving::left(&error) => Ok(()),
			Err(error) => Err(error.to_string()),
		}
	})
}

/// Remove the exact room generation `id` names, this server's own or one
/// published here.
pub(super) fn remove_room(state: &mut State, id: &str) -> bool {
	if state.foreign.by_id(id).is_some() {
		super::super::peering::forget(state, id);
		state.changed();
		return true;
	}
	let Some(key) = state.rooms.room_by_entry(id).cloned() else {
		return false;
	};
	let effects = state.rooms.retire_room(&key, ROOM_REMOVED);
	state.apply_rooms(effects);
	true
}

/// Revoke the registration `nick` holds, when `id` still names the session
/// that holds it.
pub(super) fn revoke_nick(state: &mut State, nick: &str, id: &str) -> Result<(), String> {
	let held = state
		.policy
		.registrations()
		.find(|registration| registration.nick.eq_ignore_ascii_case(nick))
		.filter(|registration| state.connection_by_operator_id(id) == Some(registration.connection))
		.map(|registration| registration.nick)
		.ok_or("that nickname claim changed")?;
	let effects = state.policy.revoke_registration(&held);
	state.apply(effects);
	Ok(())
}

/// Rotate the room-link secret and retire every durable authority: old
/// links derive from the retired secret and can never collide with what is
/// minted after.
pub(super) fn factory_reset(state: &State) -> Pending {
	let mut secret = [0u8; rooms_application::server::document::KEY_BYTES];
	if let Err(error) = rooms_platform::entropy::fill(&mut secret) {
		return Box::pin(std::future::ready(Err(format!(
			"drawing a room-link secret failed: {error}"
		))));
	}
	observe(authority::request(
		state,
		"resetOperatorScope",
		move |state| Ok(Some(state.authority.factory_reset(secret))),
		move |state| {
			let retired: Vec<(Kind, String, String)> = [Kind::Room, Kind::Steward, Kind::Manager]
				.into_iter()
				.flat_map(|kind| {
					state
						.links
						.published(kind)
						.map(move |(name, swiss)| (kind, name, swiss))
				})
				.collect();
			for (kind, name, token) in retired {
				state.unpublish(kind, &name);
				state.authority_ended(&name, kind, &token);
			}
			state.links = Default::default();
			Ok(glowcap::Argument::Void)
		},
	))
}
