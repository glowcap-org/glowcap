//! How a room is reached: opened by name, entered by name or publication,
//! reached through a durable link, or claimed through an invitation. An
//! entrance is what the adapter's room actor holds, and `seating` seats a
//! member through it.
use super::{
	InvitationKey, MAX_ROOM, MAX_ROOMS_PER_CREATOR, Refusal, RoomKey, Rooms,
	state::{Room, folded},
};
use crate::{
	directory::{creation::RecoveryKey, registration::Id},
	failure::FailureCode,
	room::{
		policy::{MembershipKind, RoomPolicy},
		subject::Subject,
	},
	server::links::Authority,
};
use alloc::{collections::BTreeSet, format, string::String, vec::Vec};

/// What keeps an entrance open. Checked on every verb, because a room
/// reference outlives the conditions it was minted under.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Gate {
	Always,
	/// The room is listed and its public name offers entry.
	Public,
	/// A managed room's public entrance, retired by a policy change.
	Managed {
		id: String,
		generation: u64,
	},
	/// A durable link, retired by its revocation.
	Link {
		name: String,
		generation: u64,
	},
	/// One claim through an invitation, spent by its first subscribe.
	Invitation(InvitationKey),
}

/// A room entrance reference's standing: which stable room it names, the
/// durable name needed to reconstitute the live room, the membership it offers,
/// and what keeps the entrance open.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entrance {
	pub room: RoomKey,
	/// The durable name a link entrance rebuilds the room from.
	pub durable: Option<String>,
	pub kind: MembershipKind,
	pub gate: Gate,
}

/// What `openManaged` answers beside the room: the bootstrap that mints the
/// room's authorities, once.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Bootstrap {
	pub name: String,
	pub managed: Option<(String, RoomPolicy)>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Opening {
	pub entrance: Entrance,
	pub bootstrap: Option<Bootstrap>,
}

/// What `open` and `openManaged` ask for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Open<'a> {
	pub name: &'a str,
	pub policy: RoomPolicy,
	/// A managed room's opaque id, or a private room's recovery key.
	pub recovery: Option<&'a str>,
	/// Whether the opener also wants the manager bootstrap.
	pub managed: bool,
}

/// Identities the adapter draws for a room that may be created.
pub struct Fresh {
	pub entry_id: Id,
	pub private_key: RecoveryKey,
}

pub(super) fn closed() -> Refusal {
	Refusal::coded(FailureCode::NoSuchRoom, "this room is no longer open")
}

impl<C: Copy + Ord, R: Clone> Rooms<C, R> {
	/// Whether `entrance` still admits, for `connection`. A member already in
	/// the room passes a closed gate: the room does not eject them for it.
	pub fn gate_open(&self, connection: C, entrance: &Entrance, authority: &Authority) -> bool {
		let room = self.rooms.get(&entrance.room);
		let seated = room.is_some_and(|room| room.member_of(connection).is_some());
		let open = match &entrance.gate {
			Gate::Always => true,
			Gate::Public => {
				room.is_some_and(|room| room.policy.is_listed() && room.policy.public_membership().is_some())
			}
			Gate::Managed { id, generation } => authority.managed_room_generation_is_current(id, *generation),
			Gate::Link { name, generation } => authority.room_link_generation_is_current(name, *generation),
			Gate::Invitation(key) => self
				.invitations
				.get(key)
				.is_some_and(|invitation| invitation.admission.is_open()),
		};
		open || (seated && !matches!(entrance.gate, Gate::Invitation(_)))
	}

	pub(super) fn register_room(&mut self, room: Room<C, R>) -> Result<(), Refusal> {
		let held = self.per_owner.get(&room.lifetime_owner).copied().unwrap_or(0);
		if held >= MAX_ROOMS_PER_CREATOR {
			return Err(Refusal::coded(
				FailureCode::TooManyRooms,
				format!("this connection already has {MAX_ROOMS_PER_CREATOR} rooms open"),
			));
		}
		let listed = room.policy.is_listed();
		let public = folded(&room.name);
		if listed && self.public_name_taken(&room.name) {
			return Err(Refusal::coded(
				FailureCode::RoomExists,
				format!("room \"{}\" already exists", room.name),
			));
		}
		if listed {
			self.public.insert(public, room.key.clone());
			self.by_entry.insert(room.entry_id.as_str().into(), room.key.clone());
		}
		self.per_owner.insert(room.lifetime_owner, held + 1);
		self.rooms.insert(room.key.clone(), room);
		Ok(())
	}

