//! Application failures whose last deterministic recipient is gone.
use super::error::Error;
#[derive(Debug)]
pub enum Notice {
	ArchiveReport(crate::session_archive::Report),
	AnswerUndeliverable { verb: &'static str, cause: Error },
	GrantReplyFailed(glowcap::Error),
	ViewRetired { cause: Error },
}
pub type Report = std::rc::Rc<dyn Fn(Notice)>;
