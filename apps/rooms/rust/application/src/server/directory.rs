//! The directory a Rooms server answers: who is registered, who is watching,
//! and the signaling it relays between members. Connections are the adapter's
//! keys (`C`) and capabilities its tokens (`R`); the policy holds neither open
//! and performs no effect. Every verb answers with what the adapter must do
//! next, so the same decisions run under any host, and a test can read them
//! without a wire.
mod discovery;
mod registry;
mod signaling;
#[cfg(test)]
mod tests;
mod watchers;

use crate::{
	directory::{
		Event,
		registration::{Id, Kind},
	},
	failure::FailureCode,
	room::inbox::nick_refusal,
};
use alloc::{string::String, vec::Vec};
pub use discovery::Shape;
pub use registry::{InboxOffer, Register};
pub use signaling::{Offered, Relay, Route};

pub const MAX_WATCHERS: usize = 256;
/// Inboxes one member may offer across peer openings, and the reciprocal
/// direct requests it may track.
pub const MAX_DM_INBOXES: usize = 256;
pub const MAX_NAME_VOUCHERS: usize = 8;
pub const NAME_VOUCHER_BYTES: usize = 32;
/// One reciprocal-route notice per requesting peer inside this window.
pub const DIRECT_REQUEST_COALESCE_MS: u64 = 1_000;
pub use crate::signaling::{
	MAX_CANDIDATE as MAX_SIGNAL_CANDIDATE, MAX_DESCRIPTION as MAX_SIGNAL_SDP, MAX_EXCHANGES as MAX_SIGNAL_EXCHANGES,
	MAX_ID as MAX_SIGNAL_ID, TIMEOUT_MS as SIGNAL_EXCHANGE_TIMEOUT_MS,
};

pub use super::{Refusal, Release};

/// What a member's register inbox is told.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Notice {
	/// The name is filed; the registration id names this exact holding.
	Registered { nick: String, id: Id },
	/// A peer offered an inbox for this member; `introduce` may be retried.
	Introducible { nick: String, id: Id, opening: String },
	/// A peer asked to be introduced and no inbox was offered for it yet.
	MintInboxFor { nick: String, id: Id, opening: String },
	/// A peer asks this member to open the route from its side.
	DirectRequested { nick: String, id: Id },
}
impl Notice {
	pub fn kind(&self) -> Option<Kind> {
		match self {
			Self::Registered { .. } => None,
			Self::Introducible { .. } => Some(Kind::Introducible),
			Self::MintInboxFor { .. } => Some(Kind::MintInboxFor),
			Self::DirectRequested { .. } => Some(Kind::DirectRequested),
		}
	}
}

/// A notice the adapter tells on a member's inbox.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Tell<C, R> {
	pub connection: C,
	pub inbox: R,
	pub notice: Notice,
}

/// A signaling exchange the directory let go, with the reply capability to
/// reject on (when the originator is still owed an answer) and then release.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Dropped<C, R> {
	pub id: String,
	pub originator: C,
	pub reply: R,
	/// Why, when the originator is told; a completed exchange says nothing.
	pub reason: Option<String>,
}

/// Everything one verb asks the adapter to do, in the order to do it.
#[derive(Debug, PartialEq, Eq)]
pub struct Effects<C, R> {
	pub releases: Vec<Release<C, R>>,
	pub tells: Vec<Tell<C, R>>,
	/// Directory events every watcher hears, in order.
	pub events: Vec<Event>,
	pub dropped: Vec<Dropped<C, R>>,
}
impl<C, R> Default for Effects<C, R> {
	fn default() -> Self {
		Self {
			releases: Vec::new(),
			tells: Vec::new(),
			events: Vec::new(),
			dropped: Vec::new(),
		}
	}
}
impl<C, R> Effects<C, R> {
	fn release(&mut self, connection: C, capability: R) {
		self.releases.push(Release { connection, capability });
	}
	fn tell(&mut self, connection: C, inbox: R, notice: Notice) {
		self.tells.push(Tell {
			connection,
			inbox,
			notice,
		});
	}
	fn extend(&mut self, other: Self) {
		self.releases.extend(other.releases);
		self.tells.extend(other.tells);
		self.events.extend(other.events);
		self.dropped.extend(other.dropped);
	}
}

