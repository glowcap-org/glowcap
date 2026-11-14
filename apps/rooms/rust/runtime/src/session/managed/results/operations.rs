//! Operation answers retain bounded data and private exact connection custody.
use super::{live::LiveRow, *};
use rooms_application::session::operations::{Listener, wire};

impl LiveRow for Connection {
	const ROLE: custody::Role = custody::Role::IrcConnection;
	const NO_CAPABILITY: &'static str = "gateway returned no connection capability";
	const INVALID_RESULT: &'static str = "invalid connection result";
	const INVALID_COORDINATE: &'static str = "invalid connection coordinate";
	fn with_key(key: FieldKey<()>) -> Self {
		Self {
			connection: key.retag(),
		}
	}
	fn key(&self) -> FieldKey<()> {
		self.connection.retag()
	}
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