	pub(super) fn make_room(
		&mut self,
		name: &str,
		key: RoomKey,
		policy: RoomPolicy,
		owner: C,
		entry_id: Id,
		subject: Subject,
	) -> Result<Room<C, R>, Refusal> {
		let files = self.files.room().map_err(Refusal::plain)?;
		Ok(Room {
			entry_id,
			name: name.into(),
			key,
			policy,
			members: Vec::new(),
			offline: Default::default(),
			invitations: BTreeSet::new(),
			lines: BTreeSet::new(),
			lifetime_owner: owner,
			next_line: 1,
			subject,
			files,
		})
	}

	/// `open` and `openManaged`: a new room, or the same managed room again
	/// under its recovery key.
	pub fn open(
		&mut self,
		connection: C,
		request: Open<'_>,
		fresh: Fresh,
		authority: &Authority,
	) -> Result<Opening, Refusal> {
		let Open {
			name,
			policy,
			recovery,
			managed,
		} = request;
		if name.is_empty() {
			return Err(Refusal::plain("open needs a room name"));
		}
		if name.encode_utf16().count() > MAX_ROOM {
			return Err(Refusal::coded(
				FailureCode::RoomTooLong,
				format!("a room name may be at most {MAX_ROOM} characters"),
			));
		}
		if let Some(recovery) = recovery
			&& !RecoveryKey::accepts(recovery)
		{
			return Err(Refusal::plain("a private room recovery key is invalid"));
		}
		if policy.is_listed() && (self.public_name_taken(name) || authority.public_name_taken(name)) {
			return Err(Refusal::coded(
				FailureCode::RoomExists,
				format!("room \"{name}\" already exists"),
			));
		}
		let bootstrap = |key: &RoomKey| {
			managed.then(|| Bootstrap {
				name: key.as_str().into(),
				managed: Some((name.into(), policy)),
			})
		};
		if let Some(recovery) = recovery
			&& let Some(recovered) = self.rooms.get(&RoomKey::managed(recovery))
		{
			if recovered.name != name || recovered.policy != policy {
				return Err(Refusal::plain(
					"that room id already belongs to a different managed room state",
				));
			}
			return Ok(Opening {
				entrance: Entrance {
					room: recovered.key.clone(),
					durable: None,
					kind: MembershipKind::Participant,
					gate: Gate::Always,
				},
				bootstrap: bootstrap(&recovered.key),
			});
		}
		let key = match recovery {
			Some(recovery) => RoomKey::managed(recovery),
			None if policy.is_listed() => RoomKey::public(name),
			None => RoomKey::managed(fresh.private_key.as_str()),
		};
		// A private room's subject follows its recovery key; a public room's, its name.
		let durable = if key.is_public() { name } else { key.as_str() };
		let subject = authority.subject(durable).cloned().unwrap_or_default();
		let room = self.make_room(name, key.clone(), policy, connection, fresh.entry_id, subject)?;
		self.register_room(room)?;
		Ok(Opening {
			entrance: Entrance {
				room: key.clone(),
				durable: None,
				kind: MembershipKind::Participant,
				gate: Gate::Always,
			},
			bootstrap: bootstrap(&key),
		})
	}

