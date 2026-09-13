//! Application failures whose last deterministic recipient is gone.
use super::error::Error;
#[derive(Debug)]
pub enum Notice {
	ArchiveReport(crate::archive::session::Report),
	AnswerUndeliverable {
		verb: &'static str,
		cause: Error,
	},
	GrantReplyFailed(glowcap::Error),
	ViewRetired {
		cause: Error,
	},
	/// A retired direct route could not prove graceful transport cleanup. The
	/// route is already unusable; this must not retire unrelated conversations.
	DirectCleanupFailed {
		cause: Error,
	},
}
pub type Report = std::rc::Rc<dyn Fn(Notice)>;
