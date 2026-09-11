//! Who is here, who just left, and how a room says so. Presence is the
//! room's own word: a membership is granted by subscribing and ends with the
//! connection or a leave, and everything below states that word to the
//! members and to the watchers following the live list.
use super::{entrance::Departure, notice::Notice, state::public_key, Effects, MembershipKey, RoomKey, Rooms};
use crate::{
	directory::{Event, RoomChange},
	room::stewardship::Kind,
	server::links::Authority,
};
use alloc::{string::String, vec::Vec};

impl<C: Copy + Ord, R: Clone> Rooms<C, R> {
	/// Say `notice` to every member of `key`, skipping `except`.
	pub(super) fn broadcast(&self, key: &RoomKey, effects: &mut Effects<C, R>, notice: Notice, except: Option<C>) {
		let Some(room) = self.rooms.get(key) else {
			return;
		};
		for member in &room.members {
			if except == Some(member.connection) {
				continue;
			}
			effects.tell(member.connection, member.inbox.clone(), notice.clone());
		}
	}

	/// End one exact membership. `holder` is the connection whose other
	/// resources go with a replacement from a new connection.
	pub(super) fn leave_member(
		&mut self,
		key: &RoomKey,
		membership: MembershipKey,
		holder: Option<C>,
		how: Departure,
	) -> Effects<C, R> {
		let mut effects = Effects::default();
		let Some(room) = self.rooms.get_mut(key) else {
			return effects;
		};
		let Some(at) = room.members.iter().position(|member| member.key == membership) else {
			return effects;
		};
		let member = room.members.remove(at);
		effects.presence.push(member.connection);
		let count = room.members.len();
		let listed = room.policy.is_listed();
		// A same-connection resubscribe keeps the uploads and invitations its
		// continuing connection owns; every other ending cuts what the
		// membership let into the room.
		if how != Departure::Continued {
			let _ = self.files.close_member(&member.files);
			let minter = holder.unwrap_or(member.connection);
			self.retire_invitations_from(key, minter);
		}
		effects.release(member.connection, member.inbox);
		match how {
			Departure::Left | Departure::Ended => {
				self.broadcast(
					key,
					&mut effects,
					Notice::Leave {
						nick: member.nick.clone(),
						count,
					},
					None,
				);
				// The record is drawn before the room is forgotten: a closed
				// event names the room by what it was.
				let entry = self.rooms[key].info();
				if count == 0 {
					effects.extend(self.forget_room(key));
					if listed {
						effects.events.push(Event::Room {
							kind: RoomChange::Closed,
							entry,
						});
					}
				} else if listed {
					effects.events.push(Event::Room {
						kind: RoomChange::Count,
						entry,
					});
				}
			}
			Departure::Continued | Departure::Replaced => {}
		}
		effects
	}

	/// Retire every live invitation one connection minted into `key`.
	pub(super) fn retire_invitations_from(&mut self, key: &RoomKey, minter: C) {
		let Some(room) = self.rooms.get_mut(key) else {
			return;
		};
		let retired: Vec<_> = room
			.invitations
			.iter()
			.copied()
			.filter(|invitation| self.invitations.get(invitation).is_some_and(|row| row.minter == minter))
			.collect();
		for invitation in retired {
			room.invitations.remove(&invitation);
			if let Some(row) = self.invitations.get_mut(&invitation) {
				row.active = false;
			}
		}
	}

	/// Take a room out of the index: its invitations end, its files go, and
	/// its public name frees. Announcing the closure is the caller's.
	pub(super) fn forget_room(&mut self, key: &RoomKey) -> Effects<C, R> {
		let mut effects = Effects::default();
		let Some(room) = self.rooms.remove(key) else {
			return effects;
		};
		for invitation in &room.invitations {
			if let Some(row) = self.invitations.get_mut(invitation) {
				row.active = false;
			}
		}
		let _ = self.files.close_room(&room.files);
		if room.policy.is_listed() {
			let public = public_key(&room.name);
			if self.public.get(&public) == Some(key) {
				self.public.remove(&public);
			}
			self.by_entry.remove(room.entry_id.as_str());
		}
		let held = self.per_owner.get(&room.lifetime_owner).copied().unwrap_or(1);
		if held > 1 {
			self.per_owner.insert(room.lifetime_owner, held - 1);
		} else {
			self.per_owner.remove(&room.lifetime_owner);
		}
		for member in room.members {
			effects.presence.push(member.connection);
			effects.release(member.connection, member.inbox);
		}
		// The lines this generation made keep answering their holders as
		// withdrawn; their history rows have no room to update.
		self.lines.retain(|_, line| &line.room != key);
		self.uploads.retain(|_, upload| &upload.room != key);
		effects
	}

