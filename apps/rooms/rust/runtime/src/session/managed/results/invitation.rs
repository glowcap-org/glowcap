//! Claimed entrances remain private live custody until mediated subscription.
use super::*;
use rooms_application::content::session::results::Acceptance;

fn coordinate() -> Coordinate {
	Coordinate {
		role: custody::Role::AcceptedAccess,
		key: FieldKey::new(
			NonZeroU64::new(1).expect("result slot"),
			NonZeroU64::new(1).expect("result generation"),
		),
	}
}
pub(super) fn read(value: &Argument) -> Result<Settlement> {
	let reference = Ref::try_from(value).map_err(|_| loam::refusal("invitation returned no entrance capability"))?;
	let coordinate = coordinate();
	let row = Acceptance {
		entrance: FieldKey::new(coordinate.key.slot(), coordinate.key.generation()),
	};
	Ok(Settlement(Argument::List(vec![
		serde_json::to_string(&row)
			.map_err(|_| loam::refusal("invalid acceptance result"))?
			.into(),
		Argument::List(vec![Argument::List(vec![
			serde_json::to_string(&coordinate)
				.map_err(|_| loam::refusal("invalid entrance coordinate"))?
				.into(),
			Argument::Reference(reference),
			Argument::List(vec!["live".into()]),
		])]),
	])))
}
pub(super) fn matches(data: &str, actual: &[Coordinate]) -> Result<bool> {
	let row: Acceptance = serde_json::from_str(data).map_err(|_| loam::refusal("invalid acceptance result"))?;
	let expected = coordinate();
	Ok(actual == [expected]
		&& row.entrance.slot() == expected.key.slot()
		&& row.entrance.generation() == expected.key.generation())
}
