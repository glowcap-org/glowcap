//! View construction keeps access/state failures typed until the outer adapter.
use crate::session_state::ViewError;
use rooms_application::session::state;
#[derive(Debug)]
pub enum Error {
	View(ViewError),
	State(state::Error),
	Invalid(String),
}
impl From<ViewError> for Error {
	fn from(error: ViewError) -> Self {
		Self::View(error)
	}
}
impl From<state::Error> for Error {
	fn from(error: state::Error) -> Self {
		Self::State(error)
	}
}
impl std::fmt::Display for Error {
	fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
		match self {
			Self::View(e) => e.fmt(f),
			Self::State(e) => e.fmt(f),
			Self::Invalid(e) => f.write_str(e),
		}
	}
}
impl std::error::Error for Error {}
