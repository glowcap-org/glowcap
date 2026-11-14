//! Durable room authority: the names this server made durable, the swiss
//! each answers to, and the changes to that authority. A change is a job the
//! loop's authority task runs one at a time: it prepares the successor in a
//! turn's terms, persists its document, installs it, and only then publishes
//! or takes down durable names and answers the caller. A name recorded but
//! not published is answered by the next restart. A name published but not
//! recorded is gone with the process. Only one of those heals itself.
pub(super) mod link_ask;
pub(super) mod links;
pub(super) mod queue;
use super::{
	notice::Notice,
	rooms,
	state::{Shared, State},
};
use glowcap::Argument;
pub(super) use link_ask::{Asker, link, listed_link_name, no_link};
pub(crate) use links::{AuthorityRefusal, Links, Swiss};
use queue::{Commit, Prepare};
pub(super) use queue::{Seat, request, submit};
use rooms_application::{
	failure::FailureCode,
	protocol_data,
	room::{
		ArgumentView,
		authority::{self as verbs, room_identity},
		policy::{MembershipKind, RoomPolicy},
		stewardship::Kind,
	},
	server::{links::Registration, rooms::room_name_refusal},
};
use rooms_glowcap::Value;

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
		self.links.set(Kind::Room, name, Swiss::from(swiss.clone()));
		Ok(swiss)
	}
	/// The digest a steward governs, derived from the room link's token. A
	/// room with no link answers none until a manager creates one.
	pub(super) fn published_room_identity(&self, name: &str) -> Result<Option<String>, String> {
		self.links
			.swiss(Kind::Room, name)
			.map(|swiss| room_identity(swiss).map_err(|e| e.to_string()))
			.transpose()
	}
	/// The name whose manager identity is `identity`. The identity derives
	/// from the name, so this walks the names the server owns and the rooms
	/// that are live, one derivation each, on an operator's rare ask.
	pub(super) fn manager_name(&self, identity: &str) -> Result<String, String> {
		self.rooms
			.live()
			.map(|room| room.durable_name)
			.chain(self.authority.owned_names())
			.find(|name| self.authority.manager_identity(name) == identity)
			.map(String::from)
			.ok_or_else(|| AuthorityRefusal::UnknownManager.to_string())
	}
	pub fn publish_steward(&mut self, name: &str) -> Result<(String, String), String> {
		let identity = room_identity(&self.publish_room(name)?).map_err(|e| e.to_string())?;
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
		self.links.set(Kind::Steward, name, Swiss::from(swiss.clone()));
		Ok((identity, swiss))
	}
	pub fn publish_manager(&mut self, name: &str) -> Result<String, String> {
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
		self.links.set(Kind::Manager, name, Swiss::from(swiss.clone()));
		Ok(swiss)
	}
	pub(super) fn unpublish(&mut self, kind: Kind, name: &str) -> Option<String> {
		let swiss = String::from(self.links.drop(kind, name)?);
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

/// `roomAuthorities` on a manager bootstrap: the room link and the manager,
/// issued once and answered again on every ask.
pub(super) fn bootstrap(
	shared: Shared,
	name: String,
	managed: Option<(String, RoomPolicy)>,
) -> impl FnMut(Option<&str>, &[Argument]) -> Result<Argument, String> {
	move |verb, args| {
		let verb = verb.ok_or("direct invocation is not supported")?;
		if args.iter().any(|arg| Value(arg).contains_capability()) {
			return Err("room manager bootstrap accepts no capability arguments".into());
		}
		if verb != rooms_application::directory::creation::AUTHORITIES || !args.is_empty() {
			return Err(format!("a room manager bootstrap has no method {verb}"));
		}
		let seat = {
			let mut state = shared.borrow_mut();
			let (caller, _) = rooms::caller(&mut state)?;
			state.ingress(caller)?;
			let seat = state.authority_writer.reserve()?;
			state.admit_work(caller, rooms_application::admission::Class::Read, 1)?;
			seat
		};
		let (name, managed) = (name.clone(), managed.clone());
		let (held, registration) = (name.clone(), managed.clone());
		submit(
			seat,
			rooms_application::protocol_data::ROOM_AUTHORITIES,
			move |state| {
				let registration = registration
					.as_ref()
					.map(|(name, policy)| Registration { name, policy: *policy });
				Ok(state.authority.remembered(&held, false, true, registration)?)
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
) -> impl FnMut(Option<&str>, &[Argument]) -> Result<Argument, String> {
	move |verb, args| {
		let verb = verb.ok_or("direct invocation is not supported")?;
		if args.iter().any(|arg| Value(arg).contains_capability()) {
			return Err("a durable steward does not take capability arguments".into());
		}
		let mut state = shared.borrow_mut();
		if !state.authority.room_link_generation_is_current(&name, room_generation)
			|| !state.authority.steward_generation_is_current(&name, generation)
		{
			return Err(FailureCode::NotSteward.line("this steward capability was revoked"));
		}
		let (caller, _) = rooms::caller(&mut state)?;
		if verb == verbs::KICK {
			state.admit_work(caller, rooms_application::admission::Class::Cleanup, 1)?;
		} else {
			state.ingress(caller)?;
			state.admit_work(caller, rooms_application::admission::Class::Read, 1)?;
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
fn manager(
	shared: Shared,
	name: String,
	generation: u64,
) -> impl FnMut(Option<&str>, &[Argument]) -> Result<Argument, String> {
	move |verb, args| {
		let verb = verb.ok_or("direct invocation is not supported")?;
		if args.iter().any(|arg| Value(arg).contains_capability()) {
			return Err("a room manager accepts no capability arguments".into());
		}
		let mut state = shared.borrow_mut();
		require_manager(&state, &name, generation)?;
		let (caller, _) = rooms::caller(&mut state)?;
		// The identity is answered from memory, within this turn.
		if matches!(verb, verbs::MANAGED_IDENTITY | verbs::GOVERNS) {
			state.ingress(caller)?;
			state.admit_work(caller, rooms_application::admission::Class::Read, 1)?;
			if !args.is_empty() {
				return Err(format!("{verb} takes no arguments"));
			}
			return Ok(state.authority.manager_identity(&name).into());
		}
		let class = match verb {
			verbs::LINK => rooms_application::admission::Class::Read,
			verbs::REVOKE_STEWARD | verbs::REVOKE_ROOM_LINK => rooms_application::admission::Class::Cleanup,
			_ => rooms_application::admission::Class::Create,
		};
		if class != rooms_application::admission::Class::Cleanup {
			state.ingress(caller)?;
		}
		// Every other verb changes the authority through its writer.
		let seat = state.authority_writer.reserve()?;
		state.admit_work(caller, class, 1)?;
		let text = |at: usize| args.get(at).and_then(Argument::as_str);
		match verb {
			verbs::LINK => {
				if !args.is_empty() {
					return Err("link takes no arguments".into());
				}
				link(
					seat,
					Asker::Manager {
						name: name.clone(),
						generation,
					},
				)
			}
			verbs::GIVE_STEWARD => {
				if !args.is_empty() {
					return Err("giveSteward takes no arguments".into());
				}
				let (held, published) = (name.clone(), name.clone());
				submit(
					seat,
					verbs::GIVE_STEWARD,
					move |state| {
						require_manager(state, &held, generation)?;
						Ok(state.authority.remembered(&held, true, false, None)?)
					},
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
				state.links.resolve_for(kind, token, &name)?;
				let (prepare, commit) = revocation(kind, token.into(), Some((name.clone(), generation)));
				submit(seat, protocol_data::REVOKE, prepare, move |state, _| commit(state))
			}
			verbs::UNREGISTER_ROOM => {
				if !args.is_empty() {
					return Err("unregisterRoom takes no arguments".into());
				}
				let managed = state
					.authority
					.managed_room(&name)
					.ok_or("this manager has no room access policy")?;
				let public = managed.name.clone();
				set_policy(seat, name.clone(), public, RoomPolicy::Private, generation)
			}
			verbs::SET_POLICY => {
				let modes = [text(0), text(1), text(2)];
				let ([Some(visibility), Some(entry), Some(speaking)], Some(public), 4) = (modes, text(3), args.len())
				else {
					return Err("setRoomPolicy takes three policy modes and a room name".into());
				};
				let policy = RoomPolicy::parse(&[visibility, entry, speaking])
					.ok_or("setRoomPolicy names no supported room access state")?;
				if let Some(refusal) = room_name_refusal(public) {
					return Err(refusal.reason());
				}
				set_policy(seat, name.clone(), public.into(), policy, generation)
			}
			_ => Err(format!("a room manager has no method {verb}")),
		}
	}
}

fn require_manager(state: &State, room: &str, generation: u64) -> Result<(), AuthorityRefusal> {
	if !state.authority.manager_generation_is_current(room, generation) {
		return Err(AuthorityRefusal::ManagerRevoked);
	}
	Ok(())
}

/// Revoke only the generation `token` names, inside the serialized change,
/// so a delayed request for an old token cannot retire its replacement.
pub(super) fn revoke(state: &State, kind: Kind, token: String) -> Result<Argument, String> {
	let (prepare, commit) = revocation(kind, token, None);
	submit(
		state.authority_writer.reserve()?,
		protocol_data::REVOKE,
		prepare,
		move |state, _| commit(state),
	)
}

/// The same revocation, observed by an operator batch.
pub(super) fn request_revoke(
	state: &State,
	kind: Kind,
	token: String,
) -> impl std::future::Future<Output = Result<Argument, String>> + 'static {
	let (prepare, commit) = revocation(kind, token, None);
	request(state, protocol_data::REVOKE, prepare, commit)
}

/// The two halves of revoking one generation: the successor without it, and
/// taking its name down once that stands.
pub(super) fn revocation(kind: Kind, token: String, manager: Option<(String, u64)>) -> (Prepare, Commit) {
	let held = token.clone();
	(
		Box::new(move |state: &State| {
			let name = if let Some((source, generation)) = &manager {
				require_manager(state, source, *generation)?;
				state.links.resolve_for(kind, &held, source)?
			} else {
				state.links.resolve(kind, &held)?
			};
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
fn set_policy(seat: Seat, id: String, name: String, policy: RoomPolicy, generation: u64) -> Result<Argument, String> {
	let (held_id, held_name) = (id.clone(), name.clone());
	submit(
		seat,
		verbs::SET_POLICY,
		move |state| {
			require_manager(state, &held_id, generation)?;
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
				return Err(FailureCode::RoomExists.line(format_args!("room \"{held_name}\" already exists")));
			}
			Ok(state.authority.with_managed_room_policy(&held_id, &held_name, policy)?)
		},
		move |state, _| {
			let effects = state
				.rooms
				.policy_changed(&id, &state.authority)
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
