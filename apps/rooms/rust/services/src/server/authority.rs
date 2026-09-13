//! Durable room authority: the names this server made durable, the swiss
//! each answers to, and the changes to that authority. A change is a job the
//! loop's authority task runs one at a time: it prepares the successor in a
//! turn's terms, persists its document, installs it, and only then publishes
//! or takes down durable names and answers the caller. A name recorded but
//! not published is answered by the next restart; a name published but not
//! recorded is gone with the process. Only one of those heals itself.
pub(super) mod queue;
use super::{
	notice::Notice,
	rooms,
	state::{Shared, State},
};
use glowcap::Argument;
use queue::{Commit, Prepare};
pub(super) use queue::{request, submit};
use rooms_application::{
	failure::FailureCode,
	protocol_data,
	room::{
		ArgumentView,
		authority::{self as verbs, room_identity},
		policy::{MembershipKind, RoomPolicy},
		stewardship::Kind,
	},
	server::{links::Registration, rooms::MAX_ROOM},
};
use rooms_glowcap::Value;
use std::collections::BTreeMap;

/// The durable names this server has published, by kind and folded name.
#[derive(Default)]
pub(super) struct Links {
	room: BTreeMap<String, String>,
	steward: BTreeMap<String, String>,
	manager: BTreeMap<String, String>,
	by_swiss: BTreeMap<String, (Kind, String)>,
	identity_by_name: BTreeMap<String, String>,
	name_by_identity: BTreeMap<String, String>,
}

fn fold(name: &str) -> String {
	name.to_lowercase()
}

impl Links {
	fn table(&mut self, kind: Kind) -> &mut BTreeMap<String, String> {
		match kind {
			Kind::Room => &mut self.room,
			Kind::Steward => &mut self.steward,
			Kind::Manager => &mut self.manager,
		}
	}
	pub fn swiss(&self, kind: Kind, name: &str) -> Option<&str> {
		let table = match kind {
			Kind::Room => &self.room,
			Kind::Steward => &self.steward,
			Kind::Manager => &self.manager,
		};
		table.get(&fold(name)).map(String::as_str)
	}
	/// Every published name of `kind` with its current swiss.
	pub fn published(&self, kind: Kind) -> impl Iterator<Item = (String, String)> + '_ {
		self.by_swiss
			.iter()
			.filter(move |(_, (held, _))| *held == kind)
			.map(|(swiss, (_, name))| (name.clone(), swiss.clone()))
	}
	fn set(&mut self, kind: Kind, name: &str, swiss: String) {
		let key = fold(name);
		if let Some(previous) = self.table(kind).insert(key, swiss.clone()) {
			self.by_swiss.remove(&previous);
		}
		self.by_swiss.insert(swiss, (kind, name.into()));
	}
	fn drop(&mut self, kind: Kind, name: &str) -> Option<String> {
		let swiss = self.table(kind).remove(&fold(name))?;
		self.by_swiss.remove(&swiss);
		Some(swiss)
	}
	/// The name a current token stands for, when it is the current
	/// generation of that kind.
	pub fn resolve(&self, kind: Kind, token: &str) -> Result<String, String> {
		let held = self.by_swiss.get(token).filter(|(held, _)| *held == kind);
		match held {
			Some((_, name)) => Ok(name.clone()),
			None => Err(format!(
				"that {} capability generation is no longer current",
				match kind {
					Kind::Room => "room link",
					Kind::Steward => "moderator",
					Kind::Manager => "manager",
				}
			)),
		}
	}
	pub(super) fn manager_name(&self, identity: &str) -> Result<&str, String> {
		self.name_by_identity
			.get(identity)
			.map(String::as_str)
			.ok_or_else(|| "that room management identity is not known to this directory".into())
	}

	/// A live baseline room can name its management identity before it becomes
	/// durable. Bound these optional lookups without refusing restoration or
	/// publication of the separately bounded durable manager registry.
	pub(super) fn cache_identity(&mut self, name: &str, identity: String) -> Result<(), String> {
		if self.identity_by_name.len() >= rooms_application::server::document::MAX_ROOM_LINKS
			&& !self.identity_by_name.contains_key(&fold(name))
		{
			return Err("room management identity capacity reached".into());
		}
		self.set_identity(name, identity)
	}

	fn set_identity(&mut self, name: &str, identity: String) -> Result<(), String> {
		let key = fold(name);
		if self.identity_by_name.get(&key).is_some_and(|held| *held != identity) {
			return Err("a room changed its stable management identity".into());
		}
		if self
			.name_by_identity
			.get(&identity)
			.is_some_and(|held| fold(held) != key)
		{
			return Err("two rooms derived the same management identity".into());
		}
		self.identity_by_name.insert(key, identity.clone());
		self.name_by_identity.insert(identity, name.into());
		Ok(())
	}
}

