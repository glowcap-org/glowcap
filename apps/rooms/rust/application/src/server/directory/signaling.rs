//! WebRTC signaling relayed between exact live registrations: opaque strings
//! routed between two members the directory already reaches, parsed by
//! nobody. An exchange lives from an offer until it is done, dropped, timed
//! out, or evicted by a newer one past the ceiling.
use super::{Dropped, Refusal, MAX_SIGNAL_EXCHANGES, SIGNAL_EXCHANGE_TIMEOUT_MS};
use alloc::{collections::BTreeMap, format, string::String, vec::Vec};

/// Where one relayed message goes: a capability on a connection.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Route<C, R> {
	pub connection: C,
	pub capability: R,
}

/// Which way a candidate goes: to the target's signaling inbox, which hears
/// the exchange id with it, or back to the originator's reply, which knows
/// its own exchange and hears the candidate alone.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Relay<C, R> {
	Inbox(Route<C, R>),
	Reply(Route<C, R>),
}

/// An offer the directory admitted. The adapter delivers `offer` to the
/// target's signaling inbox and, once that delivery is accepted, tells the
/// originator `accepted` on its reply; ICE waits behind that order.
#[derive(Debug, PartialEq, Eq)]
pub struct Offered<C, R> {
	pub id: String,
	pub target: Route<C, R>,
	/// Exchanges this offer displaced, told and released first.
	pub dropped: Vec<Dropped<C, R>>,
}

struct Exchange<C, R> {
	originator: C,
	reply: R,
	target_key: String,
	expires: u64,
}

/// One exchange as an inventory reads it.
pub struct ExchangeFace<C> {
	pub id: String,
	pub originator: C,
}

pub(super) struct Exchanges<C, R> {
	rows: BTreeMap<String, Exchange<C, R>>,
	/// Insertion order, oldest first, for eviction past the ceiling.
	order: Vec<String>,
	next: u64,
}

impl<C, R> Default for Exchanges<C, R> {
	fn default() -> Self {
		Self {
			rows: BTreeMap::new(),
			order: Vec::new(),
			next: 0,
		}
	}
}

impl<C: Copy + Ord, R: Clone> Exchanges<C, R> {
	pub fn offer(&mut self, originator: C, reply: R, target_key: String, target: (C, R), now: u64) -> Offered<C, R> {
		let mut dropped = Vec::new();
		// One live exchange per originator toward one target; a new offer
		// replaces the one before it.
		let prior = self
			.rows
			.iter()
			.find(|(_, row)| row.originator == originator && row.target_key == target_key)
			.map(|(id, _)| id.clone());
		if let Some(prior) = prior {
			dropped.extend(self.drop(&prior, Some("signaling exchange was replaced".into())));
		}
		let id = format!("x{}", self.next);
		self.next = self.next.wrapping_add(1);
		self.rows.insert(
			id.clone(),
			Exchange {
				originator,
				reply,
				target_key,
				expires: now.saturating_add(SIGNAL_EXCHANGE_TIMEOUT_MS),
			},
		);
		self.order.push(id.clone());
		while self.rows.len() > MAX_SIGNAL_EXCHANGES {
			let oldest = self.order[0].clone();
			dropped.extend(self.drop(&oldest, Some("signaling exchange was evicted".into())));
		}
		Offered {
			id,
			target: Route {
				connection: target.0,
				capability: target.1,
			},
			dropped,
		}
	}
	/// The answering member's reply, routed to the originator.
	pub fn answer(
		&self,
		connection: C,
		id: &str,
		registrar: impl Fn(&str) -> Option<C>,
	) -> Result<Option<Route<C, R>>, Refusal> {
		let Some(row) = self.rows.get(id) else {
			return Ok(None);
		};
		if registrar(&row.target_key) != Some(connection) {
			return Err(Refusal::plain(
				"signalAnswer from a session that does not answer this exchange",
			));
		}
		Ok(Some(Route {
			connection: row.originator,
			capability: row.reply.clone(),
		}))
	}
	/// A candidate from either side, routed to the other. Nobody else's
	/// candidate goes anywhere.
	pub fn candidate(
		&self,
		connection: C,
		id: &str,
		signaling: impl Fn(&str) -> Option<(C, R)>,
	) -> Option<Relay<C, R>> {
		let row = self.rows.get(id)?;
		let target = signaling(&row.target_key);
		if row.originator == connection {
			let (target, inbox) = target?;
			return Some(Relay::Inbox(Route {
				connection: target,
				capability: inbox,
			}));
		}
		if target.map(|(target, _)| target) != Some(connection) {
			return None;
		}
		Some(Relay::Reply(Route {
			connection: row.originator,
			capability: row.reply.clone(),
		}))
	}
	pub fn contains(&self, id: &str) -> bool {
		self.rows.contains_key(id)
	}
	/// The originator retires its own exchange; nothing is told.
	/// Every exchange in flight, oldest first.
	pub fn faces(&self) -> impl Iterator<Item = ExchangeFace<C>> + '_ {
		self.order.iter().filter_map(|id| {
			self.rows.get(id).map(|row| ExchangeFace {
				id: id.clone(),
				originator: row.originator,
			})
		})
	}
	pub fn done(&mut self, connection: C, id: &str) -> Option<Dropped<C, R>> {
		if self.rows.get(id)?.originator != connection {
			return None;
		}
		self.drop(id, None)
	}
	pub fn drop(&mut self, id: &str, reason: Option<String>) -> Option<Dropped<C, R>> {
		let row = self.rows.remove(id)?;
		self.order.retain(|held| held != id);
		Some(Dropped {
			id: id.into(),
			originator: row.originator,
			reply: row.reply,
			reason,
		})
	}
	/// Exchanges aimed at registrations that left: their originators are
	/// live third parties mid-dial, told rather than left to a timeout.
	pub fn drop_targeting(&mut self, keys: &[String]) -> Vec<Dropped<C, R>> {
		let ids: Vec<String> = self
			.rows
			.iter()
			.filter(|(_, row)| keys.contains(&row.target_key))
			.map(|(id, _)| id.clone())
			.collect();
		ids.iter()
			.filter_map(|id| self.drop(id, Some("the member is no longer registered".into())))
			.collect()
	}
	/// Exchanges a closing connection originated; nobody is left to tell.
	pub fn drop_originated_by(&mut self, connection: C) -> Vec<Dropped<C, R>> {
		let ids: Vec<String> = self
			.rows
			.iter()
			.filter(|(_, row)| row.originator == connection)
			.map(|(id, _)| id.clone())
			.collect();
		ids.iter().filter_map(|id| self.drop(id, None)).collect()
	}
	pub fn expire(&mut self, now: u64) -> Vec<Dropped<C, R>> {
		let ids: Vec<String> = self
			.rows
			.iter()
			.filter(|(_, row)| row.expires <= now)
			.map(|(id, _)| id.clone())
			.collect();
		ids.iter()
			.filter_map(|id| self.drop(id, Some("signaling exchange timed out".into())))
			.collect()
	}
	pub fn next_expiry(&self) -> Option<u64> {
		self.rows.values().map(|row| row.expires).min()
	}
}
