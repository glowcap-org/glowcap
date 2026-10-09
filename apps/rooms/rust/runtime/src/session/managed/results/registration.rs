//! A registration acquires one exact name capability and its committed identity.
use super::*;
use rooms_application::{content::session::results::Registration, directory::registration};

fn coordinate() -> Coordinate {
	Coordinate {
		role: custody::Role::DirectoryName,
		key: FieldKey::new(
			NonZeroU64::new(1).expect("result slot"),
			NonZeroU64::new(1).expect("result generation"),
		),
	}
}
pub(super) fn read(value: &Argument, intent: &str) -> Result<Settlement> {
	let Some([nick, id, Argument::Reference(name)]) = value.as_list() else {
		return Err(loam::refusal("directory returned no committed registration"));
	};
	let nick = nick
		.as_str()
		.filter(|nick| rooms_application::room::inbox::valid_nick(nick))
		.ok_or_else(|| loam::refusal("invalid granted nickname"))?;
	let (_, _, _, request): (String, u64, String, Vec<String>) =
		serde_json::from_str(intent).map_err(|_| loam::refusal("invalid registration intent"))?;
	let [_, expected, _, allocation, _] = request.as_slice() else {
		return Err(loam::refusal("invalid registration intent"));
	};
	if allocation == "exact" && nick != expected {
		return Err(loam::refusal("directory changed an exact nickname"));
	}
	let id = registration::Id::parse(id.as_str().unwrap_or(""))
		.map_err(|_| loam::refusal("invalid registration identity"))?;
	let coordinate = coordinate();
	let data = serde_json::to_string(&Registration {
		nick: Text::new(nick.into()).expect("validated nickname"),
		id: Text::new(id.as_str().into()).expect("validated identity"),
		name: FieldKey::new(coordinate.key.slot(), coordinate.key.generation()),
	})
	.map_err(|_| loam::refusal("invalid registration result"))?;
	let field = Argument::List(vec![
		serde_json::to_string(&coordinate)
			.map_err(|_| loam::refusal("invalid registration coordinate"))?
			.into(),
		name.clone().into(),
		Argument::List(vec!["live".into()]),
	]);
	Ok(Settlement(Argument::List(vec![
		data.into(),
		Argument::List(vec![field]),
	])))
}
pub(super) fn matches(data: &str, fields: &[Coordinate]) -> Result<bool> {
	let row: Registration = serde_json::from_str(data).map_err(|_| loam::refusal("invalid registration data"))?;
	let expected = coordinate();
	Ok(fields == [expected]
		&& row.name.slot() == expected.key.slot()
		&& row.name.generation() == expected.key.generation()
		&& row
			.nick
			.text()
			.as_str()
			.is_some_and(rooms_application::room::inbox::valid_nick)
		&& row
			.id
			.text()
			.as_str()
			.is_some_and(|id| registration::Id::parse(id).is_ok()))
}
