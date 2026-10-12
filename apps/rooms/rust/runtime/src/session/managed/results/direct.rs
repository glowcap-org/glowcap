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
	let data = serde_json::to_string(&Direct::Ready {
		inbox: FieldKey::new(coordinate.key.slot(), coordinate.key.generation()),
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
	Ok(match row {
		Direct::Pending => fields.is_empty(),
		Direct::Ready { inbox } => {
			fields == [expected]
				&& inbox.slot() == expected.key.slot()
				&& inbox.generation() == expected.key.generation()
		}
	})
}

/// Only this typed negative answer proves the directory delivered its request.
/// It carries no inbox custody and permits no executor redispatch. Every other
/// broken or disconnected call keeps its original uncertain receipt.
pub(super) fn pending(error: &glowcap::Error) -> Option<Settlement> {
	use rooms_application::failure::{Failure, FailureCode};
	if error.kind() != glowcap::ErrorKind::Broken
		|| error
			.message()
			.and_then(Failure::parse)
			.is_none_or(|failure| failure.code != FailureCode::IntroductionPending)
	{
		return None;
	}
	Some(Settlement::data(DIRECT_PENDING.to_owned()))
}
/// `Direct::Pending` as serde renders it. The test below holds the two equal.
const DIRECT_PENDING: &str = r#"{"status":"pending"}"#;

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn the_pending_constant_is_the_serialized_variant() {
		assert_eq!(serde_json::to_string(&Direct::Pending).unwrap(), DIRECT_PENDING);
	}
}
