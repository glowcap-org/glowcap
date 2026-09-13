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
	RelayEnded(String),
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
			Self::RelayEnded(cause) => write!(f, "relay ended: {cause}"),
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
