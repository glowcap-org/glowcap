//! Seating a member through an entrance: the gate is checked again, the
//! nickname is claimed, and the membership's facets are handed out.
use super::{
	Effects, MembershipKey, Refusal, Refused, Rooms,
	entrance::{Entrance, Fresh, Gate, closed},
	notice::Notice,
	state::Member,
};
use crate::{
	directory::{Event, RoomChange, creation::RecoveryKey},
	failure::FailureCode,
	room::{
		carries::Carries,
		inbox::nick_refusal,
		policy::{MembershipKind, RoomPolicy},
	},
	server::{directory::Directory, links::Authority},
};
use alloc::{format, string::String};

/// A seated member and what seating them asked for.
#[derive(Debug, PartialEq)]
pub struct Subscribed<C, R> {
	pub membership: MembershipKey,
	pub kind: MembershipKind,
	pub effects: Effects<C, R>,
}

impl<C: Copy + Ord, R: Clone> Rooms<C, R> {
	/// Seat `connection` in the room `entrance` names. `seat` and `subject_facet` are
	/// the adapter's freshly minted tokens for this membership. A refusal
	/// gives them back with the inbox. `same_claimant` says whether two
	/// connections are one proved peer.
	#[allow(clippy::too_many_arguments)]
	pub fn subscribe(
		&mut self,
		connection: C,
		entrance: &Entrance,
		nick: &str,
		inbox: R,
		voucher: Option<[u8; super::super::directory::NAME_VOUCHER_BYTES]>,
		seat: R,
		subject_facet: Option<R>,
		directory: &mut Directory<C, R>,
		same_claimant: impl Fn(C, C) -> bool,
		authority: &Authority,
		fresh: Option<Fresh>,
	) -> Result<Subscribed<C, R>, Refused<R>> {
		let mut returned = alloc::vec![inbox.clone(), seat.clone()];
		returned.extend(subject_facet.clone());
		let refuse = |refusal: Refusal| Refused { refusal, returned };
		if !self.gate_open(connection, entrance, authority) {
			return Err(refuse(Refusal::coded(
				FailureCode::NoSuchRoom,
				match entrance.gate {
					Gate::Link { .. } => "this room link was revoked",
					_ => "this room entrance is no longer offered",
				},
			)));
		}
		if let Some(unnameable) = nick_refusal(nick) {
			return Err(refuse(Refusal::coded(FailureCode::NickTooLong, unnameable)));
		}
		let created = if !self.rooms.contains_key(&entrance.room) {
			let Some(durable) = entrance.durable.as_deref() else {
				return Err(refuse(Refusal::coded(
					FailureCode::NoSuchRoom,
					"this room entrance is no longer offered",
				)));
			};
			let Some(fresh) = fresh else {
				return Err(refuse(Refusal::plain("a durable room needs a fresh identity")));
			};
			let managed = authority.managed_room(durable);
			let opaque = RecoveryKey::accepts(durable);
			let (name, policy) = match managed {
				Some(managed) => (managed.name.clone(), managed.policy),
				None if opaque => (String::new(), RoomPolicy::Private),
				None => (durable.into(), RoomPolicy::Open),
			};
			let subject = authority.subject(durable).cloned().unwrap_or_default();
			let room = match self.make_room(
				&name,
				entrance.room.clone(),
				policy,
				connection,
				fresh.entry_id,
				subject,
			) {
				Ok(room) => room,
				Err(refusal) => return Err(refuse(refusal)),
			};
			if let Err(refusal) = self.register_room(room) {
				return Err(refuse(refusal));
			}
			true
		} else {
			false
		};
		match self.seat(
			connection,
			entrance,
			nick,
			inbox,
			voucher,
			seat,
			subject_facet,
			directory,
			same_claimant,
		) {
			Ok(subscribed) => Ok(subscribed),
			Err(refused) => {
				if created {
					self.forget_room(&entrance.room);
				}
				Err(refused)
			}
		}
	}

