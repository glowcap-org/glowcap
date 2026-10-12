//! What the peer tells its operator about failures that have no caller left to
//! answer. The library records them. The binary decides where they go.
use rooms_platform::serving::PartnerNotice;
use std::{fmt, rc::Rc};

/// A failure whose last deterministic recipient is gone: a partner that went
/// away, a reply that could not be delivered, a view that had to be dropped.
/// None of these is the peer's own failure, so none ends the process.
#[derive(Debug)]
pub enum Notice {
	Admission(String),
	Activity {
		operation: String,
		cause: glowcap::Error,
	},
	/// What the serving loop says about partners and accepts.
	Partner(PartnerNotice),
}

impl fmt::Display for Notice {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Self::Admission(policy) => write!(f, "session admission: {policy}"),
			Self::Activity { operation, cause } => write!(f, "session {operation}: {cause}"),
			Self::Partner(notice) => notice.fmt(f),
		}
	}
}

/// Where notices go. The binary installs one that writes to stderr. A test
/// installs one that collects, so a silent drop is a failing assertion rather
/// than a line nobody reads.
pub type Report = Rc<dyn Fn(Notice)>;
