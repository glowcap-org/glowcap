//! The bot's typed failures. A refused lease, an unusable configuration, or
//! unreadable state stops `serve` before it starts. Once it serves, a failure
//! that clears with time, a write included, is tried again with backoff where
//! it is caught, and the process stays up. The settings and link the session's
//! first answer stores are such a write.
use super::{
	rooms::{RoomsError, RoomsErrorKind},
	words::{ASK_REFUSED, LINK_NOT_ACCEPTED, OLD_UNLISTED, REPLACEMENT_NOT_ACCEPTED, START_AGAIN},
};
use nix::errno::Errno;
use rooms_application::documents::WriteFailure;
use rooms_platform::storage::StorageError;
use std::{fmt, io, path::PathBuf};

/// The way on from state that cannot be read or restored: the one remedy
/// every refusal to start over names.
pub const START_FRESH: &str = "stop the bot, move everything in the bot directory except `home` aside, and run \
	`glowcap apps rooms bot serve --dir <bot directory> --harness <name> --link -` with a new link piped in and \
	every setting you want passed again, which drops the stored settings, the link, and the bot's place in the \
	session, so it answers only lines sent after it starts. Under Compose follow the deploy README's bot section";

/// The flags that make an access for a bot. The CLI help and the guide say
/// them too, and a test holds the three together.
const ISSUE_RIGHTS: &str = "--label bot --rights collaborator";

/// The command that gives the bot a new access and serves it, as written for a
/// host install. Under Compose the deploy README's bot section has the form.
fn serve_with_new_access(flags: &str) -> String {
	format!(
		"Run `glowcap apps rooms session access issue --dir <session directory> {ISSUE_RIGHTS} \
		 | glowcap apps rooms bot serve --dir <bot directory> --link -{flags}`, or under Compose follow the deploy \
		 README's bot section"
	)
}

/// Which link a serve holds, as a refusal words it. A first link is stored
/// once the session has answered a read. A replacement leaves the stored link
/// unchanged until then. The stored link is already saved.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LinkStage {
	First,
	Replacing,
	Stored,
}

#[derive(Debug)]
pub enum Error {
	/// A command line or request the bot cannot act on.
	Usage(String),
	/// The stored or supplied configuration is unusable.
	Config(String),
	/// The session turned the bot's link or access down.
	Access {
		stage: LinkStage,
		cause: String,
	},
	/// The session refused to say whose receipt an operation is, for good.
	Asked(String),
	/// The old access could not list the receipts it holds, so a replacement
	/// would leave its agent's actions unrecorded, and nothing of the
	/// replacement is stored.
	Unlisted(RoomsError),
	/// Another `serve` holds the bot directory.
	Lease(PathBuf),
	/// A state file is damaged or cannot be written.
	Storage(StorageError),
	/// A state file's replacement failed after it may have landed, so the
	/// file holds the old document or the new one.
	Unsettled(StorageError),
	/// The bot's state broke one of its own rules.
	State {
		file: String,
		reason: String,
	},
	/// A stored document does not decode, as one another build of the bot
	/// wrote may not.
	Unreadable {
		file: String,
		reason: String,
	},
	Io {
		context: &'static str,
		source: io::Error,
	},
	Rooms(RoomsError),
	/// An action verb's failure, already in the shape its caller reads: the
	/// JSON line it prints, and the sentence a person sees.
	Action {
		response: serde_json::Value,
		message: String,
	},
	/// `ready` found the bot not serving or not attached to a session that
	/// answers.
	NotReady(String),
	/// The system gave no randomness for an operation id.
	Entropy(String),
	/// A state document would pass the size the bot reads back.
	TooLarge {
		file: String,
		bytes: usize,
		limit: usize,
	},
}