impl State {
	/// Publish the room link for `name` under its current generation, or
	/// answer the one already published.
	pub fn publish_room(&mut self, name: &str) -> Result<String, String> {
		if let Some(swiss) = self.links.swiss(Kind::Room, name) {
			return Ok(swiss.into());
		}
		let generation = self.authority.room_link_generation(name);
		let entropy = self.authority.room_entropy(name, generation);
		let shared = self.shared();
		let entrance = self
			.rooms
			.durable_entrance(name, MembershipKind::Participant, &self.authority);
		let swiss = self
			.host
			.publish_durable_with_entropy(entropy, move || Box::new(rooms::entrance(shared, entrance)))
			.map_err(|e| format!("room link state is committed; publication failed: {e}"))?;
		self.links.set(Kind::Room, name, swiss.clone());
		Ok(swiss)
	}
	pub fn publish_steward(&mut self, name: &str) -> Result<(String, String), String> {
		let room_swiss = self.publish_room(name)?;
		let identity = room_identity(&room_swiss).map_err(|e| e.to_string())?;
		if let Some(swiss) = self.links.swiss(Kind::Steward, name) {
			return Ok((identity, swiss.into()));
		}
		let generation = self.authority.steward_generation(name);
		let room_generation = self.authority.room_link_generation(name);
		let entropy = self.authority.steward_entropy(name, generation);
		let shared = self.shared();
		let (held_name, held_identity) = (name.to_owned(), identity.clone());
		let swiss = self
			.host
			.publish_durable_with_entropy(entropy, move || {
				Box::new(steward(shared, held_name, held_identity, generation, room_generation))
			})
			.map_err(|e| format!("steward state is committed; publication failed: {e}"))?;
		self.links.set(Kind::Steward, name, swiss.clone());
		Ok((identity, swiss))
	}
	pub fn publish_manager(&mut self, name: &str) -> Result<String, String> {
		let identity = self.authority.manager_identity(name);
		self.links.set_identity(name, identity)?;
		if let Some(swiss) = self.links.swiss(Kind::Manager, name) {
			return Ok(swiss.into());
		}
		let generation = self.authority.manager_generation(name);
		let entropy = self.authority.manager_entropy(name, generation);
		let shared = self.shared();
		let held = name.to_owned();
		let swiss = self
			.host
			.publish_durable_with_entropy(entropy, move || Box::new(manager(shared, held, generation)))
			.map_err(|e| format!("manager state is committed; publication failed: {e}"))?;
		self.links.set(Kind::Manager, name, swiss.clone());
		Ok(swiss)
	}
	pub(super) fn unpublish(&mut self, kind: Kind, name: &str) -> Option<String> {
		let swiss = self.links.drop(kind, name)?;
		if let Err(cause) = self.host.remove_durable(&swiss) {
			self.report(Notice::UnpublishFailed {
				swiss: swiss.clone(),
				cause,
			});
		}
		Some(swiss)
	}
	/// Republish every durable name the document records, at startup.
	pub fn restore_links(&mut self) -> Result<(), String> {
		let linked: Vec<String> = self.authority.linked_rooms().map(String::from).collect();
		for name in &linked {
			self.publish_room(name)?;
		}
		let stewards: Vec<String> = self
			.authority
			.stewards()
			.filter(|row| row.issued)
			.map(|row| row.name.clone())
			.collect();
		for name in &stewards {
			self.publish_steward(name)?;
		}
		let managers: Vec<(String, bool)> = self
			.authority
			.managers()
			.map(|row| (row.name.clone(), row.issued))
			.collect();
		for (name, issued) in managers {
			let identity = self.authority.manager_identity(&name);
			self.links.set_identity(&name, identity)?;
			if issued {
				self.publish_manager(&name)?;
			}
		}
		Ok(())
	}
	/// A room's current link, when a room manager created one.
	pub fn current_room_link(&self, name: &str) -> Option<String> {
		self.links
			.swiss(Kind::Room, name)
			.and_then(|swiss| self.link(swiss).ok())
	}
	/// The room's own answer for a retired authority generation: members
	/// hear which token ended.
	pub(super) fn authority_ended(&mut self, name: &str, kind: Kind, token: &str) {
		let effects = self.rooms.authority_changed(name, kind, token);
		self.apply_rooms(effects);
	}
}

