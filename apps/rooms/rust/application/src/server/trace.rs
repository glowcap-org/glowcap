//! The live timeline endpoint's state: the producers publishing sessions
//! into one feed, each scoped apart so two producers' identical ids stay
//! two rows. The live topology a late viewer replays, and the stamping
//! every forwarded line carries. Sockets and the CapTP trace object are the
//! adapter's. This decides what each line means and who hears it.
pub mod records;

use alloc::{
	borrow::ToOwned,
	collections::{BTreeMap, BTreeSet},
	format,
	string::{String, ToString},
	vec::Vec,
};
use serde_json::{Map, Value};

pub const MAX_ROWS_PER_PRODUCER: usize = 1024;
pub const MAX_REMOTE_PRODUCERS: usize = 64;
pub const MAX_REPLAY_ROWS: usize = 4096;
pub const MAX_FIELD_BYTES: usize = 4096;
pub const MAX_LINE_BYTES: usize = 1 << 20;
pub const MAX_SUBSCRIBERS: usize = 64;
pub const MAX_SUBSCRIBER_QUEUE: usize = 256;
pub const MAX_SUBSCRIBER_QUEUE_BYTES: usize = 8 << 20;

/// The close a refused socket carries.
pub const REFUSED_CLOSE_CODE: u16 = 4403;
pub const REFUSED_REASON: &str = "rooms trace: this endpoint requires its capability";
pub const PRODUCER_LIMIT_CLOSE_CODE: u16 = 1013;
pub const PUBLISH_PATH: &str = "/publish";
pub const CHANNEL_PATH: &str = "/captp";
/// The exporter owns the exact producer route, including deployment prefixes.
/// Credentials come only from the separately held publication token.
pub use crate::web_channel::endpoint as producer_endpoint;
/// What a non-upgrade request is told.
pub const NOT_A_SOCKET: &str = "rooms trace: connect an OCapN byte channel at /captp; / and /publish require the trace capability as ?cap=<swiss>\n";

/// One producer's scope, assigned at admission and never claimed.
pub type Scope = String;

struct Producer {
	/// The producer's own session ids, as it named them.
	rows: BTreeSet<String>,
}

/// A stamped line: what a viewer hears, with the sequence it went out under.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Stamped {
	pub seq: u64,
	pub line: String,
}

pub struct Endpoint {
	producers: BTreeMap<Scope, Producer>,
	remote_producers: usize,
	next_scope: u64,
	seq: u64,
	/// Milliseconds since the Unix epoch when the endpoint started.
	epoch: u64,
	live_opens: BTreeMap<String, Stamped>,
	live_metas: BTreeMap<String, Stamped>,
}

/// Whether two secrets are the same, compared without an early exit, so a
/// probe cannot walk the swiss one character at a time by timing the
/// refusal.
pub fn constant_time_equals(a: &str, b: &str) -> bool {
	let (a, b) = (a.as_bytes(), b.as_bytes());
	let mut diff = (a.len() ^ b.len()) as u8;
	for at in 0..a.len().max(b.len()) {
		diff |= a.get(at).copied().unwrap_or(0) ^ b.get(at).copied().unwrap_or(0);
	}
	diff == 0
}

