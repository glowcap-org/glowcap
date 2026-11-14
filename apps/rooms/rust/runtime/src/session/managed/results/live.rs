//! A result that hands back one capability under one live coordinate. The
//! receipt names the coordinate and the session keeps the capability.
use super::*;
use serde::{Serialize, de::DeserializeOwned};

pub(super) trait LiveRow: Serialize + DeserializeOwned {
	/// The custody role the coordinate carries.
	const ROLE: custody::Role;
	/// The refusal when the reply holds no capability.
	const NO_CAPABILITY: &'static str;
	/// The refusal when the receipt row does not encode or decode.
	const INVALID_RESULT: &'static str;
	/// The refusal when the coordinate does not encode.
	const INVALID_COORDINATE: &'static str;
	/// The receipt row naming `key`.
	fn with_key(key: FieldKey<()>) -> Self;
	/// The key this receipt row names.
	fn key(&self) -> FieldKey<()>;
}

fn coordinate<R: LiveRow>() -> Coordinate {
	Coordinate {
		role: R::ROLE,
		key: FieldKey::new(NonZeroU64::MIN, NonZeroU64::MIN),
	}
}
pub(super) fn read<R: LiveRow>(value: &Argument) -> Result<Settlement> {
	let reference = Ref::try_from(value).map_err(|_| loam::refusal(R::NO_CAPABILITY))?;
	let coordinate = coordinate::<R>();
	Ok(Settlement(Argument::List(vec![
		serde_json::to_string(&R::with_key(coordinate.key))
			.map_err(|_| loam::refusal(R::INVALID_RESULT))?
			.into(),
		Argument::List(vec![Argument::List(vec![
			serde_json::to_string(&coordinate)
				.map_err(|_| loam::refusal(R::INVALID_COORDINATE))?
				.into(),
			Argument::Reference(reference),
			Argument::List(vec!["live".into()]),
		])]),
	])))
}
pub(super) fn matches<R: LiveRow>(data: &str, actual: &[Coordinate]) -> Result<bool> {
	let row: R = serde_json::from_str(data).map_err(|_| loam::refusal(R::INVALID_RESULT))?;
	let expected = coordinate::<R>();
	Ok(actual == [expected] && row.key() == expected.key)
}
