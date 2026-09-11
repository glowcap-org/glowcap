//! Startup failures retain adapter causes beside any failed cleanup.
use super::error::Error;
#[derive(Debug)]
pub enum OpenError<E> {
	Session(Error),
	Grants(Box<crate::grant_publications::Error<E>>),
	Cleanup { primary: Box<Self>, cleanup: Error },
}
impl<E> OpenError<E> {
	pub(super) fn retain_result(self, result: Result<(), Error>) -> Self {
		match result {
			Ok(()) => self,
			Err(cleanup) => Self::Cleanup {
				primary: Box::new(self),
				cleanup,
			},
		}
	}
}
impl<E> From<Error> for OpenError<E> {
	fn from(error: Error) -> Self {
		Self::Session(error)
	}
}
impl<E: std::error::Error> std::fmt::Display for OpenError<E> {
	fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
		match self {
			Self::Session(e) => e.fmt(f),
			Self::Grants(e) => e.fmt(f),
			Self::Cleanup { primary, cleanup } => write!(f, "{primary}; cleanup also failed: {cleanup}"),
		}
	}
}
impl<E: std::error::Error + 'static> std::error::Error for OpenError<E> {
	fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
		Some(match self {
			Self::Session(e) => e,
			Self::Grants(e) => e.as_ref(),
			Self::Cleanup { primary, .. } => primary.as_ref(),
		})
	}
}
