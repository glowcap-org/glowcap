//! Reaching a room the checkpoint intends: by its durable link, by its
//! publication id, or by name. A room reached by name is entered when it
//! exists and otherwise opened, managed when the directory publishes room
//! managers so the session keeps the authority it just created.
use super::{EntropySource, Platform};
use crate::Error;
use rooms_application::room::{authority::Refusal, stewardship::Kind};
use rooms_application::session::checkpoint::commands::CommandRoutes;
use rooms_glowcap::client::{Error as ClientError, directory::Directory};

/// A missing exact publication is a checkpoint observation, not a dial retry.
pub enum Failure {
	Unavailable(Error),
	Retired { kind: Kind, token: String },
}
impl core::fmt::Display for Failure {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		match self {
			Self::Unavailable(reason) => reason.fmt(f),
			Self::Retired { kind, .. } => write!(f, "the saved {:?} authority was retired", kind),
		}
	}
}
impl From<Error> for Failure {
	fn from(cause: Error) -> Self {
		Self::Unavailable(cause)
	}
}
impl From<Failure> for Error {
	/// A retired authority is a fact about the checkpoint, so it reads as
	/// stale; an unavailable room keeps the class of whatever made it so.
	fn from(failure: Failure) -> Self {
		match failure {
			Failure::Unavailable(cause) => cause,
			retired @ Failure::Retired { .. } => Error::stale(retired.to_string()),
		}
	}
}
impl Failure {
	pub fn authority(kind: Kind, link: &str, error: ClientError) -> Self {
		let retired = matches!(&error, ClientError::Binding(error) if error.is_publication_not_found())
			|| matches!(
				(&kind, &error),
				(Kind::Manager, ClientError::Reply(Refusal::ManagerMismatch))
			) || matches!(
			(&kind, &error),
			(
				Kind::Steward,
				ClientError::Custody(rooms_application::room::stewardship::Error::StewardRetired)
			)
		);
		if retired && let Some(token) = rooms_glowcap::routes::CheckpointRoutes.authority_token(link) {
			return Self::Retired { kind, token };
		}
		Self::Unavailable(Error::peer(error))
	}
}

pub use rooms_glowcap::client::directory::entry::{Acquired, Reached};

pub async fn room_reference<P: Platform>(
	entropy_source: EntropySource,
	directory: &Directory<P>,
	name: &str,
	link: Option<&str>,
	publication: Option<&str>,
) -> Result<Reached, Failure> {
	if let Some(link) = link.filter(|link| !link.is_empty()) {
		let reference = directory
			.client()
			.enliven(link)
			.await
			.map_err(|error| Failure::authority(Kind::Room, link, error))?;
		return Ok(Reached {
			reference,
			acquired: None,
		});
	}
	if let Some(publication) = publication.filter(|id| !id.is_empty()) {
		let reference = directory.enter_publication(publication).await.map_err(Error::peer)?;
		return Ok(Reached {
			reference,
			acquired: None,
		});
	}
	enter_or_open(entropy_source, directory, name)
		.await
		.map_err(Failure::from)
}

/// The directory client reports an enter-or-open that did not reach a room
/// in its own words; the room stays unreached until the directory changes.
async fn enter_or_open<P: Platform>(
	entropy_source: EntropySource,
	directory: &Directory<P>,
	name: &str,
) -> Result<Reached, Error> {
	rooms_glowcap::client::directory::entry::enter_or_open(
		|bytes| {
			entropy_source
				.borrow_mut()
				.fill(bytes)
				.map_err(|_| "room recovery-key entropy is unavailable".to_owned())
		},
		directory,
		name,
	)
	.await
	.map_err(Error::closed)
}
