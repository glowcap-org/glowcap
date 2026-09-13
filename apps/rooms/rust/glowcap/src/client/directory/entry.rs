//! Friendly entry composes strict directory verbs and preserves acquired authority.
use super::Directory;
use crate::client::{Deadline, Error};
use glowcap::Ref;
use rooms_application::{
	directory::creation::RecoveryKey,
	failure::{Failure as WireFailure, FailureCode},
	room::policy::RoomPolicy,
};

/// The room entrance capability, and the durable authority acquired on the way
/// when this session opened the room itself.
pub struct Reached {
	pub reference: Ref,
	pub acquired: Option<Acquired>,
}

pub struct Acquired {
	pub room_link: String,
	pub manager_link: String,
}

pub async fn enter_or_open<D: Deadline>(
	mut entropy_source: impl FnMut(&mut [u8; 16]) -> Result<(), String>,
	directory: &Directory<D>,
	name: &str,
) -> Result<Reached, String> {
	match directory.enter(name).await {
		Ok(reference) => {
			return Ok(Reached {
				reference,
				acquired: None,
			});
		}
		Err(error) if code(&error) == Some(FailureCode::NoSuchRoom) => {}
		Err(error) => return Err(error.to_string()),
	}
	// Managed first: a directory that publishes room managers hands back the
	// authority over the room it creates. One that does not still opens rooms;
	// it just has no authority to hand back. Either open loses the same race
	// the same way: somebody else's room is one to enter, not an error.
	let mut entropy = [0u8; 16];
	entropy_source(&mut entropy)?;
	let key = RecoveryKey::from_entropy(entropy);
	match directory.open_managed(name, RoomPolicy::Open, &key).await {
		Ok(managed) => {
			return Ok(Reached {
				reference: managed.room,
				acquired: Some(Acquired {
					room_link: managed.room_link,
					manager_link: managed.manager_link,
				}),
			});
		}
		Err(error) if code(&error) == Some(FailureCode::NoRoomManagers) => {}
		Err(error) if code(&error) == Some(FailureCode::RoomExists) => return entered(directory, name).await,
		Err(error) => return Err(error.to_string()),
	}
	match directory.open(name).await {
		Ok(reference) => Ok(Reached {
			reference,
			acquired: None,
		}),
		Err(error) if code(&error) == Some(FailureCode::RoomExists) => entered(directory, name).await,
		Err(error) => Err(error.to_string()),
	}
}

async fn entered<D: Deadline>(directory: &Directory<D>, name: &str) -> Result<Reached, String> {
	let reference = directory.enter(name).await.map_err(|e| e.to_string())?;
	Ok(Reached {
		reference,
		acquired: None,
	})
}

fn code(error: &Error) -> Option<FailureCode> {
	let Error::Binding(error) = error else { return None };
	if error.kind() != glowcap::ErrorKind::Broken {
		return None;
	}
	error.message().and_then(WireFailure::parse).map(|failure| failure.code)
}
