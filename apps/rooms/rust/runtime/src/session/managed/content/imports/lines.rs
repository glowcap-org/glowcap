//! Line numbers are scoped to the authority that accepted the original post.
use super::*;
use rooms_application::fields::SafeInteger;

impl Request<'_> {
	/// One scalar result ID and a bounded canonical request are decoded per
	/// preparation. Target fields borrow the receipt and current custody. No
	/// capability is copied or new persisted provenance is needed.
	pub(super) fn line_origin<'r>(
		&self,
		record: &'r MetadataRecord,
		receipt: &'r custody::EffectReceipt<records::Metadata>,
		candidate: &workspace::Intent,
	) -> Result<Option<[Retained<'r, records::Metadata>; 2]>> {
		let mut lines = self
			.selections
			.iter()
			.filter(|selection| selection.result.role == custody::Role::Line);
		let Some(selection) = lines.next() else { return Ok(None) };
		if lines.next().is_some() {
			return Err(refuse("one posting result selects one line"));
		}
		let Outcome::Committed { result, .. } = &receipt.outcome else {
			unreachable!("checked receipt")
		};
		#[derive(serde::Deserialize)]
		struct Identity {
			id: SafeInteger,
		}
		let identity: Identity =
			serde_json::from_str(result.text().as_str().ok_or_else(|| refuse("invalid line result"))?)
				.map_err(|_| refuse("line result has no numeric identity"))?;
		let canonical = text(self.intent)?;
		let conversation = if canonical.starts_with('{') {
			rooms_application::content::session::uploads::Intent::read(canonical)
				.map_err(|_| refuse("line acquisition requires its original upload"))?
				.conversation
		} else {
			let original = original_text(canonical)?;
			let [_, _, verb, conversation, ..] = original.as_slice() else {
				return Err(refuse("line acquisition requires its original post"));
			};
			if !matches!(text(verb)?, "say" | "sendFiles" | "refileLine") {
				return Err(refuse("receipt is not a posting result"));
			}
			text(conversation)?.to_owned()
		};
		let current = record
			.intent
			.conversations
			.as_slice()
			.iter()
			.find(|row| row.id().text().as_str() == Some(&conversation))
			.ok_or_else(|| refuse("original line conversation was removed"))?;
		let next = candidate
			.conversations
			.as_slice()
			.iter()
			.find(|row| row.id() == current.id())
			.ok_or_else(|| refuse("line result must retain its original conversation"))?;
		let line = next
			.lines()
			.iter()
			.find(|line| {
				line.handle.slot() == selection.destination.key.slot()
					&& line.handle.generation() == selection.destination.key.generation()
			})
			.ok_or_else(|| refuse("line result must select its exact destination"))?;
		if line.id != identity.id {
			return Err(refuse("line result number differs from its receipt"));
		}
		let original = receipt
			.targets
			.as_slice()
			.first()
			.ok_or_else(|| refuse("line receipt has no original target"))?
			.borrowed();
		let coordinate = original.coordinate();
		if target(current, coordinate.role, identity.id) != Some(coordinate)
			|| (coordinate.role != custody::Role::Line
				&& target(next, coordinate.role, identity.id) != Some(coordinate))
		{
			return Err(refuse("original line membership was replaced"));
		}
		let current = record
			.custody
			.get(coordinate)
			.ok_or_else(|| refuse("original line target custody is absent"))?;
		Ok(Some([original, current]))
	}
}
fn target(row: &workspace::Conversation, role: custody::Role, id: SafeInteger) -> Option<Coordinate> {
	let key = match (row, role) {
		(workspace::Conversation::Room(room), custody::Role::RoomSeat) => {
			room.seat.map(|key| (key.slot(), key.generation()))
		}
		(workspace::Conversation::Room(room), custody::Role::RoomFiles) => {
			room.files.map(|key| (key.slot(), key.generation()))
		}
		(workspace::Conversation::Direct(direct), custody::Role::DirectAccess) if !direct.closed => {
			direct.access.map(|key| (key.slot(), key.generation()))
		}
		(_, custody::Role::Line) => row
			.lines()
			.iter()
			.find(|line| line.id == id)
			.map(|line| (line.handle.slot(), line.handle.generation())),
		_ => None,
	}?;
	Some(Coordinate {
		role,
		key: custody::FieldKey::new(key.0, key.1),
	})
}
