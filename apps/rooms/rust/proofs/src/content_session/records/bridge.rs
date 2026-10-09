//! Bridge witnesses retain exact authority, reject secret payloads, and export
//! no declaration or credential identity into portable workspace intent.
use super::*;
use rooms_application::content::session::bridge::{Intent, Witness};
use rooms_application::fields::SafeInteger;

pub(super) fn run() {
	let mut custody = custody::Custody::<References>::default();
	custody.set_next_identity(SafeInteger::new(3).unwrap());
	custody
		.insert_directory_access(custody::Held {
			key: key(1, 1),
			reference: Directory,
		})
		.unwrap();
	custody
		.insert_room_access(custody::Held {
			key: key(1, 1),
			reference: Room(9),
		})
		.unwrap();
	custody
		.insert_session_access(custody::Held {
			key: key(1, 1),
			reference: Source(7),
		})
		.unwrap();
	let form = rooms_application::bridge::Form::decode(
		&serde_json::json!({
			"scope":"original-form", "title":"Identity", "said":"",
			"fields":[
				{"kind":"text","id":"name","label":"Name","required":false},
				{"kind":"secret","id":"password","label":"Password","required":false}
			],
			"actions":[{"id":"apply","label":"Apply","busyLabel":"Applying","tone":"primary","remembered":true}]
		})
		.to_string(),
	)
	.unwrap();
	let witness = Witness {
		id: SafeInteger::new(2).unwrap(),
		operation: Text::new("bridge-operation".into()).unwrap(),
		room: Text::new("conversation".into()).unwrap(),
		source: key(1, 1),
		selection: Some(custody::Coordinate {
			role: custody::Role::RoomAccess,
			key: key(1, 1),
		}),
		access: Some(custody::Coordinate {
			role: custody::Role::RoomAccess,
			key: key(1, 1),
		}),
		intent: Intent {
			declaration: form,
			action: rooms_application::bridge::Id::new("apply".into()).unwrap(),
			answers: rooms_application::bridge::Answers::decode("{\"name\":\"sender\"}").unwrap(),
		},
		credentials: Some(serde_json::from_str("\"0123456789abcdef0123456789abcdef\"").unwrap()),
		applied: false,
	};
	let mut record = workspace::Record {
		binding: custody::ResourceBinding { resource: 41 },
		intent: workspace::Intent::decode(&fixture().to_string()).unwrap(),
		custody,
		outgoing: List::default(),
		bridges: List::new(vec![witness.clone()]).unwrap(),
		effects: List::default(),
	};
	let encoded = records::encode(&record).unwrap();
	assert!(!encoded.provenance.is_empty());
	let decoded = records::decode(
		custody::ResourceBinding { resource: 41 },
		&encoded.workspace.iter().map(Vec::as_slice).collect::<Vec<_>>(),
		encoded.custody.iter().map(restored).collect(),
		&encoded.provenance.iter().map(Vec::as_slice).collect::<Vec<_>>(),
		Vec::new(),
	)
	.unwrap();
	assert!(decoded.bridges.as_slice() == [witness]);
	let exported = serde_json::to_string(&record.intent).unwrap();
	assert!(!exported.contains("original-form"));
	assert!(!exported.contains("0123456789abcdef"));
	drop(encoded);
	record.bridges.as_mut_slice()[0]
		.intent
		.answers
		.insert("password".into(), "never store this secret".into())
		.unwrap();
	assert!(matches!(records::encode(&record), Err(records::Error::Fields)));
	record.bridges.as_mut_slice()[0].intent.answers = Default::default();
	record.custody.remove_room_access(key(1, 1)).unwrap();
	assert!(matches!(records::encode(&record), Err(records::Error::Fields)));
}
