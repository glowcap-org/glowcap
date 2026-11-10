//! Imported room roles are checked against the room the session stands in:
//! the seat it holds there, or the entrance the same acquisition imports.
use super::*;
use rooms_application::room::authority;

/// Where a room's identity is asked while its roles are imported.
enum Standing<'a> {
	/// This acquisition imports the room's entrance too, so the session holds
	/// no seat and the imported entrance answers.
	Imported(&'a Import),
	/// The session already stands in the room, and its seat answers.
	Seated(custody::Coordinate),
}

impl<D: Deadline + Clone> Workspace<D> {
	pub async fn resolve_imported_room_names(&self, imports: &[Import], intent: &mut Intent) -> Result<(), Error> {
		for conversation in intent.conversations.as_mut_slice() {
			let workspace::Conversation::Room(room) = conversation else {
				continue;
			};
			let Some(access) = room.access else { continue };
			let Some(imported) = imports
				.iter()
				.find(|entry| entry.coordinate == custody::Coordinate::new(custody::Role::RoomAccess, access))
			else {
				continue;
			};
			let reply = self
				.caller
				.call(
					&imported.reference,
					rooms_application::room::queries::CALLED,
					&[],
					"the imported room did not identify its name",
				)
				.await?;
			room.name = rooms_application::fields::Text::new(
				reply
					.as_str()
					.ok_or_else(|| loam::refusal("invalid imported room name"))?
					.into(),
			)
			.ok_or_else(|| loam::refusal("invalid imported room name"))?;
		}
		Ok(())
	}
	/// The identity facade over the exact seat `seat` names. It answers the
	/// manager's identity and the room's public digest.
	async fn room_identity_reader(&self, seat: custody::Coordinate) -> Result<Ref, Error> {
		if seat.role != custody::Role::RoomSeat {
			return Err(loam::refusal("room identity requires a room seat").into());
		}
		let selected = serde_json::to_string(&seat).map_err(|_| loam::refusal("invalid room seat coordinate"))?;
		self.reader("room-identity-reader", &[selected.into()]).await
	}
	pub async fn room_publication_identity(&self, seat: custody::Coordinate) -> Result<String, Error> {
		let reader = self.room_identity_reader(seat).await?;
		let reply = self
			.caller
			.call(
				&reader,
				authority::ROOM_IDENTITY,
				&[],
				"the exact room did not identify its link",
			)
			.await?;
		Ok(reply
			.as_str()
			.filter(|value| !value.is_empty())
			.ok_or_else(|| loam::refusal("invalid room publication identity"))?
			.into())
	}
	pub async fn room_management_identity(&self, seat: custody::Coordinate) -> Result<String, Error> {
		let reader = self.room_identity_reader(seat).await?;
		let reply = self
			.caller
			.call(
				&reader,
				authority::MANAGED_IDENTITY,
				&[],
				"the exact room did not identify its manager",
			)
			.await?;
		Ok(authority::management_identity(&crate::Value(&reply))?.into())
	}
	/// Both product fronts perform the same identity checks before preparing the
	/// retained acquisition. The transaction subsequently verifies each actual
	/// capability/recipe pair and the original workspace revision.
	pub async fn validate_room_authority_imports(&self, imports: &[Import], intent: &Intent) -> Result<(), Error> {
		for conversation in intent.conversations.as_slice() {
			let workspace::Conversation::Room(room) = conversation else {
				continue;
			};
			let manager = room.control.and_then(|key| {
				imports
					.iter()
					.find(|entry| entry.coordinate == custody::Coordinate::new(custody::Role::RoomControl, key))
			});
			let moderator = room.moderator.and_then(|key| {
				imports
					.iter()
					.find(|entry| entry.coordinate == custody::Coordinate::new(custody::Role::RoomAccess, key))
			});
			if manager.is_none() && moderator.is_none() {
				continue;
			}
			let imported = room.access.and_then(|access| {
				imports
					.iter()
					.find(|entry| entry.coordinate == custody::Coordinate::new(custody::Role::RoomAccess, access))
			});
			let standing = match (imported, room.seat) {
				(Some(entry), _) => Standing::Imported(entry),
				(None, Some(seat)) => Standing::Seated(custody::Coordinate::new(custody::Role::RoomSeat, seat)),
				(None, None) => {
					return Err(loam::refusal("join the room before taking a link to manage or moderate it").into());
				}
			};
			if let Some(manager) = manager {
				let governed = self
					.caller
					.call(
						&manager.reference,
						authority::GOVERNS,
						&[],
						"the manager did not identify its room",
					)
					.await?;
				let identity = match &standing {
					Standing::Imported(entry) => {
						self.caller
							.call(
								&entry.reference,
								authority::MANAGED_IDENTITY,
								&[],
								"the imported room did not identify its manager",
							)
							.await?
					}
					Standing::Seated(seat) => self.room_management_identity(*seat).await?.into(),
				};
				authority::verify_manager(&crate::Value(&governed), &crate::Value(&identity))?;
			}
			if let Some(moderator) = moderator {
				let identity = match &standing {
					Standing::Imported(entry) => {
						let uri = entry.uri.as_ref().ok_or_else(|| {
							loam::refusal("moderator import requires the exact room publication recipe")
						})?;
						let sturdy = glowcap::parse_sturdyref(uri, glowcap::CaptpVersion::V1_0)?;
						let token = core::str::from_utf8(&sturdy.swissnum)
							.map_err(|_| loam::refusal("invalid room publication identity"))?;
						authority::room_identity(token)?
					}
					Standing::Seated(seat) => self.room_publication_identity(*seat).await?,
				};
				let governed = self
					.caller
					.call(
						&moderator.reference,
						authority::GOVERNS,
						&[],
						"the moderator did not identify its room",
					)
					.await?;
				if governed.as_str() != Some(identity.as_str()) {
					return Err(loam::refusal("that moderator belongs to a different room").into());
				}
			}
		}
		Ok(())
	}
}
