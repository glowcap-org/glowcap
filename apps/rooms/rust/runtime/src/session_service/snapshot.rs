//! Shared service error adaptation for the shared session projection.
use super::error::Error;
pub use crate::session_projection::handed;
use crate::{directory_runtime::Directories, rooms::RoomRuntime, session_state::SessionView};
use rooms_application::{
	grants::{protocol::GrantView, Access},
	session::snapshot::{
		views::{ArchiveShare, HandedRoom},
		Field,
	},
	text::DocumentText,
};
#[allow(clippy::too_many_arguments)]
pub fn encode<P: crate::platform::Platform>(
	view: &SessionView,
	member_locator: &str,
	directories: &Directories<P>,
	rooms: &RoomRuntime<P>,
	grants: &[GrantView],
	handed: &[HandedRoom],
	shares: &[ArchiveShare],
	access: Access,
	note: &DocumentText,
	extra_issues: &[(Field, Field)],
) -> Result<Vec<glowcap::Argument>, Error> {
	crate::session_projection::encode(
		view,
		member_locator,
		directories,
		rooms,
		grants,
		handed,
		shares,
		access,
		note,
		extra_issues,
	)
	.map_err(Into::into)
}

pub fn attachment_issue(subject: &str, reason: &str) -> Result<(Field, Field), Error> {
	crate::session_projection::attachment_issue(subject, reason).map_err(Into::into)
}
impl From<crate::session_projection::Error> for Error {
	fn from(error: crate::session_projection::Error) -> Self {
		match error {
			crate::session_projection::Error::View(error) => error.into(),
			crate::session_projection::Error::State(error) => error.into(),
			crate::session_projection::Error::Invalid(reason) => Self::runtime(reason),
		}
	}
}
