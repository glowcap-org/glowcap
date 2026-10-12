//! Operation answers retain bounded data and private exact connection custody.
use super::*;
use rooms_application::content::session::results::Connection;
use rooms_application::session::operations::{Listener, wire};

fn connection_coordinate() -> Coordinate {
	Coordinate {
		role: custody::Role::IrcConnection,
		key: FieldKey::new(NonZeroU64::MIN, NonZeroU64::MIN),
	}
}
pub(super) fn connection(value: &Argument) -> Result<Settlement> {
	let reference = Ref::try_from(value).map_err(|_| loam::refusal("gateway returned no connection capability"))?;
	let coordinate = connection_coordinate();
	let data = serde_json::to_string(&Connection {
		connection: FieldKey::new(coordinate.key.slot(), coordinate.key.generation()),
	})
	.map_err(|_| loam::refusal("invalid connection result"))?;
	Ok(Settlement(Argument::List(vec![
		data.into(),
		Argument::List(vec![Argument::List(vec![
			serde_json::to_string(&coordinate)
				.map_err(|_| loam::refusal("invalid connection coordinate"))?
				.into(),
			Argument::Reference(reference),
			Argument::List(vec!["live".into()]),
		])]),
	])))
}
pub(super) fn matches_connection(data: &str, fields: &[Coordinate]) -> Result<bool> {
	let row: Connection = serde_json::from_str(data).map_err(|_| loam::refusal("invalid connection result"))?;
	let expected = connection_coordinate();
	Ok(fields == [expected]
		&& row.connection.slot() == expected.key.slot()
		&& row.connection.generation() == expected.key.generation())
}

pub(super) fn read(reply: Reply, value: &Argument) -> Result<Settlement> {
	let data = match reply {
		Reply::Text => serde_json::to_string(
			value
				.as_str()
				.filter(|s| !s.is_empty())
				.ok_or_else(|| loam::refusal("operation returned no result text"))?,
		),
		Reply::Listener => {
			let row =
				wire::listener(&rooms_glowcap::Value(value)).map_err(|_| loam::refusal("invalid listener result"))?;
			serde_json::to_string(&row)
		}
		Reply::RetireBatch => {
			let row = view::read_retire(&rooms_glowcap::Value(value))
				.map_err(|_| loam::refusal("invalid operator retire result"))?;
			serde_json::to_string(&row)
		}
		_ => return Err(loam::refusal("unsupported operations result")),
	}
	.map_err(|_| loam::refusal("invalid operations result data"))?;
	if !Text::<32768>::accepts_utf16(data.encode_utf16()) {
		return Err(loam::refusal("operation result exceeds receipt capacity"));
	}
	Ok(Settlement::data(data))
}
pub(super) fn matches(reply: Reply, data: &str, fields: &[Coordinate]) -> Result<bool> {
	if !fields.is_empty() {
		return Ok(false);
	}
	Ok(match reply {
		Reply::Text => serde_json::from_str::<String>(data).is_ok_and(|value| !value.is_empty()),
		Reply::Listener => {
			let row: Listener =
				serde_json::from_str(data).map_err(|_| loam::refusal("invalid listener result data"))?;
			row.validate().is_ok()
		}
		Reply::RetireBatch => serde_json::from_str::<view::RetireBatch>(data).is_ok(),
		_ => false,
	})
}
