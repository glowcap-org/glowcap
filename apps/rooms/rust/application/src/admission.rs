//! Process-local work admission above CapTP. Embeddings supply monotonic time
//! and authenticated, fixed-size keys. No socket, clock or retry lives here.
mod bucket;
mod registry;
mod settings;
#[cfg(test)]
mod tests;
use crate::failure::FailureCode;
use alloc::string::String;
use bucket::Bucket;
pub use bucket::Rate;
pub use registry::{Charge, Policy, Registry, Statistics};
pub use settings::{Settings, Source};

/// Fixed reserve for authorized cleanup when the subject table is full. It
/// owns one bucket, allocates nothing, and never replaces existing subject debt.
pub struct CleanupReserve {
	bucket: Bucket,
	rate: Rate,
}
impl CleanupReserve {
	pub fn new(rate: Rate) -> Self {
		Self {
			bucket: Bucket::default(),
			rate,
		}
	}
	fn admit(&mut self, amount: u32, now: u64) -> Result<(), Refusal> {
		self.bucket.check(self.rate, amount, now, Class::Cleanup)?;
		self.bucket.debit(self.rate, amount, now);
		Ok(())
	}
}

/// Different work keeps independent allowance. Bytes spend a separate bucket
/// from message count. Cleanup spends independent reserved allowance.
#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "kebab-case")]
#[repr(usize)]
pub enum Class {
	Connection,
	Join,
	RoomJoin,
	Message,
	MessageBytes,
	Transient,
	RoomTransient,
	Introduction,
	Recipient,
	Create,
	Read,
	Upload,
	Signal,
	Ingress,
	HttpStart,
	Transfer,
	Preview,
	Registration,
	Rendezvous,
	Cleanup,
}
pub const CLASS_COUNT: usize = 20;
/// Bound untrusted retry metadata before a consumer schedules a wait.
pub const MAX_RETRY_DELAY_MS: u64 = 60_000;
/// Diagnostic attribution identifies the refusing boundary, never authority.
#[derive(Clone, Copy)]
pub enum Owner {
	Directory,
	Session,
	DirectInbox,
	Http,
}
pub const OWNERS: [Owner; 4] = [Owner::Directory, Owner::Session, Owner::DirectInbox, Owner::Http];
impl Owner {
	pub const fn name(self) -> &'static str {
		match self {
			Self::Directory => "directory",
			Self::Session => "session",
			Self::DirectInbox => "direct-inbox",
			Self::Http => "http",
		}
	}
	pub fn parse(name: &str) -> Option<Self> {
		OWNERS.into_iter().find(|owner| owner.name() == name)
	}
}
pub const CLASSES: [Class; CLASS_COUNT] = [
	Class::Connection,
	Class::Join,
	Class::RoomJoin,
	Class::Message,
	Class::MessageBytes,
	Class::Transient,
	Class::RoomTransient,
	Class::Introduction,
	Class::Recipient,
	Class::Create,
	Class::Read,
	Class::Upload,
	Class::Signal,
	Class::Ingress,
	Class::HttpStart,
	Class::Transfer,
	Class::Preview,
	Class::Registration,
	Class::Rendezvous,
	Class::Cleanup,
];
impl Class {
	/// Units are operations except for MessageBytes. Keeping policy beside its
	/// class prevents adding a class from silently shifting positional defaults.
	pub const fn default_rate(self) -> Rate {
		match self {
			Self::Connection => Rate::new(6, 6),
			// Restore the supported workspace in one connection. Per-room debt
			// still prevents cycling a single membership for another burst.
			Self::Join => Rate::new(crate::content::session::workspace::MAX_CONVERSATIONS as u32, 512),
			Self::RoomJoin => Rate::new(4, 6),
			// A mixed room/DM burst includes edits and separately guarded held
			// capabilities. Leave room for those ordinary mediation boundaries.
			Self::Message => Rate::new(32, 120),
			Self::MessageBytes => Rate::new(64 * 1024, 128 * 1024),
			Self::Transient => Rate::new(crate::content::session::workspace::MAX_CONVERSATIONS as u32, 512),
			Self::RoomTransient => Rate::new(4, 120),
			// First contact has an initial request and a later readiness lookup.
			Self::Introduction => Rate::new(8, 12),
			Self::Recipient => Rate::new(12, 30),
			Self::Create => Rate::new(16, 30),
			Self::Read => Rate::new(4096, 8192),
			Self::Signal => Rate::new(256, 512),
			// Consecutive full eight-file posts and edits also reach separately
			// guarded attachment targets. A burst must cover ordinary mediation.
			Self::Upload => Rate::new(32, 64),
			Self::Ingress => Rate::new(8192, 16384),
			Self::HttpStart => Rate::new(32, 120),
			// Eight maximum-sized files in both directions fit one ordinary
			// burst. The existing chunk ceiling also bounds bytes per allowance.
			Self::Transfer => Rate::new(4096, 8192),
			Self::Preview => Rate::new(32, 120),
			Self::Registration => Rate::new(32, 120),
			Self::Rendezvous => Rate::new(4, 4),
			Self::Cleanup => Rate::new(512, 1024),
		}
	}
	pub fn parse(name: &str) -> Option<Self> {
		CLASSES.into_iter().find(|class| class.name() == name)
	}
	pub const fn name(self) -> &'static str {
		match self {
			Self::Connection => "connection",
			Self::Join => "join",
			Self::RoomJoin => "room-join",
			Self::Message => "message",
			Self::MessageBytes => "message-bytes",
			Self::Transient => "transient",
			Self::RoomTransient => "room-transient",
			Self::Introduction => "introduction",
			Self::Recipient => "recipient",
			Self::Create => "create",
			Self::Read => "read",
			Self::Upload => "upload",
			Self::Signal => "signal",
			Self::Ingress => "ingress",
			Self::HttpStart => "http-start",
			Self::Transfer => "transfer",
			Self::Preview => "preview",
			Self::Registration => "registration",
			Self::Rendezvous => "rendezvous",
			Self::Cleanup => "cleanup",
		}
	}
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RetryAdvice {
	pub class: Class,
	pub retry_ms: u64,
}
impl RetryAdvice {
	pub fn parse(detail: &str) -> Option<Self> {
		let detail = match detail.split_once("; owner=") {
			Some((advice, owner)) => {
				Owner::parse(owner)?;
				advice
			}
			None => detail,
		};
		let (delay, scope) = detail.strip_prefix("retry-after-ms=")?.split_once("; scope=")?;
		if delay.is_empty() || !delay.bytes().all(|byte| byte.is_ascii_digit()) {
			return None;
		}
		let retry_ms = delay.parse().ok()?;
		if !(1..=MAX_RETRY_DELAY_MS).contains(&retry_ms) {
			return None;
		}
		Some(Self {
			class: Class::parse(scope)?,
			retry_ms,
		})
	}
}