impl Endpoint {
	pub fn new(epoch: u64) -> Self {
		Self {
			producers: BTreeMap::new(),
			remote_producers: 0,
			next_scope: 0,
			seq: 0,
			epoch,
			live_opens: BTreeMap::new(),
			live_metas: BTreeMap::new(),
		}
	}
	pub fn epoch(&self) -> u64 {
		self.epoch
	}
	/// Admit a producer. `remote` is one at a socket, bounded. The endpoint's
	/// own trace is a producer too, scoped like any other.
	pub fn admit_producer(&mut self, remote: bool) -> Option<Scope> {
		if remote {
			if self.remote_producers >= MAX_REMOTE_PRODUCERS {
				return None;
			}
			self.remote_producers += 1;
		}
		let scope = format!("p{}", self.next_scope);
		self.next_scope += 1;
		self.producers.insert(scope.clone(), Producer { rows: BTreeSet::new() });
		Some(scope)
	}
	/// The endpoint-authored mark an admitted producer hears, and the only
	/// thing it will ever hear. No `seq`: it goes to one socket.
	pub fn publish_ready_line(&self, now_ns: u64) -> String {
		format!(
			"{{\"v\":1,\"sim_t_ns\":{now_ns},\"kind\":\"trace.publish-ready\",\"epoch\":{}}}",
			self.epoch
		)
	}
	pub fn replay_end_line(&self, now_ns: u64) -> String {
		format!(
			"{{\"v\":1,\"sim_t_ns\":{now_ns},\"kind\":\"trace.replay-end\",\"epoch\":{}}}",
			self.epoch
		)
	}
	/// What a viewer replays on arrival: the live topology and nothing else,
	/// ended by the mark.
	pub fn replay(&self, now_ns: u64) -> Vec<String> {
		let mut lines = records::replay_lines(
			self.live_opens
				.values()
				.map(|stamped| (stamped.seq, stamped.line.as_str())),
			self.live_metas
				.iter()
				.filter(|(id, _)| self.live_opens.contains_key(*id))
				.map(|(_, stamped)| (stamped.seq, stamped.line.as_str())),
		);
		lines.push(self.replay_end_line(now_ns));
		lines
	}
	fn stamp(&mut self, mut rec: Map<String, Value>, now_ns: u64) -> Option<Stamped> {
		self.seq += 1;
		rec.insert("sim_t_ns".into(), Value::from(now_ns));
		rec.insert("seq".into(), Value::from(self.seq));
		rec.insert("epoch".into(), Value::from(self.epoch));
		let line = Value::Object(rec).to_string();
		if line.len() > MAX_LINE_BYTES {
			return None;
		}
		Some(Stamped { seq: self.seq, line })
	}
	/// One record from `scope`, already parsed. Answers what every viewer
	/// hears, restamped and scoped.
	pub fn ingest(&mut self, scope: &str, mut rec: Map<String, Value>, now_ns: u64) -> Vec<Stamped> {
		let Some(local) = rec.get("session").and_then(Value::as_str).map(String::from) else {
			return Vec::new();
		};
		let scoped = format!("{scope}/{local}");
		rec.insert("session".into(), Value::from(scoped.clone()));
		let kind = rec.get("kind").and_then(Value::as_str).unwrap_or("").to_owned();
		let Some(producer) = self.producers.get_mut(scope) else {
			return Vec::new();
		};
		let mut out = Vec::new();
		match kind.as_str() {
			records::OPENED => {
				if producer.rows.contains(&local) {
					// A reopened id retires its row quietly.
					self.live_opens.remove(&scoped);
					self.live_metas.remove(&scoped);
				} else {
					if producer.rows.len() >= MAX_ROWS_PER_PRODUCER || self.live_opens.len() >= MAX_REPLAY_ROWS {
						return out;
					}
					producer.rows.insert(local);
				}
				if let Some(stamped) = self.stamp(rec, now_ns) {
					self.live_opens.insert(scoped, stamped.clone());
					out.push(stamped);
				}
			}
			records::CLOSED => {
				if !producer.rows.remove(&local) {
					return out;
				}
				self.live_opens.remove(&scoped);
				self.live_metas.remove(&scoped);
				if let Some(stamped) = self.stamp(rec, now_ns) {
					out.push(stamped);
				}
			}
			records::META => {
				if !producer.rows.contains(&local) {
					return out;
				}
				if let Some(stamped) = self.stamp(rec, now_ns) {
					self.live_metas.insert(scoped, stamped.clone());
					out.push(stamped);
				}
			}
			_ => {
				if !producer.rows.contains(&local) {
					return out;
				}
				if let Some(stamped) = self.stamp(rec, now_ns) {
					out.push(stamped);
				}
			}
		}
		out
	}
	/// A producer left: its rows go without a close being announced, because
	/// a telemetry socket dropping is not a session closing, and every viewer
	/// hears that the scope is gone.
	pub fn drop_producer(&mut self, scope: &str, remote: bool, now_ns: u64) -> Vec<Stamped> {
		let Some(producer) = self.producers.remove(scope) else {
			return Vec::new();
		};
		if remote {
			self.remote_producers = self.remote_producers.saturating_sub(1);
		}
		for local in producer.rows {
			let scoped = format!("{scope}/{local}");
			self.live_opens.remove(&scoped);
			self.live_metas.remove(&scoped);
		}
		let mut left = Map::new();
		left.insert("v".into(), Value::from(1));
		left.insert("sim_t_ns".into(), Value::from(0));
		left.insert("kind".into(), Value::from("trace.producer-left"));
		left.insert("scope".into(), Value::from(scope));
		self.stamp(left, now_ns).into_iter().collect()
	}
}

/// One subscriber's bounded queue, counted here so a slow viewer is closed
/// rather than growing the endpoint.
#[derive(Default)]
pub struct SubscriberQueue {
	pub count: usize,
	pub bytes: usize,
}

impl SubscriberQueue {
	/// Admit one more queued line, or say the subscriber must go.
	pub fn admit(&mut self, bytes: usize) -> bool {
		if bytes > MAX_LINE_BYTES
			|| self.count >= MAX_SUBSCRIBER_QUEUE
			|| self.bytes + bytes > MAX_SUBSCRIBER_QUEUE_BYTES
		{
			return false;
		}
		self.count += 1;
		self.bytes += bytes;
		true
	}
	pub fn drained(&mut self, bytes: usize) {
		self.count = self.count.saturating_sub(1);
		self.bytes = self.bytes.saturating_sub(bytes);
	}
}

#[cfg(test)]
mod tests;