/// `link(name)` from the directory or a manager: persist, publish, answer.
pub(super) fn link(state: &State, name: String) -> Result<Argument, String> {
	let held = name.clone();
	submit(
		state,
		protocol_data::LINK,
		move |state| Ok(state.authority.remembered(&held, false, false, None, None)?),
		move |state, caller| {
			let swiss = state.publish_room(&name)?;
			Ok(state.link_for(&swiss, Some(caller)).map_err(|e| e.to_string())?.into())
		},
	)
}

/// `roomAuthorities` on a manager bootstrap: the room link and the manager,
/// issued once and answered again on every ask.
pub(super) fn bootstrap(
	shared: Shared,
	name: String,
	managed: Option<(String, RoomPolicy)>,
) -> impl FnMut(&str, &[Argument]) -> Result<Argument, String> {
	move |verb, args| {
		if args.iter().any(|arg| Value(arg).contains_capability()) {
			return Err("room manager bootstrap accepts no capability arguments".into());
		}
		if verb != rooms_application::directory::creation::AUTHORITIES || !args.is_empty() {
			return Err(format!("a room manager bootstrap has no method {verb}"));
		}
		let (name, managed) = (name.clone(), managed.clone());
		let (held, registration) = (name.clone(), managed.clone());
		submit(
			&shared.borrow(),
			rooms_application::protocol_data::ROOM_AUTHORITIES,
			move |state| {
				let registration = registration
					.as_ref()
					.map(|(name, policy)| Registration { name, policy: *policy });
				Ok(state.authority.remembered(&held, false, true, None, registration)?)
			},
			move |state, caller| {
				let room = state.publish_room(&name)?;
				let manager = state.publish_manager(&name)?;
				Ok(Argument::List(vec![
					state.link_for(&room, Some(caller)).map_err(|e| e.to_string())?.into(),
					state
						.link_for(&manager, Some(caller))
						.map_err(|e| e.to_string())?
						.into(),
				]))
			},
		)
	}
}

/// The durable steward publication for one room identity. It captures no
/// live room: `kick` resolves the current generation when it is used.
fn steward(
	shared: Shared,
	name: String,
	identity: String,
	generation: u64,
	room_generation: u64,
) -> impl FnMut(&str, &[Argument]) -> Result<Argument, String> {
	move |verb, args| {
		if args.iter().any(|arg| Value(arg).contains_capability()) {
			return Err("a durable steward does not take capability arguments".into());
		}
		let mut state = shared.borrow_mut();
		if !state.authority.room_link_generation_is_current(&name, room_generation)
			|| !state.authority.steward_generation_is_current(&name, generation)
		{
			return Err(format!(
				"{}: this steward capability was revoked",
				FailureCode::NotSteward.wire()
			));
		}
		match verb {
			verbs::GOVERNS => {
				if !args.is_empty() {
					return Err("governs takes no arguments".into());
				}
				Ok(identity.as_str().into())
			}
			verbs::KICK => {
				let [nick] = args else {
					return Err("kick needs one member name".into());
				};
				let nick = nick.as_str().ok_or("kick needs one member name")?;
				let key = rooms::durable_key(&name);
				let effects = state.rooms.kick(&key, nick).map_err(|refusal| refusal.reason())?;
				state.apply_rooms(effects);
				Ok(Argument::Void)
			}
			_ => Err(format!("a steward has no method {verb}")),
		}
	}
}

