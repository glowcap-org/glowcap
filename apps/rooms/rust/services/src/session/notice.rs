//! What the peer tells its operator about failures that have no caller left to
//! answer. The library records them; the binary decides where they go.
use super::error::Error;
use rooms_platform::serving::PartnerNotice;
use std::{fmt, rc::Rc};

/// A failure whose last deterministic recipient is gone: a partner that went
/// away, a reply that could not be delivered, a view that had to be dropped.
/// None of these is the peer's own failure, so none ends the process.
#[derive(Debug)]
pub enum Notice {
	/// What the serving loop says about partners and accepts.
	Partner(PartnerNotice),
	/// A deferred CapTP answer was ready but its promise could not be settled.
	AnswerUndeliverable { verb: &'static str, cause: Error },
	/// A grant command's reply could not be delivered.
	GrantReplyFailed(glowcap::Error),
	/// An attached view stopped receiving because a delivery to it failed.
	ViewRetired { cause: Error },
	/// A retired direct route could not prove graceful transport cleanup.
	/// Other routes remain live; the operator still receives the failure.
	DirectCleanupFailed { cause: Error },
	/// The archive worker's account of what it could not finish: share
	/// publications it could not restore at startup, deferred answers whose
	/// callers were gone, cleanups that failed.
	ArchiveReport(crate::session_archive::Report),
}

impl fmt::Display for Notice {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Self::Partner(notice) => notice.fmt(f),
			Self::AnswerUndeliverable { verb, cause } => write!(f, "deferred {verb} reply failed: {cause}"),
			Self::GrantReplyFailed(cause) => write!(f, "grant reply failed: {cause}"),
			Self::ViewRetired { cause } => write!(f, "an attached view was dropped: {cause}"),
			Self::DirectCleanupFailed { cause } => write!(f, "direct route cleanup failed: {cause}"),
			Self::ArchiveReport(report) => {
				write!(
					f,
					"the archive worker finished with {} refused, {} lost replies, {} cleanup failures",
					report.refused, report.lost_replies, report.cleanup_failures
				)?;
				if let Some(cause) = &report.restore_failure {
					write!(f, "; archive share publications were not restored: {cause}")?;
				}
				Ok(())
			}
		}
	}
}

/// Where notices go. The binary installs one that writes to stderr; a test
/// installs one that collects, so a silent drop is a failing assertion rather
/// than a line nobody reads.
pub type Report = Rc<dyn Fn(Notice)>;

impl From<rooms_runtime::service::notice::Notice> for Notice {
	fn from(notice: rooms_runtime::service::notice::Notice) -> Self {
		use rooms_runtime::service::notice::Notice as Shared;
		match notice {
			Shared::ArchiveReport(report) => Self::ArchiveReport(report),
			Shared::AnswerUndeliverable { verb, cause } => Self::AnswerUndeliverable {
				verb,
				cause: cause.into(),
			},
			Shared::GrantReplyFailed(error) => Self::GrantReplyFailed(error),
			Shared::ViewRetired { cause } => Self::ViewRetired { cause: cause.into() },
			Shared::DirectCleanupFailed { cause } => Self::DirectCleanupFailed { cause: cause.into() },
		}
	}
}
