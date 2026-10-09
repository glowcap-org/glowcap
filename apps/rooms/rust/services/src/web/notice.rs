//! Operator-facing events emitted by the web front.
use std::{fmt, rc::Rc};

#[derive(Debug)]
pub enum Notice {
	CompilingAssets,
	AssetRefreshFailed(String),
	AssetUnavailable(String),
	IceUnavailable(String),
	HttpAcceptRefused(String),
	HttpConnectionEnded(String),
	RelayEnded { cause: String, times: u32 },
	ShutdownConnectionEnded(String),
	AttachedDirectory(String),
	DirectoryExited(String),
	AttachedDirectoryEnded,
	DirectoryRestartFailed { cause: String, delay_ms: u128 },
	ChildOutputEnded { label: &'static str, cause: String },
	ChildOutputTaskFailed { label: &'static str, cause: String },
	ChildShutdownRequestFailed(String),
}

impl fmt::Display for Notice {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Self::CompilingAssets => f.write_str("compiling browser assets"),
			Self::AssetRefreshFailed(cause) => write!(f, "refreshing assets failed: {cause}"),
			Self::AssetUnavailable(cause) => write!(f, "asset unavailable: {cause}"),
			Self::IceUnavailable(cause) => write!(f, "{cause}"),
			Self::HttpAcceptRefused(cause) => write!(f, "HTTP accept refused, retrying: {cause}"),
			Self::HttpConnectionEnded(cause) => write!(f, "HTTP connection ended: {cause}"),
			Self::RelayEnded { cause, times: 1 } => write!(f, "relay ended: {cause}"),
			Self::RelayEnded { cause, times } => write!(f, "relay ended: {cause} ({times} times in a row)"),
			Self::ShutdownConnectionEnded(cause) => write!(f, "connection ended during shutdown: {cause}"),
			Self::AttachedDirectory(locator) => write!(f, "attaching to the existing directory at {locator}"),
			Self::DirectoryExited(status) => write!(f, "Rooms server exited ({status}); restarting"),
			Self::AttachedDirectoryEnded => f.write_str("attached directory is gone; taking ownership"),
			Self::DirectoryRestartFailed { cause, delay_ms } => {
				write!(f, "directory restart failed: {cause}; retrying in {delay_ms} ms")
			}
			Self::ChildOutputEnded { label, cause } => write!(f, "reading {label} output ended early: {cause}"),
			Self::ChildOutputTaskFailed { label, cause } => write!(f, "the {label} output reader failed: {cause}"),
			Self::ChildShutdownRequestFailed(cause) => write!(f, "requesting child shutdown failed: {cause}"),
		}
	}
}

pub type Report = Rc<dyn Fn(Notice)>;

/// Collapses a failure that repeats with the same cause, such as a browser
/// retrying a peer that is gone. The first occurrence is reported, then the
/// count each time it doubles, so a persistent failure stays visible in a
/// logarithmic number of lines.
#[derive(Default)]
pub(super) struct Repeats {
	last: Option<String>,
	times: u32,
}
impl Repeats {
	/// The number of times `cause` has now repeated, when that count is worth
	/// reporting.
	pub(super) fn observe(&mut self, cause: &str) -> Option<u32> {
		if self.last.as_deref() == Some(cause) {
			self.times = self.times.saturating_add(1);
		} else {
			self.last = Some(cause.to_owned());
			self.times = 1;
		}
		self.times.is_power_of_two().then_some(self.times)
	}
}

#[cfg(test)]
mod tests {
	use super::Repeats;

	#[test]
	fn a_repeated_cause_is_reported_when_its_count_doubles() {
		let mut repeats = Repeats::default();
		let reported: Vec<_> = (0..9).map(|_| repeats.observe("peer.iroh: timed out")).collect();
		assert_eq!(
			reported,
			[Some(1), Some(2), None, Some(4), None, None, None, Some(8), None]
		);
		assert_eq!(repeats.observe("other.iroh: timed out"), Some(1));
	}
}
