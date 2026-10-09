//! Imported room roles are checked against exact held or imported room access.
use super::*;
use rooms_application::room::authority;

fn coordinate<K>(role: custody::Role, key: custody::FieldKey<K>) -> custody::Coordinate {
	custody::Coordinate {
		role,
		key: custody::FieldKey::new(key.slot(), key.generation()),
	}
}
impl<D: Deadline + Clone> Workspace<D> {
	/// Learn presentation from the exact imported entrance before preparing the
	/// atomic acquisition. The same reference is retained by that transaction;
	/// a supplied caption cannot substitute for the room's own name.
	pub async fn resolve_imported_room_names(&self, imports: &[Import], intent: &mut Intent) -> Result<(), Error> {
		for conversation in intent.conversations.as_mut_slice() {
			let workspace::Conversation::Room(room) = conversation else {
				continue;
			};
			let Some(access) = room.access else { continue };
			let Some(imported) = imports
				.iter()
				.find(|entry| entry.coordinate == coordinate(custody::Role::RoomAccess, access))
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
	pub async fn room_publication_identity(&self, access: custody::Coordinate) -> Result<String, Error> {
		let selected = serde_json::to_string(&access).map_err(|_| loam::refusal("invalid room access coordinate"))?;
		let reply = self.call("room-publication-identity", &[selected.into()]).await?;
		Ok(reply
			.as_str()
			.filter(|value| !value.is_empty())
			.ok_or_else(|| loam::refusal("invalid room publication identity"))?
			.into())
	}
	pub async fn room_management_identity(&self, access: custody::Coordinate) -> Result<String, Error> {
		let selected = serde_json::to_string(&access).map_err(|_| loam::refusal("invalid room access coordinate"))?;
		let reader = self.reader("room-identity-reader", &[selected.into()]).await?;
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
					.find(|entry| entry.coordinate == coordinate(custody::Role::RoomControl, key))
			});
			let moderator = room.moderator.and_then(|key| {
				imports
					.iter()
					.find(|entry| entry.coordinate == coordinate(custody::Role::RoomAccess, key))
			});
			if manager.is_none() && moderator.is_none() {
				continue;
			}
			let access = room
				.access
				.ok_or_else(|| loam::refusal("room role import requires exact continuing room access"))?;
			let selected = coordinate(custody::Role::RoomAccess, access);
			let imported = imports.iter().find(|entry| entry.coordinate == selected);
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
				let identity = match imported {
					Some(entry) => {
						self.caller
							.call(
								&entry.reference,
								authority::MANAGED_IDENTITY,
								&[],
								"the imported room did not identify its manager",
							)
							.await?
					}
					None => self.room_management_identity(selected).await?.into(),
				};
				authority::verify_manager(&crate::Value(&governed), &crate::Value(&identity))?;
			}
			if let Some(moderator) = moderator {
				let identity = match imported {
					Some(entry) => {
						let uri = entry.uri.as_ref().ok_or_else(|| {
							loam::refusal("moderator import requires the exact room publication recipe")
						})?;
						let sturdy = glowcap::parse_sturdyref(uri, glowcap::CaptpVersion::V1_0)?;
						let token = core::str::from_utf8(&sturdy.swissnum)
							.map_err(|_| loam::refusal("invalid room publication identity"))?;
						authority::room_identity(token)?
					}
					None => self.room_publication_identity(selected).await?,
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
