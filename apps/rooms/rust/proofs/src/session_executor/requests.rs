//! Test requests retain the exact canonical intent submitted to the session.
use super::*;

pub(super) fn coordinate(role: custody::Role, slot: u64) -> custody::Coordinate {
	custody::Coordinate {
		role,
		key: custody::FieldKey::new(NonZeroU64::new(slot).unwrap(), NonZeroU64::new(1).unwrap()),
	}
}
pub(super) async fn command(
	host: &Host,
	source: &Ref,
	id: &str,
	name: &str,
	rest: &[String],
) -> (Vec<Argument>, String) {
	let snapshot = host.send(source, "snapshot", &[]).await.unwrap();
	let base = snapshot.as_list().unwrap()[0].as_i64().unwrap();
	let canonical = serde_json::to_string(&(id, base, name, rest)).unwrap();
	let mut args = vec![id.into(), base.into(), name.into()];
	args.extend(rest.iter().cloned().map(Argument::from));
	(args, canonical)
}
