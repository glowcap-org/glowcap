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
	/// Each imported entrance names its room. An entrance to a room the
	/// session already stands in becomes that room's way in instead of a second
	/// row: the standing row takes the import as its access and the staged row
	/// goes. Rooms match by the manager identity the entrance and the held seat
	/// both answer, never by name, because two rooms on one directory can
	/// share a name.
	pub async fn resolve_imported_rooms(&self, imports: &mut Vec<Import>, intent: &mut Intent) -> Result<(), Error> {
		let mut at = 0;
		while at < intent.conversations.as_slice().len() {
			let staged = match &intent.conversations.as_slice()[at] {
				workspace::Conversation::Room(room) => room.access.and_then(|access| {
					imports
						.iter()
						.find(|entry| entry.coordinate == custody::Coordinate::new(custody::Role::RoomAccess, access))
						.map(|entry| {
							(
								access,
								entry.reference.clone(),
								room.directory.clone(),
								room.seat.is_none(),
							)
						})
				}),
				_ => None,
			};
			let Some((access, imported, directory, unseated)) = staged else {
				at += 1;
				continue;
			};
			// The rows that could already stand in the imported room: seated,
			// on its directory. With none, nothing is asked over the wire.
			let seated: Vec<(usize, custody::FieldKey<custody::RoomSeat>)> = if unseated {
				intent
					.conversations
					.as_slice()
					.iter()
					.enumerate()
					.filter_map(|(index, row)| match row {
						workspace::Conversation::Room(room) if index != at && room.directory == directory => {
							room.seat.map(|seat| (index, seat))
						}
						_ => None,
					})
					.collect()
			} else {
				Vec::new()
			};
			let standing = if seated.is_empty() {
				None
			} else {
				let reply = self
					.caller
					.call(
						&imported,
						authority::MANAGED_IDENTITY,
						&[],
						"the imported room did not identify its manager",
					)
					.await?;
				let identity = authority::management_identity(&crate::Value(&reply))?.to_owned();
				self.standing_in(&seated, &identity).await
			};
			match standing {
				Some(index) => {
					// The staged row's other fields go with it, so nothing is
					// imported that no row refers to.
					let entrance = custody::Coordinate::new(custody::Role::RoomAccess, access);
					let dropped: Vec<custody::Coordinate> = intent.conversations.as_slice()[at]
						.coordinates()
						.filter(|coordinate| *coordinate != entrance)
						.collect();
					imports.retain(|import| !dropped.contains(&import.coordinate));
					if let workspace::Conversation::Room(room) = &mut intent.conversations.as_mut_slice()[index] {
						room.access = Some(access);
						room.accepted = None;
						room.public_entry = None;
						// The join stated the intent to be in this room across connections.
						room.reconnect = workspace::Reconnect::Requested;
					}
					intent.conversations.remove(at);
				}
				None => {
					let reply = self
						.caller
						.call(
							&imported,
							rooms_application::room::queries::CALLED,
							&[],
							"the imported room did not identify its name",
						)
						.await?;
					let name = rooms_application::fields::Text::new(
						reply
							.as_str()
							.ok_or_else(|| loam::refusal("invalid imported room name"))?
							.into(),
					)
					.ok_or_else(|| loam::refusal("invalid imported room name"))?;
					if let workspace::Conversation::Room(room) = &mut intent.conversations.as_mut_slice()[at] {
						room.name = name;
					}
					at += 1;
				}
			}
		}
		Ok(())
	}
	/// The seated row whose seat answers the manager identity `identity`, if
	/// the session stands in that room.
	async fn standing_in(
		&self,
		seated: &[(usize, custody::FieldKey<custody::RoomSeat>)],
		identity: &str,
	) -> Option<usize> {
		for (index, seat) in seated {
			// tolerant: a seat that does not answer is not the one stood in,
			// and the staged row keeps its own place.
			let answered = self
				.room_management_identity(custody::Coordinate::new(custody::Role::RoomSeat, *seat))
				.await
				.ok();
			if answered.as_deref() == Some(identity) {
				return Some(*index);
			}
		}
		None
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
	pub async fn room_identity(&self, seat: custody::Coordinate) -> Result<String, Error> {
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
		Ok(authority::seat_room_identity(&crate::Value(&reply))?.into())
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
	/// Whether `link` arrives over the session `entrance` arrives over, or both
	/// are local to this Host.
	fn same_server(&self, entrance: &Ref, link: &Ref) -> Result<bool, Error> {
		let host = self.caller.host();
		Ok(
			match (host.reference_session(entrance)?, host.reference_session(link)?) {
				(Some(entrance), Some(link)) => entrance.same_session(&link),
				(None, None) => true,
				_ => false,
			},
		)
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
			// A room's identity is readable by any member, so a link elsewhere
			// could answer it. An entrance imported alongside names the server
			// the link must reach. A seat is held inside the managed runtime and
			// this client reads it only through a facade, so a seated room is
			// proved by identity alone.
			if let Standing::Imported(entry) = &standing {
				for link in [manager, moderator].into_iter().flatten() {
					if !self.same_server(&entry.reference, &link.reference)? {
						return Err(loam::refusal("that link does not reach this room's server").into());
					}
				}
			}
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
							.map_err(|_| loam::refusal("the room link is not well formed"))?;
						authority::room_identity(token)?
					}
					Standing::Seated(seat) => self.room_identity(*seat).await?,
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
				authority::verify_steward_identity(&crate::Value(&governed), &identity)?;
			}
		}
		Ok(())
	}
}
