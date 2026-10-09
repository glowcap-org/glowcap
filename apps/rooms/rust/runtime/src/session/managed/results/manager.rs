//! Manager recovery uses the operator's exact management identity and result.
use super::*;
use rooms_application::content::session::results::RoomManager;

fn coordinate() -> Coordinate {
	Coordinate {
		role: custody::Role::RoomControl,
		key: FieldKey::new(NonZeroU64::new(1).unwrap(), NonZeroU64::new(1).unwrap()),
	}
}
pub(super) fn read(value: &Argument, intent: &str) -> Result<Acquisition> {
	let (_, _, name, request): (String, u64, String, Vec<String>) =
		serde_json::from_str(intent).map_err(|_| loam::refusal("invalid manager recovery intent"))?;
	let [_, action, identity] = request.as_slice() else {
		return Err(loam::refusal("invalid manager recovery intent"));
	};
	if name != "operator" || action != "giveManager" || identity.is_empty() {
		return Err(loam::refusal("invalid manager recovery intent"));
	}
	let uri = authority::room_link(&rooms_glowcap::Value(value))
		.map_err(|_| loam::refusal("operator returned no manager recipe"))?
		.to_owned();
	glowcap::parse_sturdyref(&uri, glowcap::CaptpVersion::V1_0)?;
	let coordinate = coordinate();
	let data = serde_json::to_string(&RoomManager {
		control: FieldKey::new(coordinate.key.slot(), coordinate.key.generation()),
	})
	.map_err(|_| loam::refusal("invalid manager result"))?;
	Ok(Acquisition {
		data,
		lookup: Lookup::Manager {
			coordinate,
			uri,
			identity: identity.clone(),
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
