//! Subscription result data and exact live fields share one ordered codec.
use super::*;
use rooms_application::{content::session::results::Membership, room::membership};

fn key<K>() -> FieldKey<K> {
	FieldKey::new(NonZeroU64::MIN, NonZeroU64::MIN)
}
fn coordinate<K>(role: custody::Role, key: FieldKey<K>) -> Coordinate {
	Coordinate {
		role,
		key: FieldKey::new(key.slot(), key.generation()),
	}
}
fn coordinates(row: &Membership) -> Vec<Coordinate> {
	core::iter::once(coordinate(custody::Role::RoomSeat, row.seat))
		.chain(row.subject.map(|key| coordinate(custody::Role::RoomSubject, key)))
		.chain(row.files.map(|key| coordinate(custody::Role::RoomFiles, key)))
		.collect()
}
pub(super) fn read(value: &Argument) -> Result<Settlement> {
	let args = value
		.as_list()
		.ok_or_else(|| loam::refusal("invalid membership result"))?;
	let values = rooms_glowcap::values(args).collect::<Vec<_>>();
	let seat = membership::read_answer(&values).map_err(|_| loam::refusal("invalid membership result"))?;
	let row = Membership {
		kind: seat.kind,
		seat: key(),
		subject: seat.subject.as_ref().map(|_| key()),
		files: seat.files.as_ref().map(|_| key()),
	};
	let fields = coordinates(&row)
		.into_iter()
		.zip(core::iter::once(seat.reference).chain(seat.subject).chain(seat.files))
		.map(|(coordinate, reference)| {
			Ok(Argument::List(vec![
				serde_json::to_string(&coordinate)
					.map_err(|_| loam::refusal("invalid membership coordinate"))?
					.into(),
				Argument::Reference(reference),
				Argument::List(vec!["live".into()]),
			]))
		})
		.collect::<Result<Vec<_>>>()?;
	Ok(Settlement(Argument::List(vec![
		serde_json::to_string(&row)
			.map_err(|_| loam::refusal("invalid membership data"))?
			.into(),
		Argument::List(fields),
	])))
}
pub(super) fn matches(data: &str, actual: &[Coordinate]) -> Result<bool> {
	let row: Membership = serde_json::from_str(data).map_err(|_| loam::refusal("invalid membership data"))?;
	Ok(coordinates(&row) == actual)
}
