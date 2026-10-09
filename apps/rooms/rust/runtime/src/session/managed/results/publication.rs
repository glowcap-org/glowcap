//! A returned lease is exact live custody, independently of listing readiness.
use super::*;
use rooms_application::content::session::results::Publication;

fn coordinate() -> Coordinate {
	Coordinate {
		role: custody::Role::PublicationLease,
		key: FieldKey::new(
			NonZeroU64::new(1).expect("result slot"),
			NonZeroU64::new(1).expect("result generation"),
		),
	}
}
pub(super) fn read(value: &Argument) -> Result<Settlement> {
	let reference = Ref::try_from(value).map_err(|_| loam::refusal("publication returned no lease capability"))?;
	let coordinate = coordinate();
	let row = Publication {
		lease: FieldKey::new(coordinate.key.slot(), coordinate.key.generation()),
	};
	Ok(Settlement(Argument::List(vec![
		serde_json::to_string(&row)
			.map_err(|_| loam::refusal("invalid publication result"))?
			.into(),
		Argument::List(vec![Argument::List(vec![
			serde_json::to_string(&coordinate)
				.map_err(|_| loam::refusal("invalid lease coordinate"))?
				.into(),
			Argument::Reference(reference),
			Argument::List(vec!["live".into()]),
		])]),
	])))
}
pub(super) fn matches(data: &str, actual: &[Coordinate]) -> Result<bool> {
	let row: Publication = serde_json::from_str(data).map_err(|_| loam::refusal("invalid publication result"))?;
	let expected = coordinate();
	Ok(actual == [expected]
		&& row.lease.slot() == expected.key.slot()
		&& row.lease.generation() == expected.key.generation())
}