/// Passable authority over one room's durable link and moderator
/// generations. It retains only the durable name, never a live room.
fn manager(shared: Shared, name: String, generation: u64) -> impl FnMut(&str, &[Argument]) -> Result<Argument, String> {
	move |verb, args| {
		if args.iter().any(|arg| Value(arg).contains_capability()) {
			return Err("a room manager accepts no capability arguments".into());
		}
		let state = shared.borrow();
		if !state.authority.manager_generation_is_current(&name, generation) {
			return Err("this room manager capability was revoked".into());
		}
		let text = |at: usize| args.get(at).and_then(Argument::as_str);
		match verb {
			verbs::MANAGED_IDENTITY | verbs::GOVERNS => {
				if !args.is_empty() {
					return Err(format!("{verb} takes no arguments"));
				}
				Ok(state.authority.manager_identity(&name).into())
			}
			verbs::LINK => {
				if !args.is_empty() {
					return Err("link takes no arguments".into());
				}
				link(&state, name.clone())
			}
			verbs::GIVE_STEWARD => {
				if !args.is_empty() {
					return Err("giveSteward takes no arguments".into());
				}
				let (held, published) = (name.clone(), name.clone());
				submit(
					&state,
					"giveSteward",
					move |state| Ok(state.authority.remembered(&held, true, false, None, None)?),
					move |state, caller| {
						let room = state.publish_room(&published)?;
						let (identity, steward) = state.publish_steward(&published)?;
						Ok(Argument::List(vec![
							state.link_for(&room, Some(caller)).map_err(|e| e.to_string())?.into(),
							identity.into(),
							state
								.link_for(&steward, Some(caller))
								.map_err(|e| e.to_string())?
								.into(),
						]))
					},
				)
			}
			verbs::REVOKE_STEWARD | verbs::REVOKE_ROOM_LINK => {
				let (Some(token), 1) = (text(0), args.len()) else {
					return Err(format!("{verb} takes one exact authority token"));
				};
				if token.is_empty() {
					return Err(format!("{verb} takes one exact authority token"));
				}
				let kind = if verb == verbs::REVOKE_STEWARD {
					Kind::Steward
				} else {
					Kind::Room
				};
				revoke(&state, kind, token.into())
			}
			verbs::UNREGISTER_ROOM => {
				let (Some(token), 1) = (text(0), args.len()) else {
					return Err("unregisterRoom takes this manager's exact authority token".into());
				};
				if token.is_empty() {
					return Err("unregisterRoom takes this manager's exact authority token".into());
				}
				let id = state.links.resolve(Kind::Manager, token)?;
				let managed = state
					.authority
					.managed_room(&id)
					.ok_or("this manager has no room access policy")?;
				let public = managed.name.clone();
				set_policy(&state, id, public, RoomPolicy::Private)
			}
			verbs::SET_POLICY => {
				let modes = [text(1), text(2), text(3)];
				let (Some(token), [Some(visibility), Some(entry), Some(speaking)], Some(public), 5) =
					(text(0), modes, text(4), args.len())
				else {
					return Err("setRoomPolicy takes this manager's token, three policy modes, and a room name".into());
				};
				if token.is_empty() || public.is_empty() {
					return Err("setRoomPolicy takes this manager's token, three policy modes, and a room name".into());
				}
				let policy = RoomPolicy::parse(&[visibility, entry, speaking])
					.ok_or("setRoomPolicy names no supported room access state")?;
				if public.encode_utf16().count() > MAX_ROOM {
					return Err(format!("a room name must be between 1 and {MAX_ROOM} characters"));
				}
				let id = state.links.resolve(Kind::Manager, token)?;
				set_policy(&state, id, public.into(), policy)
			}
			_ => Err(format!("a room manager has no method {verb}")),
		}
	}
}

