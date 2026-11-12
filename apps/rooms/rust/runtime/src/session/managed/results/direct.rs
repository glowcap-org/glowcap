//! Directory introductions retain exact private live inboxes, never alias URIs.
use super::*;
use rooms_application::content::session::results::Direct;

fn coordinate() -> Coordinate {
	Coordinate {
		role: custody::Role::DirectAccess,
		key: FieldKey::new(NonZeroU64::MIN, NonZeroU64::MIN),
	}
}
pub(super) fn read(value: &Argument) -> Result<Settlement> {
	let reference = Ref::try_from(value).map_err(|_| loam::refusal("directory returned no direct inbox"))?;
	let coordinate = coordinate();
	let data = serde_json::to_string(&Direct {
		inbox: coordinate.key.retag(),
	})
	.map_err(|_| loam::refusal("invalid direct result"))?;
	Ok(Settlement(Argument::List(vec![
		data.into(),
		Argument::List(vec![Argument::List(vec![
			serde_json::to_string(&coordinate)
				.map_err(|_| loam::refusal("invalid direct coordinate"))?
				.into(),
			Argument::Reference(reference),
			Argument::List(vec!["live".into()]),
		])]),
	])))
}
pub(super) fn matches(data: &str, fields: &[Coordinate]) -> Result<bool> {
	let row: Direct = serde_json::from_str(data).map_err(|_| loam::refusal("invalid direct result"))?;
	let expected = coordinate();
	Ok(fields == [expected]
		&& row.inbox.slot() == expected.key.slot()
		&& row.inbox.generation() == expected.key.generation())
}
