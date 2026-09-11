//! The operator's IRC gateway, described as an ordinary bridge gateway: the
//! networks it retains, the channel bridges beneath them, each member's one
//! identity per network, and the description Rooms draws without knowing
//! IRC. The forms are IRC's own words; the answer readers read a submission
//! back against the form this file declared, so the field ids are the one
//! contract between the two halves.
mod feed;
pub mod projection;

use super::{
	model::{channel_key, network_key, BridgeIntent, NetworkChoice},
	registration::{automatic_nick, SaslPlain},
	room::Room,
	seat::{Phase, View},
	MAX_BRIDGED_ROOMS, MAX_READERS_PER_CHANNEL,
};
use crate::failure::FailureCode;
use alloc::{
	collections::{BTreeMap, BTreeSet},
	format,
	string::{String, ToString},
	vec::Vec,
};

/// The generic gateway verbs, shared by every bridge.
pub const OPEN_CONNECTION: &str = "openConnection";
pub const CONNECTION: &str = "connection";
pub const ADD_LEASE: &str = "addLease";
pub const REMOVE_LEASE: &str = "removeLease";
pub const CLOSE_CONNECTION: &str = "closeConnection";
pub const SNAPSHOT: &str = "snapshot";

/// Where the shared feed of one network stands.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FeedStatus {
	/// No channel enacts a transport.
	Dormant,
	Connecting,
	Up,
	Backoff,
}

#[derive(Debug)]
pub struct Network {
	pub choice: NetworkChoice,
	pub status: FeedStatus,
	pub problem: String,
}

/// One bridged channel: the room it became and the feed's word on it.
#[derive(Debug)]
pub struct Bridge<C, R> {
	pub network: String,
	pub room: Room<C, R>,
	pub status: FeedStatus,
	pub problem: String,
	/// Parted: every later verb on a retained room capability is refused.
	pub stopped: bool,
}

/// One member's identity on one network, shared by every channel of it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Identity {
	/// The first membership's runtime id. Adapters supply ids that never
	/// repeat, so a retired identity cannot be mistaken for its successor.
	pub incarnation: u64,
	pub irc_nick: String,
	pub live_nick: String,
	pub enabled: bool,
	pub sasl: Option<SaslPlain>,
	/// The channels this identity is seated on, by channel key.
	pub seats: BTreeSet<String>,
}

/// One member's seat on one bridged channel.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Seat {
	pub phase: Phase,
	pub live_nick: String,
}

#[derive(Debug)]
pub struct Gateway<C, R> {
	networks: BTreeMap<String, Network>,
	bridges: BTreeMap<String, Bridge<C, R>>,
	/// Identities by connection, then network key.
	identities: BTreeMap<C, BTreeMap<String, Identity>>,
	/// Seats by channel key, then connection.
	seats: BTreeMap<String, BTreeMap<C, Seat>>,
}