/// Revoke only the generation `token` names, inside the serialized change,
/// so a delayed request for an old token cannot retire its replacement.
pub(super) fn revoke(state: &State, kind: Kind, token: String) -> Result<Argument, String> {
	let (prepare, commit) = revocation(kind, token);
	submit(state, protocol_data::REVOKE, prepare, move |state, _| commit(state))
}

/// The same revocation, observed by an operator batch.
pub(super) fn request_revoke(
	state: &State,
	kind: Kind,
	token: String,
) -> impl std::future::Future<Output = Result<Argument, String>> + 'static {
	let (prepare, commit) = revocation(kind, token);
	request(state, protocol_data::REVOKE, prepare, commit)
}

/// The two halves of revoking one generation: the successor without it, and
/// taking its name down once that stands.
fn revocation(kind: Kind, token: String) -> (Prepare, Commit) {
	let held = token.clone();
	(
		Box::new(move |state: &State| {
			let name = state.links.resolve(kind, &held)?;
			Ok(Some(match kind {
				Kind::Steward => state.authority.with_steward_revoked(&name)?.0,
				Kind::Room => state.authority.with_room_link_revoked(&name)?,
				Kind::Manager => state.authority.with_manager_revoked(&name)?.0,
			}))
		}),
		Box::new(move |state: &mut State| {
			let name = state.links.resolve(kind, &token)?;
			state.unpublish(kind, &name);
			if kind == Kind::Room {
				state.unpublish(Kind::Steward, &name);
			}
			state.authority_ended(&name, kind, &token);
			Ok(Argument::Void)
		}),
	)
}

/// Change a managed room's public name and policy without replacing its
/// identity or any bearer generation.
fn set_policy(state: &State, id: String, name: String, policy: RoomPolicy) -> Result<Argument, String> {
	let (held_id, held_name) = (id.clone(), name.clone());
	submit(
		state,
		"setRoomPolicy",
		move |state| {
			if state.authority.managed_room(&held_id).is_none() {
				return Err("this manager has no room access policy".into());
			}
			let claimed = state.authority.managed_room_id_for_name(&held_name);
			let own_name = state
				.rooms
				.room_name(&rooms_application::server::rooms::RoomKey::managed(&held_id))
				.is_some_and(|current| current.to_lowercase() == held_name.to_lowercase());
			if policy.is_listed()
				&& (claimed.is_some_and(|claimed| claimed.to_lowercase() != held_id.to_lowercase())
					|| (state.authority.room_link_active(&held_name)
						&& state.authority.managed_room(&held_name).is_none())
					|| state.irc.holds_name(&held_name)
					|| state.foreign.holds_name(&held_name)
					|| (!own_name && state.rooms.public_name_taken(&held_name)))
			{
				return Err(format!(
					"{}: room \"{held_name}\" already exists",
					FailureCode::RoomExists.wire()
				));
			}
			Ok(state.authority.with_managed_room_policy(&held_id, &held_name, policy)?)
		},
		move |state, _| {
			let authority = state.authority.clone();
			let effects = state
				.rooms
				.policy_changed(&id, &authority)
				.map_err(|refusal| refusal.reason())?;
			state.apply_rooms(effects);
			let managed = state
				.authority
				.managed_room(&id)
				.ok_or("room policy change lost its managed room")?;
			let [visibility, entry, speaking] = managed.policy.modes();
			Ok(Argument::List(vec![
				managed.name.as_str().into(),
				visibility.into(),
				entry.into(),
				speaking.into(),
			]))
		},
	)
}