/// One typed profile. Units are operations except for MessageBytes. The scale
/// raises burst and sustained allowance together without disabling any bound.
#[derive(Clone, Copy, Debug)]
pub struct Profile {
	rates: [Rate; CLASS_COUNT],
}
impl Default for Profile {
	fn default() -> Self {
		Self {
			rates: CLASSES.map(Class::default_rate),
		}
	}
}
impl Profile {
	pub fn scaled(scale: u32) -> Option<Self> {
		if !(1..=100).contains(&scale) {
			return None;
		}
		let mut profile = Self::default();
		for rate in &mut profile.rates {
			*rate = rate.scaled(scale)?;
		}
		Some(profile)
	}
	pub const fn rate(&self, class: Class) -> Rate {
		self.rates[class as usize]
	}
	pub fn multiplied(self, scale: u32) -> Option<Self> {
		let mut profile = self;
		for rate in &mut profile.rates {
			*rate = rate.scaled(scale)?;
		}
		Some(profile)
	}
	pub fn with_rate(mut self, class: Class, rate: Rate) -> Self {
		self.rates[class as usize] = rate;
		self
	}
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refusal {
	Throttled { class: Class, retry_ms: u64 },
	Capacity,
	TooLarge { class: Class },
}
impl Refusal {
	pub fn reason_at(self, owner: Owner) -> String {
		let mut reason = self.reason();
		reason.push_str("; owner=");
		reason.push_str(owner.name());
		reason
	}
	pub fn reason(self) -> String {
		match self {
			Self::Throttled { class, retry_ms } => {
				FailureCode::RateLimited.line(format_args!("retry-after-ms={retry_ms}; scope={}", class.name()))
			}
			Self::Capacity => FailureCode::AdmissionBusy.line("admission accounting is at capacity"),
			Self::TooLarge { class } => {
				FailureCode::RequestTooLarge.line(format_args!("{} exceeds one admitted burst", class.name()))
			}
		}
	}
}
