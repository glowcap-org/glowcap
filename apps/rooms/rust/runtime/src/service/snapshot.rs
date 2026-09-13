//! Shared service error adaptation for the shared session projection.
use super::error::Error;
pub use crate::session::projection::handed;
use rooms_application::session::snapshot::Field;

pub fn attachment_issue(subject: &str, reason: &str) -> Result<(Field, Field), Error> {
	crate::session::projection::attachment_issue(subject, reason).map_err(Into::into)
}
impl From<crate::session::projection::Error> for Error {
	fn from(error: crate::session::projection::Error) -> Self {
		match error {
			crate::session::projection::Error::View(error) => error.into(),
			crate::session::projection::Error::State(error) => error.into(),
			crate::session::projection::Error::Invalid(reason) => Self::invalid(reason),
		}
	}
}