	/// The connection ended: every membership it held goes as a leave would,
	/// every room it opened and never entered goes with it, and every upload
	/// and invitation it owned ends.
	pub fn connection_closed(&mut self, connection: C) -> Effects<C, R> {
		let mut effects = Effects::default();
		let keys: Vec<RoomKey> = self.rooms.keys().cloned().collect();
		for key in keys {
			let membership = self.rooms[&key].member_of(connection).map(|member| member.key);
			match membership {
				Some(membership) => {
					effects.extend(self.leave_member(&key, membership, None, Departure::Left));
				}
				None => {
					let room = &self.rooms[&key];
					if room.members.is_empty() && room.lifetime_owner == connection {
						effects.extend(self.forget_room(&key));
					}
				}
			}
		}
		self.uploads.retain(|_, upload| upload.uploader != connection);
		effects
	}

	/// A member is asked to leave by a steward: everyone hears why first, the
	/// member hears the room's word, and the leave follows.
	pub fn kick(&mut self, key: &RoomKey, nick: &str) -> Result<Effects<C, R>, super::Refusal> {
		if nick.is_empty() {
			return Err(super::Refusal::plain("kick names the member to ask out"));
		}
		let room = self
			.rooms
			.get(key)
			.ok_or_else(|| super::Refusal::plain("that room is not occupied"))?;
		let member = room
			.member_named(nick)
			.ok_or_else(|| super::Refusal::plain(alloc::format!("nobody here answers to \"{nick}\"")))?;
		let (membership, connection, inbox, nick, name) = (
			member.key,
			member.connection,
			member.inbox.clone(),
			member.nick.clone(),
			room.name.clone(),
		);
		let mut effects = Effects::default();
		self.broadcast(
			key,
			&mut effects,
			Notice::Said(alloc::format!("{nick} was asked to leave")),
			None,
		);
		effects.tell(
			connection,
			inbox,
			Notice::Ended(alloc::format!("You were asked to leave #{name}.")),
		);
		effects.extend(self.leave_member(key, membership, None, Departure::Ended));
		Ok(effects)
	}

	/// A room authority rotated: every member of the room named hears which
	/// generation ended.
	pub fn authority_changed(&self, name: &str, kind: Kind, token: &str) -> Effects<C, R> {
		let mut effects = Effects::default();
		let wanted = name.to_lowercase();
		for room in self.rooms.values() {
			if room.durable_name().to_lowercase() != wanted {
				continue;
			}
			for member in &room.members {
				effects.tell(
					member.connection,
					member.inbox.clone(),
					Notice::AuthorityChanged {
						kind,
						token: token.into(),
					},
				);
			}
		}
		effects
	}

	/// A managed room's public name or policy changed in the authority. The
	/// live room, if any, follows: its listing moves, its members are told,
	/// and the watchers hear the room close or open under its name.
	pub fn policy_changed(&mut self, id: &str, authority: &Authority) -> Result<Effects<C, R>, super::Refusal> {
		let mut effects = Effects::default();
		let Some(managed) = authority.managed_room(id) else {
			return Ok(effects);
		};
		let Some(room) = self.rooms.get(id) else {
			return Ok(effects);
		};
		let (old_name, was_listed, old_entry) = (room.name.clone(), room.policy.is_listed(), room.info());
		let listed = managed.policy.is_listed();
		if listed && managed.name.to_lowercase() != old_name.to_lowercase() && self.public_name_taken(&managed.name) {
			return Err(super::Refusal::coded(
				crate::failure::FailureCode::RoomExists,
				alloc::format!("room \"{}\" already exists", managed.name),
			));
		}
		if was_listed {
			let public = public_key(&old_name);
			if self.public.get(&public).map(String::as_str) == Some(id) {
				self.public.remove(&public);
			}
		}
		let room = self.rooms.get_mut(id).expect("checked above");
		room.name = managed.name.clone();
		room.policy = managed.policy;
		let entry_id = String::from(room.entry_id.as_str());
		if listed {
			self.public.insert(public_key(&managed.name), id.into());
			self.by_entry.insert(entry_id, id.into());
		} else {
			self.by_entry.remove(&entry_id);
		}
		self.broadcast(&id.into(), &mut effects, Notice::PolicyChanged(managed.policy), None);
		let renamed = old_name.to_lowercase() != managed.name.to_lowercase();
		if was_listed && (!listed || renamed) {
			effects.events.push(Event::Room {
				kind: RoomChange::Closed,
				entry: crate::directory::RoomInfo {
					count: crate::fields::Nullable::Value(crate::fields::SafeInteger::new(0).expect("zero")),
					..old_entry
				},
			});
		}
		if listed && !self.rooms[id].members.is_empty() {
			effects.events.push(Event::Room {
				kind: if was_listed && !renamed {
					RoomChange::Count
				} else {
					RoomChange::Opened
				},
				entry: self.rooms[id].info(),
			});
		}
		Ok(effects)
	}
}
