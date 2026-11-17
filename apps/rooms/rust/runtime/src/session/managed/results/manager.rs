//! Manager recovery keeps the identity its worker observed beside the operator's result.
use super::*;
use rooms_application::content::session::results::RoomManager;

fn coordinate() -> Coordinate {
	Coordinate {
		role: custody::Role::RoomControl,
		key: FieldKey::new(NonZeroU64::MIN, NonZeroU64::MIN),
	}
}
/// The reply of the one operator call is checked against the identity this
/// worker read from the witnessed seat. No request text supplies an identity.
pub(super) fn read(value: &Argument, identity: Option<&str>) -> Result<Acquisition> {
	let identity = identity.ok_or_else(|| loam::refusal("manager recovery has no observed identity"))?;
	let uri = authority::room_link(&rooms_glowcap::Value(value))
		.map_err(|_| loam::refusal("operator returned no manager recipe"))?
		.to_owned();
	glowcap::parse_sturdyref(&uri, glowcap::CaptpVersion::V1_0)?;
	let coordinate = coordinate();
	let data = serde_json::to_string(&RoomManager {
		control: coordinate.key.retag(),
	})
	.map_err(|_| loam::refusal("invalid manager result"))?;
	Ok(Acquisition {
		data,
		lookup: Lookup::Manager {
			coordinate,
			uri,
			identity: identity.to_owned(),
		},
	})
}
pub(super) fn matches(data: &str, coordinates: &[Coordinate]) -> Result<bool> {
	let row: RoomManager = serde_json::from_str(data).map_err(|_| loam::refusal("invalid manager result"))?;
	let expected = coordinate();
	Ok(coordinates == [expected]
		&& row.control.slot() == expected.key.slot()
		&& row.control.generation() == expected.key.generation())
}
