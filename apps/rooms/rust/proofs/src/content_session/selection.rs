//! Checked role selection refuses stale generations, occupied room roles and
//! encoded bearer authority. Retirement preserves unrelated imports and aliases.
use super::*;
use rooms_application::{content::session::local, session::command::Request};

fn apply(
	intent: &mut workspace::Intent,
	fields: &mut custody::Custody<References>,
	name: &str,
	args: &[&str],
) -> Result<(), local::Refusal> {
	use crate::arguments::Arg;
	let mut wire = vec![Arg::Text("selection".into()), Arg::Integer(1), Arg::Text(name.into())];
	wire.extend(args.iter().map(|value| Arg::Text((*value).into())));
	let request = Request::parse(&wire).unwrap();
	assert!(local::recognizes(request.route()));
	assert!(
		requirements::command(request.route())
			.unwrap()
			.workspace
			.contains(&ManageCustody)
	);
	local::apply(&request, intent, fields)
}
fn encoded<K>(slot: u64, generation: u64) -> String {
	serde_json::to_string(&key::<K>(slot, generation)).unwrap()
}
pub fn run() {
	let mut raw = fixture();
	raw["conversations"][0]["access"] = Value::Null;
	raw["conversations"][0]["reconnect"] = json!("manual");
	let mut intent = workspace::Intent::decode(&raw.to_string()).unwrap();
	let mut fields = custody::Custody::<References>::default();
	fields
		.insert_directory_access(custody::Held {
			key: key(1, 1),
			reference: Directory,
		})
		.unwrap();
	for slot in 1..=3 {
		fields
			.insert_room_access(custody::Held {
				key: key(slot, 1),
				reference: Room(slot),
			})
			.unwrap();
		fields
			.insert_operator(custody::Held {
				key: key(slot, 1),
				reference: (),
			})
			.unwrap();
		fields
			.insert_archive_access(custody::Held {
				key: key(slot, 1),
				reference: (),
			})
			.unwrap();
	}
	fields
		.insert_room_control(custody::Held {
			key: key(4, 5),
			reference: (),
		})
		.unwrap();
	fields
		.insert_archive_control(custody::Held {
			key: key(6, 7),
			reference: (),
		})
		.unwrap();
	for (command, key) in [
		("takeRoomLink", encoded::<custody::RoomAccess>(1, 1)),
		("takeRoomModerator", encoded::<custody::RoomAccess>(2, 1)),
		("takeRoomManager", encoded::<custody::RoomControl>(4, 5)),
	] {
		let before = fields.len();
		apply(&mut intent, &mut fields, command, &["conversation", &key]).unwrap();
		apply(&mut intent, &mut fields, command, &["conversation", &key]).unwrap();
		assert_eq!(fields.len(), before, "selection copies no capability fields");
	}
	let initial = intent.clone();
	let mut visit = initial.clone();
	let workspace::Conversation::Room(room) = &mut visit.conversations.as_mut_slice()[0] else {
		panic!("room")
	};
	room.access = None;
	room.accepted = Some(key(9, 10));
	fields
		.insert_accepted_access(custody::Held {
			key: key(9, 10),
			reference: (),
		})
		.unwrap();
	assert_eq!(visit.validate(&fields), Ok(()));
	apply(
		&mut visit,
		&mut fields,
		"takeRoomLink",
		&["conversation", &encoded::<custody::RoomAccess>(1, 1)],
	)
	.unwrap();
	let workspace::Conversation::Room(room) = &visit.conversations.as_slice()[0] else {
		panic!("room")
	};
	assert_eq!(room.access, Some(key(1, 1)));
	assert!(room.accepted.is_none());
	assert!(
		fields.accepted_access(key(9, 10)).is_none(),
		"an explicit continuing-access selection retires the unused visit"
	);
	assert_eq!(visit.validate(&fields), Ok(()));
	for (command, args) in [
		(
			"takeRoomLink",
			vec!["conversation".into(), encoded::<custody::RoomAccess>(3, 1)],
		),
		(
			"takeRoomModerator",
			vec!["conversation".into(), encoded::<custody::RoomAccess>(3, 1)],
		),
		(
			"takeRoomModerator",
			vec!["conversation".into(), encoded::<custody::RoomAccess>(2, 2)],
		),
		(
			"takeRoomModerator",
			vec!["conversation".into(), encoded::<custody::RoomControl>(4, 5)],
		),
		(
			"takeRoomManager",
			vec!["conversation".into(), encoded::<custody::RoomAccess>(1, 1)],
		),
		("takeRoomLink", vec!["conversation".into(), "\"ocapn://bearer\"".into()]),
		("takeRoomModerator", vec!["conversation".into()]),
	] {
		let args = args.iter().map(String::as_str).collect::<Vec<_>>();
		assert!(
			apply(&mut intent, &mut fields, command, &args).is_err(),
			"{command}: {args:?}"
		);
		assert_eq!(intent, initial);
	}
	let first = local::ArchiveSelection {
		access: key(1, 1),
		control: Some(key(6, 7)),
	};
	let first = serde_json::to_string(&first).unwrap();
	apply(&mut intent, &mut fields, "selectArchive", &[&first]).unwrap();
	assert_eq!(intent.archive_control, Some(key(6, 7)));
	let before = intent.clone();
	let invalid = serde_json::to_string(&local::ArchiveSelection {
		access: key(2, 1),
		control: Some(key(6, 8)),
	})
	.unwrap();
	assert!(apply(&mut intent, &mut fields, "selectArchive", &[&invalid]).is_err());
	assert_eq!(intent, before, "a refused control cannot change archive access");
	let positional = serde_json::to_string(&(
		key::<custody::ArchiveAccess>(2, 1),
		Option::<custody::FieldKey<custody::ArchiveControl>>::None,
	))
	.unwrap();
	assert!(
		apply(&mut intent, &mut fields, "selectArchive", &[&positional]).is_err(),
		"archive selection requires a JSON object"
	);
	assert_eq!(intent, before);
	let second = serde_json::to_string(&local::ArchiveSelection {
		access: key(2, 1),
		control: None,
	})
	.unwrap();
	apply(&mut intent, &mut fields, "selectArchive", &[&second]).unwrap();
	assert_eq!(intent.archive, Some(key(2, 1)));
	assert!(intent.archive_control.is_none());
	assert!(fields.archive_access(key(1, 1)).is_none());
	assert!(fields.archive_control(key(6, 7)).is_none());
	assert!(
		fields.archive_access(key(3, 1)).is_some(),
		"unselected import survives replacement"
	);
	apply(&mut intent, &mut fields, "selectArchive", &[]).unwrap();
	assert!(intent.archive.is_none() && fields.archive_access(key(2, 1)).is_none());
	let operators = serde_json::to_string(&[key::<custody::Operator>(1, 1), key(2, 1)]).unwrap();
	apply(&mut intent, &mut fields, "replaceOperationsCapabilities", &[&operators]).unwrap();
	for keys in [
		vec![key::<custody::Operator>(1, 1); 2],
		vec![key(1, 2)],
		vec![key(4, 5)],
		vec![key(1, 1); 65],
	] {
		let keys = serde_json::to_string(&keys).unwrap();
		assert!(apply(&mut intent, &mut fields, "replaceOperationsCapabilities", &[&keys]).is_err());
		assert_eq!(serde_json::to_string(&intent.operators).unwrap(), operators);
	}
	let remaining = serde_json::to_string(&[key::<custody::Operator>(2, 1)]).unwrap();
	apply(&mut intent, &mut fields, "replaceOperationsCapabilities", &[&remaining]).unwrap();
	assert!(fields.operator(key(1, 1)).is_none());
	assert!(fields.operator(key(2, 1)).is_some());
	assert!(
		fields.operator(key(3, 1)).is_some(),
		"unrelated operator import survives"
	);
	assert!(
		fields.room_access(key(1, 1)).is_some(),
		"role coordinates are independent"
	);
	assert_eq!(intent.validate(&fields), Ok(()));
}
