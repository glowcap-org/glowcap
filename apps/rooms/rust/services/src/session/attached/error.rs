//! What an attached view reports. Access verdicts, an unreachable peer, and an
//! unknown write outcome are separate variants because each asks the caller
//! for a different next step.
use rooms_glowcap::client::Error as Client;
use std::{fmt, path::PathBuf};

#[derive(Debug)]
pub enum Error {
	/// The peer does not admit this use: the link is unknown, expired, or its
	/// access is out of scope. A new link or new access is the only remedy.
	Refused,
	/// The issuer revoked this access. It never recovers.
	Revoked,
	/// The issuer paused this access. It resumes when the issuer resumes it.
	Paused,
	/// No live connection to the peer proved an answer. The caller decides
	/// whether and when to attach again.
	Unreachable(Client),
	/// A write whose outcome is unknown. Observe the same operation at `base`
	/// with the same arguments. Sending it again under a new operation may
	/// duplicate it.
	Uncertain { base: u64, cause: Client },
	/// The peer answered and refused or failed the request.
	Peer(Client),
	/// The session was restarted since this cursor was issued. A cursor
	/// cannot be resumed across a restart. Read from the empty cursor to
	/// follow the session's new activity, knowing that whatever came after the
	/// old cursor and before the restart is gone.
	Stale,
	/// The access changed between reading it and changing it. Read it again
	/// and decide whether the change still applies.
	Conflict,
	/// A line posted under `operation` at `base`, but the session did not take
	/// its authority, so it cannot be edited or withdrawn. The line stands.
	/// Saying it again posts a second one. The cause names why the authority
	/// was not kept. `released` says the command's receipt was given back, and
	/// when it is false the receipt still holds one of the session's places.
	Unkept {
		operation: String,
		base: u64,
		cause: Box<Error>,
		released: bool,
	},
	/// `startDirect` committed under `operation` at `base`, so the peer was
	/// introduced, but the session did not take the route it returned, so no
	/// conversation reaches the peer. The cause names why. `released` says the
	/// command's receipt was given back. Opening again introduces again.
	Unopened {
		operation: String,
		base: u64,
		cause: Box<Error>,
		released: bool,
	},
	/// The request was refused locally before any effect.
	Input(String),
	/// The session answered in a shape this client does not read: activity
	/// that did not decode, or an access description it does not know.
	Malformed(&'static str),
	/// The receiving budget cannot hold this file now.
	Budget,
	/// The destination exists. A fetch never overwrites.
	Exists(PathBuf),
	/// Local file work failed.
	Io(std::io::Error),
}
impl fmt::Display for Error {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Self::Refused => f.write_str("the session refused this access"),
			Self::Revoked => f.write_str("this access was revoked"),
			Self::Paused => f.write_str("this access is paused"),
			Self::Unreachable(cause) => write!(f, "the session is unreachable: {cause}"),
			Self::Uncertain { base, cause } => {
				write!(f, "the outcome is unknown, observe it at base {base}: {cause}")
			}
			Self::Peer(cause) => write!(f, "the session refused the request: {cause}"),
			Self::Stale => f.write_str("the session restarted, so this cursor cannot be resumed"),
			Self::Conflict => f.write_str("the access changed, read it again"),
			Self::Unkept {
				cause, released: true, ..
			} => {
				write!(f, "the line posted but its authority was not kept: {cause}")
			}
			Self::Unkept {
				cause, released: false, ..
			} => write!(
				f,
				"the line posted but its authority was not kept, and its receipt is still held: {cause}"
			),
			Self::Unopened {
				cause, released: true, ..
			} => write!(f, "the peer was introduced but no conversation took its route: {cause}"),
			Self::Unopened {
				cause, released: false, ..
			} => write!(
				f,
				"the peer was introduced but no conversation took its route, and its receipt is still held: {cause}"
			),
			Self::Input(reason) => write!(f, "invalid request: {reason}"),
			Self::Malformed(reason) => write!(f, "the session's answer did not decode: {reason}"),
			Self::Budget => f.write_str("the receiving budget cannot hold this file"),
			Self::Exists(path) => write!(f, "{} already exists", path.display()),
			Self::Io(cause) => write!(f, "file error: {cause}"),
		}
	}
}
impl std::error::Error for Error {}
impl From<std::io::Error> for Error {
	fn from(cause: std::io::Error) -> Self {
		Self::Io(cause)
	}
}