impl<C, R> Default for Gateway<C, R> {
	fn default() -> Self {
		Self {
			networks: BTreeMap::new(),
			bridges: BTreeMap::new(),
			identities: BTreeMap::new(),
			seats: BTreeMap::new(),
		}
	}
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Refusal {
	pub code: Option<FailureCode>,
	pub detail: String,
}

impl Refusal {
	pub fn plain(detail: impl Into<String>) -> Self {
		Self {
			code: None,
			detail: detail.into(),
		}
	}
	pub fn reason(&self) -> String {
		match self.code {
			Some(code) => format!("{}: {}", code.wire(), self.detail),
			None => self.detail.clone(),
		}
	}
}

impl<C: Copy + Ord, R: Clone> Gateway<C, R> {
	pub fn networks(&self) -> impl Iterator<Item = &Network> {
		self.networks.values()
	}
	pub fn network(&self, name: &str) -> Option<&Network> {
		self.networks.get(&network_key(name))
	}
	pub fn network_mut(&mut self, name: &str) -> Option<&mut Network> {
		self.networks.get_mut(&network_key(name))
	}
	pub fn bridges(&self) -> impl Iterator<Item = (&str, &Bridge<C, R>)> {
		self.bridges.iter().map(|(key, bridge)| (key.as_str(), bridge))
	}
	pub fn bridges_of(&self, network: &str) -> impl Iterator<Item = (&str, &Bridge<C, R>)> {
		let key = network_key(network);
		self.bridges
			.iter()
			.filter(move |(_, bridge)| bridge.network == key)
			.map(|(key, bridge)| (key.as_str(), bridge))
	}
	pub fn bridge(&self, key: &str) -> Option<&Bridge<C, R>> {
		self.bridges.get(key)
	}
	pub fn bridge_mut(&mut self, key: &str) -> Option<&mut Bridge<C, R>> {
		self.bridges.get_mut(key)
	}
	// Directory labels use Rooms name equality. IRC case mapping belongs
	// to network/channel identity and must not alias unrelated Rooms labels.
	fn named_bridge(&self, name: &str) -> Option<(&str, &Bridge<C, R>)> {
		let folded = name.to_lowercase();
		self.bridges
			.iter()
			.find(|(_, bridge)| bridge.room.name().to_lowercase() == folded)
			.map(|(key, bridge)| (key.as_str(), bridge))
	}
	/// The bridge whose room is called `name`, live.
	pub fn by_room_name(&self, name: &str) -> Option<(&str, &Bridge<C, R>)> {
		self.named_bridge(name).filter(|(_, bridge)| !bridge.stopped)
	}
	pub fn by_publication(&self, id: &str) -> Option<(&str, &Bridge<C, R>)> {
		self.bridges
			.iter()
			.find(|(_, bridge)| !bridge.stopped && bridge.room.publication_id() == id)
			.map(|(key, bridge)| (key.as_str(), bridge))
	}
	/// Pending publication retains its name until it stands or is removed.
	pub fn holds_name(&self, name: &str) -> bool {
		self.named_bridge(name).is_some()
	}
	pub fn listed(&self) -> impl Iterator<Item = crate::directory::RoomInfo> + '_ {
		self.bridges
			.values()
			.filter(|bridge| !bridge.stopped)
			.map(|bridge| bridge.room.info())
	}
	/// Retain one network. A second claim on the same name must agree with
	/// the first exactly.
	pub fn open_network(&mut self, choice: NetworkChoice) -> Result<bool, Refusal> {
		choice.validate().map_err(Refusal::plain)?;
		let key = choice.key();
		if let Some(existing) = self.networks.get(&key) {
			if !existing.choice.same(&choice) {
				return Err(Refusal::plain(format!(
					"IRC network {} is already open with different connection settings",
					choice.network
				)));
			}
			return Ok(false);
		}
		self.networks.insert(
			key,
			Network {
				choice,
				status: FeedStatus::Dormant,
				problem: String::new(),
			},
		);
		Ok(true)
	}
	/// Delete one network and answer every channel key beneath it, which
	/// the caller retires.
	pub fn close_network(&mut self, name: &str) -> Result<Vec<String>, Refusal> {
		let key = network_key(name);
		if self.networks.remove(&key).is_none() {
			return Err(Refusal::plain(format!("IRC network {name} is not open")));
		}
		Ok(self
			.bridges
			.iter()
			.filter(|(_, bridge)| bridge.network == key)
			.map(|(key, _)| key.clone())
			.collect())
	}
	/// Stand one channel beside the native rooms. `taken` says whether the
	/// room name or publication id is already a room this directory lists.
	pub fn join_bridge(
		&mut self,
		network: &str,
		channel: &str,
		publication_id: &str,
		taken: &dyn Fn(&str, &str) -> bool,
	) -> Result<String, Refusal> {
		let owner = self
			.networks
			.get(&network_key(network))
			.ok_or_else(|| Refusal::plain(format!("IRC network {network} is not open")))?;
		let key = channel_key(&owner.choice.network, channel);
		if self.bridges.contains_key(&key) {
			return Err(Refusal::plain(format!(
				"{}/{channel} is already bridged",
				owner.choice.network
			)));
		}
		let live = self.bridges.values().filter(|bridge| !bridge.stopped).count();
		if live >= MAX_BRIDGED_ROOMS {
			return Err(Refusal {
				code: Some(FailureCode::TooManyRooms),
				detail: format!("this directory already bridges {MAX_BRIDGED_ROOMS} channels"),
			});
		}
		let room = Room::new(
			&owner.choice.network,
			channel,
			&owner.choice.nick,
			publication_id,
			&owner.choice.endpoint(),
		)
		.map_err(Refusal::plain)?;
		if self.holds_name(room.name()) || taken(room.name(), publication_id) {
			return Err(Refusal {
				code: Some(FailureCode::RoomExists),
				detail: format!("room \"{}\" already exists", room.name()),
			});
		}
		let name = room.name().to_string();
		self.bridges.insert(
			key,
			Bridge {
				network: network_key(network),
				room,
				status: FeedStatus::Connecting,
				problem: String::new(),
				stopped: true,
			},
		);
		Ok(name)
	}
	/// The bridge stands: its intent is kept and its authority published.
	pub fn started(&mut self, key: &str) {
		if let Some(bridge) = self.bridges.get_mut(key) {
			bridge.stopped = false;
			// Committing the first channel starts connection work. Snapshots
			// must expose that pending state before the socket worker is polled.
			if let Some(network) = self
				.networks
				.get_mut(&bridge.network)
				.filter(|n| n.status == FeedStatus::Dormant)
			{
				network.status = FeedStatus::Connecting;
			}
		}
	}
	/// Take one bridge out, answering the room and its seated connections
	/// so the caller can end their memberships and the feed can part.
	pub fn part_bridge(&mut self, key: &str) -> Option<Bridge<C, R>> {
		let bridge = self.bridges.remove(key)?;
		for (connection, _) in self.seats.remove(key).unwrap_or_default() {
			if let Some(identity) = self.identity_mut(connection, &bridge.network) {
				identity.seats.remove(key);
			}
		}
		Some(bridge)
	}
	pub fn intent(&self, key: &str) -> Option<BridgeIntent> {
		let bridge = self.bridges.get(key)?;
		let network = self.networks.get(&bridge.network)?;
		Some(BridgeIntent {
			network: network.choice.network.clone(),
			channel: bridge.room.channel().into(),
			publication_id: bridge.room.publication_id().into(),
		})
	}
	// ── Seats and identities ────────────────────────────────────────────
	pub fn identity(&self, connection: C, network: &str) -> Option<&Identity> {
		self.identities.get(&connection)?.get(&network_key(network))
	}
	pub fn identity_mut(&mut self, connection: C, network: &str) -> Option<&mut Identity> {
		self.identities.get_mut(&connection)?.get_mut(&network_key(network))
	}
	pub fn seat(&self, key: &str, connection: C) -> Option<&Seat> {
		self.seats.get(key)?.get(&connection)
	}
	pub fn seats_of(&self, key: &str) -> impl Iterator<Item = (C, &Seat)> {
		self.seats
			.get(key)
			.into_iter()
			.flat_map(|seats| seats.iter().map(|(c, seat)| (*c, seat)))
	}
	/// The view the room states for one member's seat.
	pub fn view(&self, key: &str, connection: C) -> Option<View> {
		feed::view(self, key, connection)
	}
	/// Whether an IRC nick belongs to a seated member, rather than the feed.
	pub fn seat_nick(&self, key: &str, nick: &str) -> bool {
		feed::seat_nick(self, key, nick)
	}
	/// Seat one reader who just subscribed: a new identity for the network
	/// when they hold none, and a Rooms-only baseline the room states now.
	/// Answers whether the identity is enabled, so the caller opens it.
	pub fn seat_reader(&mut self, key: &str, connection: C, nick: &str, incarnation: u64) -> Option<bool> {
		let bridge = self.bridges.get(key)?;
		if bridge.room.membership_kind(connection).ok()? != crate::room::policy::MembershipKind::Participant {
			return None;
		}
		if self.seat(key, connection).is_some() {
			return None;
		}
		let network = bridge.network.clone();
		let identity = self
			.identities
			.entry(connection)
			.or_default()
			.entry(network)
			.or_insert_with(|| {
				let irc_nick = automatic_nick(nick);
				Identity {
					incarnation,
					live_nick: irc_nick.clone(),
					irc_nick,
					enabled: true,
					sasl: None,
					seats: BTreeSet::new(),
				}
			});
		identity.seats.insert(key.into());
		let live_nick = identity.live_nick.clone();
		let enabled = identity.enabled;
		self.seats.entry(key.into()).or_default().insert(
			connection,
			Seat {
				phase: Phase::Rooms,
				live_nick,
			},
		);
		Some(enabled)
	}
	/// A seat's phase or nick changed. Answers whether anything did.
	pub fn show_seat(&mut self, key: &str, connection: C, phase: Phase, nick: Option<&str>) -> bool {
		let Some(seat) = self.seats.get_mut(key).and_then(|seats| seats.get_mut(&connection)) else {
			return false;
		};
		let nick = nick.unwrap_or(&seat.live_nick).to_string();
		if seat.phase == phase && seat.live_nick == nick {
			return false;
		}
		seat.phase = phase;
		seat.live_nick = nick;
		true
	}
	/// Reflect one identity across every channel it is seated on. Answers
	/// the channel keys whose seat changed.
	pub fn show_identity(&mut self, connection: C, network: &str, phase: Phase, nick: Option<&str>) -> Vec<String> {
		let Some(identity) = self.identity_mut(connection, network) else {
			return Vec::new();
		};
		if let Some(nick) = nick {
			identity.live_nick = nick.into();
		}
		let live = identity.live_nick.clone();
		let keys: Vec<String> = identity.seats.iter().cloned().collect();
		keys.into_iter()
			.filter(|key| self.show_seat(key, connection, phase, Some(&live)))
			.collect()
	}
	/// Retire one seat. Answers whether the identity has no seats left and
	/// so goes with it.
	pub fn retire_seat(&mut self, key: &str, connection: C) -> Option<bool> {
		let bridge = self.bridges.get(key)?;
		let network = bridge.network.clone();
		self.seats.get_mut(key)?.remove(&connection)?;
		let Some(identity) = self.identity_mut(connection, &network) else {
			return Some(false);
		};
		identity.seats.remove(key);
		if identity.seats.is_empty() {
			self.forget_identity(connection, &network);
			return Some(true);
		}
		Some(false)
	}
	pub fn forget_identity(&mut self, connection: C, network: &str) {
		let key = network_key(network);
		if let Some(by_network) = self.identities.get_mut(&connection) {
			by_network.remove(&key);
			if by_network.is_empty() {
				self.identities.remove(&connection);
			}
		}
	}
	/// Every channel one connection is seated on, for its retirement.
	pub fn seated_channels(&self, connection: C) -> Vec<String> {
		self.identities
			.get(&connection)
			.map(|by_network| {
				by_network
					.values()
					.flat_map(|identity| identity.seats.iter().cloned())
					.collect()
			})
			.unwrap_or_default()
	}
	/// Whether one more speaker fits on the channel beside those linked or
	/// linking already.
	pub fn speaker_fits(&self, key: &str, connection: C) -> Result<(), Refusal> {
		let occupied = self
			.seats_of(key)
			.filter(|(held, seat)| *held != connection && seat.phase.occupies())
			.count();
		if occupied >= MAX_READERS_PER_CHANNEL {
			return Err(Refusal::plain(format!(
				"this room seats at most {MAX_READERS_PER_CHANNEL} IRC speakers; the seat list is full"
			)));
		}
		Ok(())
	}
	pub fn network_of_bridge(&self, key: &str) -> Option<&Network> {
		let bridge = self.bridges.get(key)?;
		self.networks.get(&bridge.network)
	}
	/// Every network key one connection holds an identity on.
	pub fn identity_networks(&self, connection: C) -> Vec<String> {
		self.identities
			.get(&connection)
			.map(|by_network| by_network.keys().cloned().collect())
			.unwrap_or_default()
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	fn choice(name: &str) -> NetworkChoice {
		NetworkChoice {
			network: name.into(),
			host: "127.0.0.1".into(),
			port: 6667,
			tls: false,
			nick: "feed".into(),
			sasl: None,
		}
	}

	#[test]
	fn networks_are_retained_once_and_bridges_stand_beneath_them() {
		let mut gateway: Gateway<u32, u8> = Gateway::default();
		assert!(gateway.open_network(choice("Libera")).unwrap());
		assert!(!gateway.open_network(choice("libera")).unwrap());
		let mut other = choice("libera");
		other.port = 6697;
		assert!(gateway.open_network(other).is_err());
		assert!(gateway.join_bridge("nowhere", "#a", "p", &|_, _| false).is_err());
		let name = gateway.join_bridge("libera", "#news", "p1", &|_, _| false).unwrap();
		assert_eq!(name, "Libera/#news");
		assert!(gateway.join_bridge("libera", "#NEWS", "p2", &|_, _| false).is_err());
		assert!(gateway.join_bridge("libera", "#taken", "p3", &|_, _| true).is_err());
		let key = channel_key("libera", "#news");
		assert!(gateway.listed().next().is_none(), "a bridge lists once it stands");
		gateway.started(&key);
		assert!(
			matches!(gateway.network("libera").unwrap().status, FeedStatus::Connecting),
			"a committed first channel must expose pending connection work before the socket worker runs"
		);
		assert_eq!(gateway.listed().count(), 1);
		assert!(gateway.holds_name("libera/#NEWS"));
		assert_eq!(gateway.intent(&key).unwrap().publication_id, "p1");
		let keys = gateway.close_network("libera").unwrap();
		assert_eq!(keys.as_slice(), core::slice::from_ref(&key));
		assert!(gateway.part_bridge(&key).is_some());
		assert!(gateway.close_network("libera").is_err());
	}

	#[test]
	fn room_labels_reserve_pending_names_without_irc_punctuation_aliases() {
		let mut gateway: Gateway<u32, u8> = Gateway::default();
		gateway.open_network(choice("Libera")).unwrap();
		gateway.join_bridge("libera", "#[room]", "p1", &|_, _| false).unwrap();
		assert!(gateway.holds_name("LIBERA/#[ROOM]"));
		assert!(gateway.by_room_name("Libera/#[room]").is_none());
		assert!(!gateway.holds_name("Libera/#{room}"));
		assert!(gateway.join_bridge("libera", "#{room}", "p2", &|_, _| false).is_err());
		let key = channel_key("libera", "#[room]");
		gateway.started(&key);
		assert!(gateway.by_room_name("LIBERA/#[ROOM]").is_some());
		assert!(gateway.by_room_name("Libera/#{room}").is_none());
		gateway.part_bridge(&key);
		assert!(!gateway.holds_name("Libera/#[room]"));
	}

	#[test]
	fn a_member_holds_one_identity_across_a_networks_channels() {
		let mut gateway: Gateway<u32, u8> = Gateway::default();
		gateway.open_network(choice("net")).unwrap();
		gateway.join_bridge("net", "#one", "p1", &|_, _| false).unwrap();
		gateway.join_bridge("net", "#two", "p2", &|_, _| false).unwrap();
		let (one, two) = (channel_key("net", "#one"), channel_key("net", "#two"));
		for key in [&one, &two] {
			gateway
				.subscribe_reader(key, 7, "web alice", 0, crate::room::policy::MembershipKind::Participant)
				.unwrap();
		}
		gateway
			.subscribe_reader(&one, 99, "observer", 0, crate::room::policy::MembershipKind::Observer)
			.unwrap();
		assert!(gateway.seat_reader(&one, 99, "observer", 99).is_none());
		assert!(gateway.identity(99, "net").is_none());
		assert_eq!(gateway.seat_reader(&one, 7, "web alice", 7), Some(true));
		assert!(gateway.seat_reader(&one, 7, "web alice", 7).is_none());
		assert_eq!(gateway.seat_reader(&two, 7, "web alice", 8), Some(true));
		let identity = gateway.identity(7, "net").unwrap();
		assert_eq!(identity.incarnation, 7);
		assert!(identity.irc_nick.starts_with("rooms-"));
		assert_eq!(identity.seats.len(), 2);
		let changed = gateway.show_identity(7, "net", Phase::Linked, Some("alice"));
		assert_eq!(changed.len(), 2);
		assert_eq!(gateway.view(&one, 7).unwrap().nick, "alice");
		assert!(gateway.seat_nick(&one, "ALICE"));
		assert_eq!(gateway.retire_seat(&one, 7), Some(false));
		assert_eq!(gateway.retire_seat(&two, 7), Some(true));
		assert!(gateway.identity(7, "net").is_none());
		assert_eq!(gateway.seat_reader(&two, 7, "web alice", 77), Some(true));
		assert_eq!(gateway.identity(7, "net").unwrap().incarnation, 77);
		gateway.retire_seat(&two, 7);
		gateway.identity_mut(7, "net");
		for at in 0..MAX_READERS_PER_CHANNEL as u32 {
			let nick = alloc::format!("n{at}");
			gateway
				.subscribe_reader(
					&one,
					at + 10,
					&nick,
					0,
					crate::room::policy::MembershipKind::Participant,
				)
				.unwrap();
			gateway.seat_reader(&one, at + 10, &nick, u64::from(at + 10));
			gateway.show_seat(&one, at + 10, Phase::Linked, None);
		}
		assert!(gateway.speaker_fits(&one, 99).is_err());
	}
}