	#[allow(clippy::too_many_arguments)]
	fn seat(
		&mut self,
		connection: C,
		entrance: &Entrance,
		nick: &str,
		inbox: R,
		voucher: Option<[u8; super::super::directory::NAME_VOUCHER_BYTES]>,
		seat: R,
		subject_facet: Option<R>,
		directory: &mut Directory<C, R>,
		same_claimant: impl Fn(C, C) -> bool,
	) -> Result<Subscribed<C, R>, Refused<R>> {
		let mut returned = alloc::vec![inbox.clone(), seat.clone()];
		returned.extend(subject_facet.clone());
		let refuse = |refusal: Refusal| Refused { refusal, returned };
		let Some(room) = self.rooms.get(&entrance.room) else {
			return Err(refuse(closed()));
		};
		// A voucher is spent only where a holder stands in the way, and once.
		let mut entitlement: Option<bool> = None;
		let mut entitled = |directory: &mut Directory<C, R>| -> bool {
			*entitlement.get_or_insert_with(|| voucher.is_some_and(|voucher| directory.redeem_voucher(nick, &voucher)))
		};
		let previous = room.member_named(nick).map(|member| (member.key, member.connection));
		if let Some((_, holder)) = previous
			&& holder != connection
			&& !same_claimant(holder, connection)
			&& !entitled(directory)
		{
			return Err(refuse(Refusal::coded(
				FailureCode::NickTaken,
				format!("name \"{nick}\" is already claimed"),
			)));
		}
		// The room is not the only holder of a name: someone who left this
		// room but stayed connected still answers to theirs for direct
		// messages, so granting it here would put one name on two people.
		if directory.registered_by_another(connection, nick, &same_claimant) && !entitled(directory) {
			return Err(refuse(Refusal::coded(
				FailureCode::NickTaken,
				format!("name \"{nick}\" is held for direct messages by a member who is still connected"),
			)));
		}
		let already = room
			.member_of(connection)
			.map(|member| (member.key, member.nick.clone()));
		let count_before = room.members.len();
		let replacing = previous.filter(|(_, holder)| *holder != connection).map(|(key, _)| key);
		let Some(names) = room.roster_for(connection, nick, replacing) else {
			return Err(refuse(Refusal::coded(
				FailureCode::RoomFull,
				format!(
					"a room may hold at most {} live members, each named within one line",
					super::MAX_ROOM_MEMBERS
				),
			)));
		};
		let mut effects = Effects::default();
		// A proved reconnect may arrive before the old transport's terminal
		// edge; its claim distinguishes a replacement from a collision, so the
		// old connection's seat goes rather than transferring with the name.
		if let Some((key, holder)) = previous.filter(|(_, holder)| *holder != connection) {
			effects.extend(self.leave_member(&entrance.room, key, Some(holder), Departure::Replaced));
		}
		if let Some((key, _)) = already {
			effects.extend(self.leave_member(&entrance.room, key, None, Departure::Continued));
		}
		let key = MembershipKey(self.next_id());
		let Some(room) = self.rooms.get_mut(&entrance.room) else {
			return Err(refuse(closed()));
		};
		let files = match self.files.member(&room.files) {
			Ok(files) => files,
			Err(error) => return Err(refuse(Refusal::plain(error))),
		};
		if let Gate::Invitation(key) = &entrance.gate {
			// The gate was open a moment ago, so its row should still be live.
			let Some(row) = self.invitations.get_mut(key) else {
				return Err(refuse(Refusal::plain("this invitation is no longer open")));
			};
			row.admission.admit().map_err(|reason| refuse(Refusal::plain(reason)))?;
		}
		room.members.push(Member {
			key,
			nick: nick.into(),
			inbox: inbox.clone(),
			connection,
			kind: entrance.kind,
			away: String::new(),
			typing_until: core::cell::Cell::new(0),
			files,
		});
		effects.presence.push(connection);
		let count = room.members.len();
		let listed = room.policy.is_listed();
		// Complete room metadata precedes the occupancy that marks arrival.
		// Visibility alone cannot distinguish open and moderated rooms.
		effects.tell(connection, inbox.clone(), Notice::Carries(Carries::EVERYTHING));
		effects.tell(connection, inbox.clone(), Notice::PolicyChanged(room.policy));
		effects.tell(connection, inbox.clone(), Notice::Listed(listed));
		self.returning_name(&entrance.room, nick, &mut effects);
		if let Some((_, old_nick)) = already.filter(|(_, old)| old.to_lowercase() != nick.to_lowercase()) {
			self.broadcast(
				&entrance.room,
				&mut effects,
				Notice::Leave { nick: old_nick, count },
				None,
			);
		}
		if previous.is_none() {
			self.broadcast(
				&entrance.room,
				&mut effects,
				Notice::Join {
					nick: nick.into(),
					count,
				},
				None,
			);
		}
		if count != count_before && listed {
			let room = &self.rooms[&entrance.room];
			effects.events.push(Event::Room {
				kind: if count_before == 0 {
					RoomChange::Opened
				} else {
					RoomChange::Count
				},
				entry: room.info(),
			});
		}
		let room = &self.rooms[&entrance.room];
		effects.tell(connection, inbox.clone(), Notice::Roster(names));
		self.offline_roster(&entrance.room, connection, inbox.clone(), &mut effects);
		for member in room
			.members
			.iter()
			.filter(|member| !member.away.is_empty() && member.key != key)
		{
			effects.tell(
				connection,
				inbox.clone(),
				Notice::Away {
					nick: member.nick.clone(),
					why: member.away.clone(),
				},
			);
		}
		if !room.subject.is_empty() {
			effects.tell(
				connection,
				inbox,
				Notice::Subject {
					subject: room.subject.clone(),
					changed: false,
				},
			);
		}
		Ok(Subscribed {
			membership: key,
			kind: entrance.kind,
			effects,
		})
	}
}

/// How a membership ends, which decides what is said and what goes with it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Departure {
	/// A real leave: announced, and the room closes if it emptied.
	Left,
	/// The connection ended. Authority is released. A display name stays offline.
	Disconnected,
	/// A departure with the room's word said first to the member.
	Ended,
	/// The same connection continuing one membership under a new seat.
	Continued,
	/// Another connection of the same peer took the name. The old seat goes
	/// quietly with everything its connection held.
	Replaced,
}
