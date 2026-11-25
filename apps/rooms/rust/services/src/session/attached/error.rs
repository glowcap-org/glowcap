//! What an attached view reports. Access verdicts, an unreachable peer, and an
//! unknown write outcome are separate variants because each asks the caller
//! for a different next step.
use super::Files;
use rooms_application::failure::Retry;
use rooms_glowcap::client::Error as Client;
use std::{fmt, path::PathBuf};

#[derive(Debug)]
pub enum Error {
	/// The link's capability is gone, whether the session never held it or
	/// retired it, or the access is out of scope. It never recovers: only a new
	/// access restores it.
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
	/// was not kept, and `receipt` what became of the command's receipt: given
	/// back for a refusal that never clears, and held for a failure that
	/// clears with time, so the line can still be kept later. `files` is how
	/// a post's files stood when its outcome was read before the keep failed,
	/// and none when nothing read it, so the caller never reports files it did
	/// read as unknown.
	Unkept {
		operation: String,
		base: u64,
		cause: Box<Error>,
		receipt: GiveBack,
		files: Option<Files>,
	},
	/// `startDirect` committed under `operation` at `base`, so the peer was
	/// introduced, but the session did not take the route it returned, so no
	/// conversation reaches the peer. The cause names why, and `receipt` what
	/// became of the command's receipt, as for `Unkept`. Opening again
	/// introduces again.
	Unopened {
		operation: String,
		base: u64,
		cause: Box<Error>,
		receipt: GiveBack,
	},
	/// A command committed under `operation` at `base`, and nothing here
	/// keeps what it returned, so its receipt was given back and the result
	/// forfeited. `receipt` says what giving it back came to. Sending it again
	/// performs it again.
	Forfeited {
		operation: String,
		base: u64,
		receipt: GiveBack,
	},
	/// `command` refused before sending, because the named command returns
	/// a capability and nothing in this view keeps it. Nothing was sent.
	Unkeepable { command: String },
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
impl Error {
	/// Whether this failure to keep what a committed command returned is a
	/// refusal that never clears: a plan the workspace refuses (a conversation
	/// that is gone, authority that changed, no room for another kept line), a
	/// receipt that does not decode, or a request nothing here keeps. The
	/// receipt of such a result is given back, because keeping it again meets
	/// the same refusal. Every other failure clears with time or says only what
	/// the access is now: a lost connection, a peer's failure that says to ask
	/// again soon, a paused,
	/// revoked or refused access, a failed snapshot, or a workspace that moved
	/// on every attempt. Its receipt is held, so the result can be kept later
	/// and its edit and withdraw authority is not lost with it. Every keeper,
	/// the verb path, the sweep, and the bot's reply-line path, asks this one
	/// answer, and the match has no wildcard, so a new variant is classified
	/// where it is added.
	pub fn refuses_keeping(&self) -> bool {
		match self {
			Self::Input(_) | Self::Malformed(_) | Self::Unkeepable { .. } | Self::Budget | Self::Exists(_) => true,
			// The session answered and refused: waiting does not change that
			// answer, unless the refusal itself says to ask again soon.
			// A workspace that moved on every attempt is the one refusal that
			// asking again later answers differently.
			Self::Peer(cause) => {
				!matches!(cause, Client::WorkspaceConflict)
					&& !cause.connection_failed()
					&& cause.retry() != Retry::Soon
			}
			Self::Refused
			| Self::Revoked
			| Self::Paused
			| Self::Unreachable(_)
			| Self::Uncertain { .. }
			| Self::Stale
			| Self::Conflict
			| Self::Unkept { .. }
			| Self::Unopened { .. }
			| Self::Forfeited { .. }
			| Self::Io(_) => false,
		}
	}
}
impl Error {
	/// This error with `read` as the files of the post it reports, when it is
	/// the failure to keep a line whose files were read first.
	pub(super) fn read_files(self, read: Option<Files>) -> Self {
		match self {
			Self::Unkept {
				operation,
				base,
				cause,
				receipt,
				..
			} => Self::Unkept {
				operation,
				base,
				cause,
				receipt,
				files: read,
			},
			other => other,
		}
	}
}
impl fmt::Display for Error {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Self::Refused => f.write_str(
				"the session holds no capability for this access, or the access is out of scope, and only a new access restores it",
			),
			Self::Revoked => f.write_str("this access was revoked"),
			Self::Paused => f.write_str("this access is paused"),
			Self::Unreachable(cause) => write!(f, "the session is unreachable: {cause}"),
			Self::Uncertain { base, cause } => {
				write!(f, "the outcome is unknown, observe it at base {base}: {cause}")
			}
			Self::Peer(cause) => write!(f, "the session refused the request: {cause}"),
			Self::Stale => f.write_str("the session restarted, so this cursor cannot be resumed"),
			Self::Conflict => f.write_str("the access changed, read it again"),
			Self::Unkept { cause, receipt, .. } => {
				write!(f, "the line posted but its authority was not kept{receipt}: {cause}")
			}
			Self::Unopened { cause, receipt, .. } => {
				write!(
					f,
					"the peer was introduced but no conversation took its route{receipt}: {cause}"
				)
			}
			Self::Forfeited { receipt, .. } => {
				write!(f, "the command committed, and nothing it returned is kept{receipt}")
			}
			Self::Unkeepable { command } => write!(
				f,
				"nothing was sent: {command} returns a capability that this view cannot keep"
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

/// What giving back the receipt of a command whose result was not kept came
/// to. Unless the session took it, the receipt still holds one of its places.
#[derive(Debug)]
pub enum GiveBack {
	Released,
	/// The receipt's executor still ran past the session's running bound.
	Running,
	/// The result could not be kept for a reason that clears with time, so the
	/// receipt is held for another try (`Error::refuses_keeping`).
	Held,
	/// The give-back failed for this cause.
	Failed(Box<Error>),
}

impl GiveBack {
	pub fn released(&self) -> bool {
		matches!(self, Self::Released)
	}
}

/// How the receipt reads after a refusal to keep, as a clause of it.
impl fmt::Display for GiveBack {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Self::Released => Ok(()),
			Self::Running => f.write_str(", and its receipt is still held because the session still runs it"),
			Self::Held => f.write_str(", and its receipt is held so keeping it can be tried again"),
			Self::Failed(cause) => write!(
				f,
				", and its receipt is still held because giving it back failed ({cause})"
			),
		}
	}
}
impl From<std::io::Error> for Error {
	fn from(cause: std::io::Error) -> Self {
		Self::Io(cause)
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	/// The two sets a failed keep splits into: refusals that never clear give
	/// the receipt back, and every failure that clears with time holds it.
	#[test]
	fn a_failed_keep_gives_its_receipt_back_only_for_a_refusal_that_never_clears() {
		let clears = Client::Timeout("the injected fault");
		for never in [
			Error::Input("conversation is gone".into()),
			Error::Malformed("the line receipt did not decode"),
			Error::Unkeepable { command: "x".into() },
			Error::Peer(Client::SourceRead("an answered refusal".into())),
		] {
			assert!(never.refuses_keeping(), "{never}");
		}
		for held in [
			Error::Unreachable(clears.clone()),
			Error::Uncertain {
				base: 1,
				cause: clears.clone(),
			},
			Error::Peer(clears.clone()),
			Error::Paused,
			Error::Revoked,
			Error::Refused,
			Error::Conflict,
		] {
			assert!(!held.refuses_keeping(), "{held}");
		}
	}
}