impl fmt::Display for Error {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Self::Usage(reason) | Self::Config(reason) | Self::NotReady(reason) => reason.fmt(f),
			Self::Access { stage, cause } => match stage {
				LinkStage::First => write!(
					f,
					"{LINK_NOT_ACCEPTED}: {cause}. {}",
					serve_with_new_access(" --harness <name>")
				),
				LinkStage::Replacing => write!(
					f,
					"{REPLACEMENT_NOT_ACCEPTED}: {cause}. The stored link is unchanged. {}",
					serve_with_new_access(" --replace-link")
				),
				LinkStage::Stored => write!(
					f,
					"the bot can no longer serve: {cause}. {}",
					serve_with_new_access(" --replace-link")
				),
			},
			Self::Asked(cause) => write!(
				f,
				"{ASK_REFUSED}. It answered: {cause}. Asking again \
				 will not change that, so run the bot and the session from the same release, {START_AGAIN}"
			),
			Self::Unlisted(cause) => write!(
				f,
				"{OLD_UNLISTED}: {cause}. The stored link is unchanged. \
				 Run the same replacement again, or revoke the old access first, which frees the places its \
				 agent's actions hold"
			),
			Self::Lease(path) => write!(
				f,
				"another rooms-bot serve already holds {}. Stop it before starting a second one",
				path.display()
			),
			Self::Storage(error) => error.fmt(f),
			Self::Unsettled(error) => write!(f, "{error}. The file may hold the change, so it is written again"),
			Self::State { file, reason } => write!(
				f,
				"{file} is unreadable: {reason}. Preserve it and inspect before restart"
			),
			Self::Unreadable { file, reason } => write!(
				f,
				"{file} in the bot directory is unreadable: {reason}. To start fresh, {START_FRESH}"
			),
			Self::Io { context, source } => write!(f, "{context}: {source}"),
			Self::Rooms(error) => error.fmt(f),
			Self::Action { message, .. } => message.fmt(f),
			Self::Entropy(reason) => write!(f, "no randomness for an operation id: {reason}"),
			Self::TooLarge { file, bytes, limit } => {
				write!(f, "{file} would be {bytes} bytes, past its {limit}-byte bound")
			}
		}
	}
}

impl std::error::Error for Error {}

impl Error {
	pub fn io(context: &'static str) -> impl FnOnce(io::Error) -> Self {
		move |source| Self::Io { context, source }
	}
	/// The session turned the access down, and what the operator does next
	/// depends on the stage of the link it turned down.
	pub fn access_ended(stage: LinkStage, cause: String) -> Self {
		Self::Access { stage, cause }
	}
	/// Whether waiting and doing the same work again can succeed. Only the
	/// system failures in [`CLEARING`] can clear on their own. A document the
	/// bot cannot read, one that has outgrown its bound, a path that is not a
	/// regular file, and a refused permission stay that way until a person acts.
	pub fn is_transient(&self) -> bool {
		match self {
			Self::Storage(error) | Self::Unsettled(error) => storage_clears(error),
			Self::Io { source, .. } => clears(source),
			Self::Entropy(_) => true,
			Self::Unlisted(cause) => cause.kind == RoomsErrorKind::Unreachable,
			Self::Usage(_)
			| Self::Config(_)
			| Self::NotReady(_)
			| Self::Access { .. }
			| Self::Asked(_)
			| Self::Lease(_)
			| Self::State { .. }
			| Self::Unreadable { .. }
			| Self::Rooms(_)
			| Self::Action { .. }
			| Self::TooLarge { .. } => false,
		}
	}
	pub fn unreadable(file: &str, reason: impl ToString) -> Self {
		Self::Unreadable {
			file: file.into(),
			reason: reason.to_string(),
		}
	}

	pub fn state(file: &str, reason: impl ToString) -> Self {
		Self::State {
			file: file.into(),
			reason: reason.to_string(),
		}
	}
}

/// The system failures that clear with time: a full disk or quota, an
/// interrupted or busy call, a device error, and running out of memory or
/// open files. Every other failure needs a person to change something.
const CLEARING: [Errno; 9] = [
	Errno::ENOSPC,
	Errno::EDQUOT,
	Errno::EIO,
	Errno::EINTR,
	Errno::EAGAIN,
	Errno::ENOMEM,
	Errno::EMFILE,
	Errno::ENFILE,
	Errno::EBUSY,
];

