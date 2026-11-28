//! A participant may install only the seat and facets its original join
//! returned, in the still-empty membership of that same room and callback.
use super::*;

impl Request<'_> {
	/// Membership results remain tied to both original targets and to the
	/// initiating grant, even if a manager reuses their scalar coordinates.
	pub(super) fn membership_origins<'r>(
		&self,
		record: &'r MetadataRecord,
		receipt: &'r custody::EffectReceipt<records::Metadata>,
	) -> Result<Option<[OriginTargets<'r>; 3]>> {
		if !self
			.selections
			.iter()
			.any(|entry| entry.result.role == custody::Role::RoomSeat)
		{
			return Ok(None);
		}
		let original = original_text(text(self.intent)?)?;
		let [_, _, verb, id, _, callback] = original.as_slice() else {
			return Ok(None);
		};
		if text(verb)? != "joinRoom" {
			return Ok(None);
		}
		let room = record
			.intent
			.room(text(id)?)
			.ok_or_else(|| refuse("original membership room was removed"))?;
		let callback = serde_json::from_str(text(callback)?).map_err(|_| refuse("invalid original room callback"))?;
		if room.inbox != Some(callback) {
			return Err(refuse("original membership callback was replaced"));
		}
		let pair = |coordinate: Coordinate| {
			let original = receipt
				.targets
				.as_slice()
				.iter()
				.map(|field| field.borrowed())
				.find(|target| target.coordinate() == coordinate)
				.ok_or_else(|| refuse("original membership target was replaced"))?;
			held_at(record, original, "original membership target is absent")
		};
		let entrance = room
			.entrance()
			.ok_or_else(|| refuse("original membership entrance is absent"))?;
		let source = room
			.source
			.and_then(|key| record.custody.get(Coordinate::new(custody::Role::SessionAccess, key)))
			.ok_or_else(|| refuse("original membership source is absent"))?;
		Ok(Some([
			pair(entrance)?,
			pair(Coordinate::new(custody::Role::RoomInbox, callback))?,
			[Retained::SessionAccess(&receipt.source), source],
		]))
	}

	pub(super) fn membership_delta(
		&self,
		record: &MetadataRecord,
		receipt: &custody::EffectReceipt<records::Metadata>,
		replacement: &Replacement,
		conversation: &str,
		candidate: &mut workspace::Intent,
	) -> Result<bool> {
		let Some(current) = record.intent.room(conversation) else {
			return Ok(false);
		};
		let Some(workspace::Conversation::Room(next)) = candidate
			.conversations
			.as_mut_slice()
			.iter_mut()
			.find(|row| row.id().text().as_str() == Some(conversation))
		else {
			return Ok(false);
		};
		if current.seat.is_some()
			|| current.subject.is_some()
			|| current.files.is_some()
			|| current.inbox.is_none()
			|| next.seat.is_none()
			|| replacement.source.is_some()
			|| !replacement.releases.is_empty()
		{
			return Ok(false);
		}
		let targets = receipt.targets.as_slice();
		let contains = |coord| {
			targets
				.iter()
				.any(|target| Some(target.borrowed().coordinate()) == coord)
		};
		if !contains(current.entrance())
			|| !contains(current.inbox.map(|key| Coordinate::new(custody::Role::RoomInbox, key)))
		{
			return Ok(false);
		}
		let destinations = [
			next.seat
				.take()
				.map(|key| Coordinate::new(custody::Role::RoomSeat, key)),
			next.subject
				.take()
				.map(|key| Coordinate::new(custody::Role::RoomSubject, key)),
			next.files
				.take()
				.map(|key| Coordinate::new(custody::Role::RoomFiles, key)),
		];
		let Outcome::Committed { retained, .. } = &receipt.outcome else {
			return Ok(false);
		};
		if destinations.iter().flatten().count() != self.selections.len()
			|| self.selections.len() != retained.as_slice().len()
		{
			return Ok(false);
		}
		Ok(self.selections.iter().all(|entry| {
			destinations.contains(&Some(entry.destination))
				&& entry.destination.role == entry.result.role
				&& record.custody.get(entry.destination).is_none()
				&& retained
					.as_slice()
					.iter()
					.any(|field| field.borrowed().coordinate() == entry.result)
		}) && *candidate == record.intent)
	}
}
