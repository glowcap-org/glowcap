//! Manager issuance retains the returned moderator, never its bearer recipe.
use super::*;
use rooms_application::content::session::results::RoomModerator;

fn coordinate() -> Coordinate {
	Coordinate {
		role: custody::Role::RoomAccess,
		key: FieldKey::new(NonZeroU64::MIN, NonZeroU64::MIN),
	}
}
/// Two transient URI parses validate the reply's room identity and moderator
/// recipe. Their owned fields retire here. Only one bounded recipe survives
/// until the Host lookup and exact result save. Borrowed reply text cannot
/// supply the decoded publication token needed for the identity check.
pub(super) fn read(value: &Argument) -> Result<Acquisition> {
	if value.as_list().is_none_or(|fields| fields.len() != 3) {
		return Err(loam::refusal("invalid moderator issuance result"));
	}
	let value = rooms_glowcap::Value(value);
	let grant = authority::steward_grant(&value).map_err(|_| loam::refusal("invalid moderator issuance result"))?;
	let room = glowcap::parse_sturdyref(grant.room_link, glowcap::CaptpVersion::V1_0)?;
	let token = std::str::from_utf8(&room.swissnum).map_err(|_| loam::refusal("invalid room publication identity"))?;
	grant
		.verify(token)
		.map_err(|_| loam::refusal("moderator issuance identifies a different room"))?;
	glowcap::parse_sturdyref(grant.steward_link, glowcap::CaptpVersion::V1_0)?;
	let coordinate = coordinate();
	let data = serde_json::to_string(&RoomModerator {
		moderator: FieldKey::new(coordinate.key.slot(), coordinate.key.generation()),
	})
	.map_err(|_| loam::refusal("invalid moderator result"))?;
	Ok(Acquisition {
		data,
		lookup: Lookup::Publication {
			coordinate,
			uri: grant.steward_link.into(),
		},
	})
}
pub(super) fn matches(data: &str, coordinates: &[Coordinate]) -> Result<bool> {
	let row: RoomModerator = serde_json::from_str(data).map_err(|_| loam::refusal("invalid moderator result"))?;
	let expected = coordinate();
	Ok(coordinates == [expected]
		&& row.moderator.slot() == expected.key.slot()
		&& row.moderator.generation() == expected.key.generation())
}

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn moderator_issuance_retains_exact_recipe_and_refuses_wrong_room_identity() {
		let mut reply = Argument::List(vec![
			"ocapn://127.0.0.1%3A1234.tcp/s/cm9vbQ".into(),
			authority::room_identity("room").unwrap().into(),
			"ocapn://127.0.0.1%3A1234.tcp/s/c3Rld2FyZA".into(),
		]);
		let prepared = read(&reply).unwrap();
		assert!(matches(&prepared.data, &[coordinate()]).unwrap());
		let Lookup::Publication { uri, .. } = prepared.lookup else {
			panic!("publication acquisition")
		};
		assert_eq!(uri, reply.as_list().unwrap()[2].as_str().unwrap());
		let Argument::List(fields) = &mut reply else {
			unreachable!()
		};
		fields[1] = authority::room_identity("another-room").unwrap().into();
		assert!(read(&reply).is_err());
	}
}