fn clears(error: &io::Error) -> bool {
	error
		.raw_os_error()
		.is_some_and(|code| CLEARING.contains(&Errno::from_raw(code)))
}

fn storage_clears(error: &StorageError) -> bool {
	match error {
		StorageError::Io(source) => clears(source),
		StorageError::Cleanup { primary, .. } => storage_clears(primary),
		// The storage worker is busy or restarting.
		StorageError::Pending | StorageError::Worker(_) => true,
		// A lease another holder keeps for one small write, as a note's count.
		StorageError::InUse(_) => true,
		StorageError::Document(_) => false,
	}
}

impl From<StorageError> for Error {
	fn from(error: StorageError) -> Self {
		Self::Storage(error)
	}
}

/// A replacement that may have landed stays distinct, so the ledger can
/// write the same document again rather than a different one.
impl From<WriteFailure<StorageError>> for Error {
	fn from(failure: WriteFailure<StorageError>) -> Self {
		match failure {
			WriteFailure::Unchanged(error) => Self::Storage(error),
			WriteFailure::Indeterminate(error) => Self::Unsettled(error),
		}
	}
}

impl From<RoomsError> for Error {
	fn from(error: RoomsError) -> Self {
		Self::Rooms(error)
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use rooms_application::documents::DocumentError;

	#[test]
	fn the_issue_flags_read_the_same_in_the_help_and_the_guide() {
		let help = include_str!("../../../../../../../cli/app/rooms/bot_commands.zig");
		let guide = include_str!("../../../../../../../docs/rooms/bot.md");
		for (name, text) in [("the CLI help", help), ("the guide", guide)] {
			assert!(text.contains(ISSUE_RIGHTS), "{name} does not say `{ISSUE_RIGHTS}`");
		}
	}

	#[test]
	fn the_three_refusals_share_one_issue_command_and_a_first_start_names_its_harness() {
		let text = |stage| Error::access_ended(stage, "refused".into()).to_string();
		let issue = format!("glowcap apps rooms session access issue --dir <session directory> {ISSUE_RIGHTS} | ");
		let first = text(LinkStage::First);
		for said in [&first, &text(LinkStage::Replacing), &text(LinkStage::Stored)] {
			assert!(said.contains(&issue), "{said}");
		}
		assert!(first.contains("--harness <name>"), "{first}");
		assert!(!text(LinkStage::Replacing).contains("--harness"));
		assert!(text(LinkStage::Replacing).contains("The stored link is unchanged"));
		assert!(
			text(LinkStage::Stored).contains("--replace-link") && text(LinkStage::Replacing).contains("--replace-link")
		);
		assert!(
			!first.contains("--replace-link"),
			"a first link has none stored to replace"
		);
	}

	#[test]
	fn only_storage_failures_that_can_clear_are_transient() {
		let full = Error::Storage(StorageError::Io(io::Error::from_raw_os_error(28)));
		assert!(full.is_transient());
		let not_a_file = Error::Storage(StorageError::Io(io::Error::other("not a regular file")));
		assert!(!not_a_file.is_transient());
		let denied = Error::Storage(StorageError::Io(io::Error::from_raw_os_error(Errno::EACCES as i32)));
		assert!(!denied.is_transient(), "a refused permission waits for a person");
		let read_only = Error::Io {
			context: "writing",
			source: io::Error::from_raw_os_error(Errno::EROFS as i32),
		};
		assert!(!read_only.is_transient());
		for errno in CLEARING {
			let error = Error::Unsettled(StorageError::Io(io::Error::from_raw_os_error(errno as i32)));
			assert!(error.is_transient(), "{errno}");
		}
		assert!(!Error::Storage(StorageError::Document(DocumentError::TooLarge)).is_transient());
		assert!(!Error::state("turns.json", "damaged").is_transient());
	}
}
