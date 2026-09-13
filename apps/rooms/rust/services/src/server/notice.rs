//! What the server tells its operator about failures that have no caller
//! left to answer. The library records them; the binary decides where they go.
use rooms_platform::serving::PartnerNotice;
use std::{fmt, rc::Rc};

/// A failure whose last deterministic recipient is gone. None of these is the
/// server's own failure, so none ends the process.
#[derive(Debug)]
pub enum Notice {
	/// What the serving loop says about partners and accepts.
	Partner(PartnerNotice),
	/// A notification to a member still connected could not be queued.
	Undelivered { verb: &'static str, cause: glowcap::Error },
	/// A capability could not be given back to a session still open.
	ReleaseFailed(glowcap::Error),
	/// A relayed delivery the server awaited was refused by its recipient.
	DeliveryFailed { what: &'static str, cause: glowcap::Error },
	/// A deferred answer was ready but its promise could not be settled.
	AnswerUndeliverable { verb: &'static str, cause: glowcap::Error },
	/// A durable name could not be taken down after its authority ended.
	/// The behavior behind it refuses on its own, so nothing answers through it.
	UnpublishFailed { swiss: String, cause: glowcap::Error },
	/// The announced listener could not be re-selected as the Host's
	/// location after a runtime listener took the selection.
	ListenerSelectFailed(glowcap::Error),
	/// A failure named at its site, for the journal and the operator.
	Trouble { source: String, reason: String },
}

impl Notice {
	/// Where the failure came from, as the journal files it.
	pub fn source(&self) -> &str {
		match self {
			Self::Partner(PartnerNotice::Ended(_)) => "a member session failed",
			Self::Partner(PartnerNotice::TaskFailed(_)) => "a member session task failed",
			Self::Partner(PartnerNotice::AcceptRefused(_)) => "accepting a connection failed",
			Self::Undelivered { .. } => "a notification could not be delivered",
			Self::ReleaseFailed(_) => "could not release a capability",
			Self::DeliveryFailed { what, .. } => what,
			Self::AnswerUndeliverable { verb, .. } => verb,
			Self::UnpublishFailed { .. } => "could not take down a durable name",
			Self::ListenerSelectFailed(_) => "could not re-select the announced listener",
			Self::Trouble { source, .. } => source,
		}
	}
	/// What went wrong, as the journal files it.
	pub fn reason(&self) -> String {
		match self {
			Self::Partner(PartnerNotice::Ended(ended)) => ended.to_string(),
			Self::Partner(PartnerNotice::TaskFailed(cause)) => cause.to_string(),
			Self::Partner(PartnerNotice::AcceptRefused(cause)) => cause.to_string(),
			Self::Undelivered { cause, .. }
			| Self::ReleaseFailed(cause)
			| Self::DeliveryFailed { cause, .. }
			| Self::AnswerUndeliverable { cause, .. }
			| Self::UnpublishFailed { cause, .. }
			| Self::ListenerSelectFailed(cause) => cause.to_string(),
			Self::Trouble { reason, .. } => reason.clone(),
		}
	}
}

impl fmt::Display for Notice {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Self::Partner(notice) => notice.fmt(f),
			Self::Undelivered { verb, cause } => write!(f, "a {verb} notification failed: {cause}"),
			Self::ReleaseFailed(cause) => write!(f, "giving a capability back failed: {cause}"),
			Self::DeliveryFailed { what, cause } => write!(f, "{what} delivery failed: {cause}"),
			Self::AnswerUndeliverable { verb, cause } => write!(f, "deferred {verb} reply failed: {cause}"),
			Self::UnpublishFailed { swiss, cause } => {
				write!(f, "a retired durable name {swiss} could not be taken down: {cause}")
			}
			Self::ListenerSelectFailed(cause) => {
				write!(f, "the announced listener could not be re-selected: {cause}")
			}
			Self::Trouble { source, reason } => write!(f, "{source}: {reason}"),
		}
	}
}

/// Where notices go. The binary installs one that writes to stderr; a test
/// installs one that collects, so a silent drop is a failing assertion rather
/// than a line nobody reads.
pub type Report = Rc<dyn Fn(Notice)>;