/// What `introduce` answers: the inbox the member offered for the caller, or
/// the member to ask for one, after which the caller is told to try again.
#[derive(Debug, PartialEq, Eq)]
pub enum Introduction<C, R> {
	Inbox(R),
	Pending(Tell<C, R>),
}

/// The whole directory for one server.
pub struct Directory<C, R> {
	registry: registry::Registry<C, R>,
	watchers: watchers::Watchers<C, R>,
	exchanges: signaling::Exchanges<C, R>,
}

impl<C: Copy + Ord, R: Clone> Default for Directory<C, R> {
	fn default() -> Self {
		Self {
			registry: registry::Registry::default(),
			watchers: watchers::Watchers::default(),
			exchanges: signaling::Exchanges::default(),
		}
	}
}

impl<C: Copy + Ord, R: Clone> Directory<C, R> {
	/// File `request` under `connection`. `id` is the registration's fresh
	/// identity, minted by the adapter. A name another live connection holds
	/// needs a current voucher for it; a member re-registering on a connection
	/// the directory can prove is the same peer replaces its own rows.
	pub fn register(
		&mut self,
		connection: C,
		request: Register<R>,
		id: Id,
		now: u64,
	) -> Result<Effects<C, R>, Refusal> {
		if let Some(refusal) = nick_refusal(&request.nick) {
			return Err(Refusal::coded(FailureCode::NickTooLong, refusal));
		}
		if !request.own_locator {
			return Err(Refusal::coded(
				FailureCode::NotYourLocator,
				alloc::format!(
					"the locator \"{}\" does not name the connection registering it",
					request.locator
				),
			));
		}
		let mut effects = self.registry.register(connection, request, id, now)?;
		for dropped in self.exchanges.drop_targeting(&effects.withdrawn_keys) {
			effects.effects.dropped.push(dropped);
		}
		Ok(effects.effects)
	}
	/// The connection ended: its registration, watcher, and exchanges go.
	pub fn connection_closed(&mut self, connection: C) -> Effects<C, R> {
		let mut effects = Effects::default();
		if let Some(observer) = self.watchers.remove(connection) {
			effects.release(connection, observer);
		}
		let withdrawn = self.registry.withdraw_connection(connection);
		for dropped in self.exchanges.drop_targeting(&withdrawn.withdrawn_keys) {
			effects.dropped.push(dropped);
		}
		effects.extend(withdrawn.effects);
		for dropped in self.exchanges.drop_originated_by(connection) {
			effects.dropped.push(dropped);
		}
		effects
	}
	pub fn offer_inbox(
		&mut self,
		connection: C,
		for_nick: &str,
		for_id: &str,
		opening: &str,
		offered: R,
	) -> Result<Effects<C, R>, Refusal> {
		let offer = self.prepare_inbox(connection, for_nick, for_id, opening)?;
		self.complete_inbox(offer, offered)
	}
	pub fn prepare_inbox(&self, connection: C, peer: &str, id: &str, opening: &str) -> Result<InboxOffer<C>, Refusal> {
		self.registry.prepare_inbox(connection, peer, id, opening)
	}
	pub fn complete_inbox(&mut self, offer: InboxOffer<C>, inbox: R) -> Result<Effects<C, R>, Refusal> {
		self.registry.complete_inbox(offer, inbox)
	}
	pub fn introduce(
		&mut self,
		connection: C,
		nick: &str,
		id: &str,
		opening: &str,
	) -> Result<Introduction<C, R>, Refusal> {
		self.registry.introduce(connection, nick, id, opening)
	}
	pub fn request_direct(
		&mut self,
		connection: C,
		nick: &str,
		id: &str,
		now: u64,
	) -> Result<Option<Tell<C, R>>, Refusal> {
		self.registry.request_direct(connection, nick, id, now)
	}
	pub fn member_registration(&self, nick: &str) -> Result<Id, Refusal> {
		self.registry.member_registration(nick)
	}
	/// Mint a voucher for the name `id` holds, recording `bytes` the adapter
	/// drew. The name capability answers only while this registration stands.
	pub fn voucher(&mut self, id: &Id, bytes: [u8; NAME_VOUCHER_BYTES]) -> Result<(), Refusal> {
		self.registry.voucher(id, bytes)
	}
	pub fn registration_connection(&self, id: &Id) -> Result<C, Refusal> {
		self.registry.registration_connection(id)
	}
	/// Retire only the registration selected by its actual name capability.
	/// Repeating retirement is a no-op, including after the same nickname or
	/// connection acquires a replacement registration. Discovery watchers have
	/// independent custody and remain until their own cancellation or disconnect.
	pub fn retire_registration(&mut self, id: &Id) -> Effects<C, R> {
		let (connection, mut withdrawn) = self.registry.withdraw_id(id);
		withdrawn
			.effects
			.dropped
			.extend(self.exchanges.drop_targeting(&withdrawn.withdrawn_keys));
		if let Some(connection) = connection {
			withdrawn
				.effects
				.dropped
				.extend(self.exchanges.drop_originated_by(connection));
		}
		withdrawn.effects
	}
	/// The nick `connection` registered, when it registered one.
	pub fn registered_nick(&self, connection: C) -> Option<&str> {
		self.registry.nick_of(connection)
	}
	/// Whether `nick` is held for direct messages by a connection that is
	/// neither `connection` nor the same proved peer: a room granting the
	/// name would then put one name on two people.
	pub fn registered_by_another(&self, connection: C, nick: &str, same_claimant: impl Fn(C, C) -> bool) -> bool {
		self.registry
			.holder_of(nick)
			.is_some_and(|holder| holder != connection && !same_claimant(holder, connection))
	}
	/// Spend one voucher for `nick`, true exactly once per minted voucher.
	pub fn redeem_voucher(&mut self, nick: &str, voucher: &[u8; NAME_VOUCHER_BYTES]) -> bool {
		self.registry.redeem(nick, voucher)
	}
	/// Watch the directory from `connection`. Watching again replaces, so a
	/// connection holds one view; the replaced observer is given back.
	pub fn watch(
		&mut self,
		connection: C,
		observer: R,
		shape: Shape,
		rooms: impl Iterator<Item = crate::directory::RoomInfo>,
	) -> Result<(discovery::Snapshot, Option<Release<C, R>>), Refusal> {
		let replaced = self.watchers.push(connection, observer, shape)?;
		let snapshot = discovery::snapshot(&self.registry, rooms, shape);
		Ok((snapshot, replaced.map(|capability| Release { connection, capability })))
	}
	/// Cancel exactly this connection's observer. A delayed cancellation of a
	/// replaced observer cannot retire its successor; repeated cancellation is empty.
	pub fn unwatch(&mut self, connection: C, observer: &R) -> Option<Release<C, R>>
	where
		R: PartialEq,
	{
		self.watchers
			.remove_exact(connection, observer)
			.map(|capability| Release { connection, capability })
	}
	/// The baseline `watch` answers: the listed rooms the server hosts and
	/// the members registered here, under one row ceiling.
	pub fn snapshot(
		&self,
		shape: Shape,
		rooms: impl Iterator<Item = crate::directory::RoomInfo>,
	) -> discovery::Snapshot {
		discovery::snapshot(&self.registry, rooms, shape)
	}
	/// Every watcher, with the shape each asked for.
	pub fn watchers(&self) -> impl Iterator<Item = (C, &R, Shape)> {
		self.watchers.iter()
	}
	/// Every registration as an inventory reads it.
	pub fn registrations(&self) -> impl Iterator<Item = registry::Face<C>> + '_ {
		self.registry.faces()
	}
	/// Every signaling exchange in flight.
	pub fn exchanges(&self) -> impl Iterator<Item = signaling::ExchangeFace<C>> + '_ {
		self.exchanges.faces()
	}
	/// An operator revokes one registration: it goes the way its connection
	/// leaving would take it, and the exchanges aimed at it are dropped.
	pub fn revoke_registration(&mut self, nick: &str) -> Effects<C, R> {
		let mut effects = Effects::default();
		let withdrawn = self.registry.withdraw_nick(nick);
		for dropped in self.exchanges.drop_targeting(&withdrawn.withdrawn_keys) {
			effects.dropped.push(dropped);
		}
		effects.extend(withdrawn.effects);
		effects
	}
	pub fn release_offered(&mut self, nick: &str, peer: &str) -> Option<Vec<Release<C, R>>> {
		self.registry.release_offered(nick, peer)
	}
	pub fn release_signaling(&mut self, nick: &str) -> Option<Release<C, R>> {
		self.registry.release_signaling(nick)
	}
	/// An operator drops one exchange; its originator hears why.
	pub fn drop_exchange(&mut self, id: &str) -> Option<Dropped<C, R>> {
		self.exchanges
			.drop(id, Some("an operator released this signaling exchange".into()))
	}
	/// A watcher whose delivery failed is dropped only once its connection is
	/// known to be gone; the adapter decides that and calls `connection_closed`.
	pub fn offer_signaling(&mut self, connection: C, inbox: R) -> Result<Option<Release<C, R>>, Refusal> {
		self.registry.offer_signaling(connection, inbox)
	}
	/// Start an exchange toward the member registered at `designator`. The
	/// exchange id is minted here; the adapter delivers `offer` to the target
	/// and, once that delivery is accepted, tells the originator `accepted`.
	pub fn signal_offer(
		&mut self,
		connection: C,
		designator: &str,
		reply: R,
		now: u64,
	) -> Result<signaling::Offered<C, R>, Refusal> {
		if self.registry.nick_of(connection).is_none() {
			return Err(Refusal::coded(
				FailureCode::NotRegistered,
				"signalOffer needs a registered name",
			));
		}
		let (target_key, target) = self
			.registry
			.signaling_target(designator)
			.ok_or_else(|| Refusal::coded(FailureCode::PeerOffline, "no signaling inbox for that designator"))?;
		Ok(self.exchanges.offer(connection, reply, target_key, target, now))
	}
	pub fn signal_answer(&self, connection: C, id: &str) -> Result<Option<Route<C, R>>, Refusal> {
		self.exchanges
			.answer(connection, id, |key| self.registry.registrar(key))
	}
	pub fn signal_candidate(&self, connection: C, id: &str) -> Option<Relay<C, R>> {
		self.exchanges
			.candidate(connection, id, |key| self.registry.signaling_of(key))
	}
	/// Whether the exchange `id` is still open, for a delivery that finished
	/// after the exchange may have been retired.
	pub fn signaling_open(&self, id: &str) -> bool {
		self.exchanges.contains(id)
	}
	/// Whether a registration already holds `id`, so a minted identity is
	/// never filed twice.
	pub fn registration_known(&self, id: &Id) -> bool {
		self.registry.holds_id(id)
	}
	pub fn signal_done(&mut self, connection: C, id: &str) -> Option<Dropped<C, R>> {
		self.exchanges.done(connection, id)
	}
	/// An exchange the target's delivery could not reach.
	pub fn signal_failed(&mut self, id: &str, what: &str) -> Option<Dropped<C, R>> {
		self.exchanges
			.drop(id, Some(alloc::format!("{what} could not be delivered")))
	}
	/// Exchanges older than their timeout at `now`.
	pub fn expire_signaling(&mut self, now: u64) -> Vec<Dropped<C, R>> {
		self.exchanges.expire(now)
	}
	/// When the next exchange expires, so the adapter can sleep until then.
	pub fn next_signaling_expiry(&self) -> Option<u64> {
		self.exchanges.next_expiry()
	}
}