	/// `enter`: a live listed room, or a managed or durable name this server
	/// answers for.
	pub fn enter(&self, name: &str, authority: &Authority) -> Result<Entrance, Refusal> {
		if name.is_empty() {
			return Err(Refusal::plain("enter needs one room name"));
		}
		let invite_only = |shown: &str| {
			Refusal::coded(
				FailureCode::NoSuchRoom,
				format!("room \"{shown}\" is invite-only; use an invitation or room link"),
			)
		};
		if let Some(key) = self.public.get(&folded(name)) {
			let room = &self.rooms[key];
			if room.policy.public_membership().is_none() {
				return Err(invite_only(name));
			}
			return Ok(Entrance {
				room: key.clone(),
				durable: None,
				kind: Self::public_kind(room.policy),
				gate: Gate::Public,
			});
		}
		if let Some(id) = authority.managed_room_id_for_name(name) {
			let managed = authority
				.managed_room(id)
				.ok_or_else(|| Refusal::coded(FailureCode::NoSuchRoom, format!("no room named \"{name}\"")))?;
			if managed.policy.public_membership().is_none() {
				return Err(invite_only(name));
			}
			return Ok(Entrance {
				room: RoomKey::managed(id),
				durable: Some(id.into()),
				kind: Self::public_kind(managed.policy),
				gate: Gate::Managed {
					id: id.into(),
					generation: managed.generation,
				},
			});
		}
		if authority.room_link_active(name) && authority.managed_room(name).is_none() {
			return Ok(self.durable_entrance(name, MembershipKind::Participant, authority));
		}
		Err(Refusal::coded(
			FailureCode::NoSuchRoom,
			format!("no room named \"{name}\""),
		))
	}

	/// Exact public admission follows a live publication or persisted authority
	/// generation. A dormant durable room is realized only at subscription.
	pub fn enter_publication(&self, id: &str, authority: &Authority) -> Result<Entrance, Refusal> {
		if let Some(room) = authority.publication_room(id) {
			if !room.managed {
				return Ok(self.durable_entrance(room.id, MembershipKind::Participant, authority));
			}
			return Ok(Entrance {
				room: RoomKey::managed(room.id),
				durable: Some(room.id.into()),
				kind: Self::public_kind(room.policy),
				gate: Gate::Managed {
					id: room.id.into(),
					generation: room.generation,
				},
			});
		}
		let key = self
			.by_entry
			.get(id)
			.ok_or_else(|| Refusal::coded(FailureCode::NoSuchRoom, "that room publication is no longer current"))?;
		let room = &self.rooms[key];
		if room.policy.public_membership().is_none() {
			return Err(Refusal::coded(
				FailureCode::NoSuchRoom,
				format!("room \"{}\" is invite-only; use an invitation or room link", room.name),
			));
		}
		Ok(Entrance {
			room: key.clone(),
			durable: None,
			kind: Self::public_kind(room.policy),
			gate: Gate::Public,
		})
	}

	/// The entrance a durable room link publishes: it rebuilds an empty room
	/// only when its first subscriber arrives.
	pub fn durable_entrance(&self, durable: &str, kind: MembershipKind, authority: &Authority) -> Entrance {
		let key = if RecoveryKey::accepts(durable) {
			RoomKey::managed(durable)
		} else {
			RoomKey::public(durable)
		};
		Entrance {
			room: key,
			durable: Some(durable.into()),
			kind,
			gate: Gate::Link {
				name: durable.into(),
				generation: authority.room_link_generation(durable),
			},
		}
	}

	/// What a room reference says it is called, live or from its durable
	/// name. Empty when a private room came back from a link with nobody left
	/// to remember what it was called.
	pub fn called(&self, entrance: &Entrance, authority: &Authority) -> String {
		if let Some(room) = self.rooms.get(&entrance.room) {
			return room.name.clone();
		}
		let Some(durable) = &entrance.durable else {
			return String::new();
		};
		match authority.managed_room(durable) {
			Some(managed) => managed.name.clone(),
			None if RecoveryKey::accepts(durable) => String::new(),
			None => durable.clone(),
		}
	}
	pub fn policy(&self, entrance: &Entrance, authority: &Authority) -> RoomPolicy {
		if let Some(room) = self.rooms.get(&entrance.room) {
			return room.policy;
		}
		let Some(durable) = &entrance.durable else {
			return RoomPolicy::Open;
		};
		match authority.managed_room(durable) {
			Some(managed) => managed.policy,
			None if RecoveryKey::accepts(durable) => RoomPolicy::Private,
			None => RoomPolicy::Open,
		}
	}
}
