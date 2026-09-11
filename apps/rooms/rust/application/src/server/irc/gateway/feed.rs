//! Feed observations borrow the seat tables while changing the channel room.
//! Roster projections are built only when the room actually asks for one.
use super::*;
use crate::server::irc::{
	protocol::{fold, Message},
	room::Effects,
};

struct Seats<'a, C> {
	network: &'a str,
	key: &'a str,
	seats: Option<&'a BTreeMap<C, Seat>>,
	identities: &'a BTreeMap<C, BTreeMap<String, Identity>>,
}
impl<C: Copy + Ord> Seats<'_, C> {
	fn view(&self, connection: C) -> Option<View> {
		let seat = self.seats?.get(&connection)?;
		let identity = self.identities.get(&connection)?.get(self.key)?;
		Some(View {
			network: self.network.into(),
			phase: if identity.enabled { seat.phase } else { Phase::Rooms },
			nick: seat.live_nick.clone(),
		})
	}
	fn nick(&self, nick: &str) -> bool {
		let folded = fold(nick);
		self.seats
			.into_iter()
			.flat_map(|seats| seats.iter())
			.any(|(connection, seat)| {
				seat.phase.occupies()
					&& (fold(&seat.live_nick) == folded
						|| self
							.identities
							.get(connection)
							.and_then(|networks| networks.get(self.key))
							.is_some_and(|identity| fold(&identity.irc_nick) == folded))
			})
	}
}
impl<C: Copy + Ord, R: Clone> Gateway<C, R> {
	pub fn subscribe_reader(
		&mut self,
		key: &str,
		connection: C,
		nick: &str,
		inbox: R,
		kind: crate::room::policy::MembershipKind,
	) -> Result<Effects<C, R>, String> {
		self.feed_room(key, |bridge, seats| {
			let note = alloc::format!(
				"this room bridges to {}; your member row shows whether your IRC identity is connected",
				bridge.room.channel()
			);
			let bytes = bridge.room.line_bytes();
			bridge
				.room
				.subscribe(connection, nick, inbox, kind, &note, bytes, &|connection| {
					seats.view(connection)
				})
				.map_err(|e| e.reason())
		})
	}

	pub fn feed_observe(&mut self, key: &str, message: &Message) -> Result<Effects<C, R>, String> {
		self.feed_room(key, |bridge, seats| {
			bridge
				.room
				.observe(message, &|nick| seats.nick(nick), &|connection| seats.view(connection))
		})
	}
	pub fn feed_disconnected(&mut self, key: &str) -> Result<Effects<C, R>, String> {
		self.feed_room(key, |bridge, seats| {
			Ok(bridge.room.disconnected(&|connection| seats.view(connection)))
		})
	}
	pub fn feed_refused(&mut self, key: &str, reason: &str) -> Result<Effects<C, R>, String> {
		self.feed_room(key, |bridge, seats| {
			bridge.status = FeedStatus::Backoff;
			bridge.problem = reason.into();
			// The adapter already has the refusal; consume the channel's failure
			// action here so reporting it does not recursively refuse the relay.
			bridge.room.relay().refused(reason.into());
			Ok(bridge.room.left_channel(&|connection| seats.view(connection)))
		})
	}
	fn feed_room(
		&mut self,
		key: &str,
		apply: impl FnOnce(&mut Bridge<C, R>, &Seats<'_, C>) -> Result<Effects<C, R>, String>,
	) -> Result<Effects<C, R>, String> {
		let bridge = self.bridges.get_mut(key).ok_or("IRC channel was retired")?;
		let (network_key, network) = self
			.networks
			.get_key_value(&bridge.network)
			.ok_or("IRC network was retired")?;
		let seats = Seats {
			network: &network.choice.network,
			key: network_key,
			seats: self.seats.get(key),
			identities: &self.identities,
		};
		apply(bridge, &seats)
	}
}

fn seats<'a, C: Copy + Ord, R: Clone>(gateway: &'a Gateway<C, R>, key: &str) -> Option<Seats<'a, C>> {
	let bridge = gateway.bridges.get(key)?;
	let (network_key, network) = gateway.networks.get_key_value(&bridge.network)?;
	Some(Seats {
		network: &network.choice.network,
		key: network_key,
		seats: gateway.seats.get(key),
		identities: &gateway.identities,
	})
}
pub(super) fn view<C: Copy + Ord, R: Clone>(gateway: &Gateway<C, R>, key: &str, connection: C) -> Option<View> {
	seats(gateway, key)?.view(connection)
}
pub(super) fn seat_nick<C: Copy + Ord, R: Clone>(gateway: &Gateway<C, R>, key: &str, nick: &str) -> bool {
	seats(gateway, key).is_some_and(|seats| seats.nick(nick))
}
