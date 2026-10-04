//! Payload codecs preserve typed fields and refuse mismatched page inputs.
use super::{Directory, References, Room, Source, custody, fixture, key, nz, workspace};
use rooms_application::{
	content::session::records,
	fields::{List, Text},
};

fn restored(page: &records::Page<'_, References>) -> records::RestoredPage<References> {
	use custody::{Held, Retained, RetainedField};
	let fields = page
		.fields
		.iter()
		.map(|field| match field {
			Retained::SessionAccess(field) => RetainedField::SessionAccess(Held {
				key: field.key,
				reference: Source(field.reference.0),
			}),
			Retained::RoomAccess(field) => RetainedField::RoomAccess(Held {
				key: field.key,
				reference: Room(field.reference.0),
			}),
			Retained::DirectoryAccess(field) => RetainedField::DirectoryAccess(Held {
				key: field.key,
				reference: Directory,
			}),
			_ => panic!("fixture only restores its declared roles"),
		})
		.collect();
	records::RestoredPage {
		payload: page.payload.clone(),
		fields,
	}
}
pub fn run() {
	let mut custody = custody::Custody::<References>::default();
	custody
		.insert_directory_access(custody::Held {
			key: key(1, 1),
			reference: Directory,
		})
		.unwrap();
	custody
		.insert_room_access(custody::Held {
			key: key(1, 2),
			reference: Room(8),
		})
		.unwrap();
	let mut intent = fixture();
	intent["conversations"][0]["access"] = serde_json::to_value(key::<custody::RoomAccess>(1, 2)).unwrap();
	intent["ignored"] = serde_json::json!(vec!["é".repeat(1024); 64]);
	let receipt = custody::EffectReceipt::<References> {
		operation: Text::new("operation".into()).unwrap(),
		canonical_intent: Text::new("x".repeat(60000).into()).unwrap(),
		attachment_generation: nz(u64::MAX),
		source: custody::Held {
			key: key(1, 1),
			reference: Source(3),
		},
		targets: List::new(vec![custody::RetainedField::RoomAccess(custody::Held {
			key: key(1, 1),
			reference: Room(7),
		})])
		.unwrap(),
		outcome: custody::Outcome::Committed {
			result: Text::new("committed".into()).unwrap(),
			retained: List::new(vec![custody::RetainedField::RoomAccess(custody::Held {
				key: key(2, 1),
				reference: Room(9),
			})])
			.unwrap(),
		},
	};
	let record = workspace::Record {
		binding: custody::ResourceBinding { resource: 41 },
		intent: workspace::Intent::decode(&intent.to_string()).unwrap(),
		custody,
		effects: List::new(vec![receipt]).unwrap(),
	};
	let encoded = records::encode(&record).unwrap();
	assert_eq!(encoded.binding.resource, 41);
	assert!(encoded.workspace.len() > 1);
	assert!(encoded.effects[0].len() > 1);
	assert!(encoded.effects[0].iter().skip(1).all(|page| page.fields.is_empty()));
	let workspace: Vec<_> = encoded.workspace.iter().map(Vec::as_slice).collect();
	let decoded = records::decode(
		custody::ResourceBinding { resource: 41 },
		&workspace,
		encoded.custody.iter().map(restored).collect(),
		encoded
			.effects
			.iter()
			.map(|pages| pages.iter().map(restored).collect())
			.collect(),
	)
	.unwrap();
	assert_eq!(decoded.intent, record.intent);
	assert_eq!(decoded.custody.room_access(key(1, 2)).unwrap().reference.0, 8);
	assert!(decoded.custody.room_access(key(1, 1)).is_none());
	let effect = &decoded.effects.as_slice()[0];
	assert_eq!(effect.source.reference.0, 3);
	let custody::RetainedField::RoomAccess(target) = &effect.targets.as_slice()[0] else {
		panic!("original target")
	};
	assert_eq!(target.reference.0, 7);
	let custody::Outcome::Committed { result, retained } = &effect.outcome else {
		panic!("committed result")
	};
	assert_eq!(result.text().as_str(), Some("committed"));
	let custody::RetainedField::RoomAccess(result) = &retained.as_slice()[0] else {
		panic!("original result")
	};
	assert_eq!(result.reference.0, 9);
	let mut missing = restored(&encoded.custody[0]);
	missing.fields.clear();
	assert!(matches!(
		records::decode_custody(vec![missing]),
		Err(records::Error::Fields)
	));
	let mut wrong = restored(&encoded.custody[0]);
	let custody::RetainedField::RoomAccess(field) = &mut wrong.fields[0] else {
		panic!("room is first retained role")
	};
	field.key = key(1, 3);
	assert!(matches!(
		records::decode_custody(vec![wrong]),
		Err(records::Error::Fields)
	));
	let mut reordered = workspace.clone();
	reordered.swap(0, 1);
	assert!(matches!(
		records::decode_workspace(&reordered),
		Err(records::Error::Format)
	));
	assert!(records::decode_workspace(&workspace[..workspace.len() - 1]).is_err());
	let mut unknown = encoded.workspace[0].clone();
	unknown[9] = 2;
	let mut changed = workspace.clone();
	changed[0] = &unknown;
	assert!(records::decode_workspace(&changed).is_err());
	let oversized = vec![0; records::PAGE_BYTES + 1];
	assert!(matches!(
		records::check_budget([oversized.as_slice()]),
		Err(records::Error::Capacity)
	));
	let page = vec![0; records::PAGE_BYTES];
	assert!(records::check_budget(core::iter::repeat_n(page.as_slice(), 22)).is_err());
	assert!(records::check_budget(core::iter::repeat_n(&[][..], records::MAX_PAGES + 1)).is_err());
	assert_eq!(records::SCHEMAS.len(), 3);
	assert!(records::SCHEMAS.iter().all(|schema| schema.version
		== u32::from(rooms_application::content::session::VERSION)
		&& schema.max_payload == records::PAGE_BYTES
		&& schema.max_payload + schema.max_edges * 64 < 64 * 1024));
	let mut full = custody::Custody::<References>::default();
	for i in 1..=custody::MAX_FIELDS_PER_ROLE as u64 {
		full.insert_room_access(custody::Held {
			key: key(i, 1),
			reference: Room(i),
		})
		.unwrap();
	}
	let pages = records::encode_custody(&full).unwrap();
	assert_eq!(
		pages.len(),
		custody::MAX_FIELDS_PER_ROLE.div_ceil(records::FIELDS_PER_PAGE)
	);
	let restored = records::decode_custody(pages.iter().map(restored).collect()).unwrap();
	assert_eq!(restored.room_access(key(256, 1)).unwrap().reference.0, 256);
	#[cfg(not(target_arch = "wasm32"))]
	register_family();
}

#[cfg(not(target_arch = "wasm32"))]
fn register_family() {
	use glowcap::loam::{Limits, Schema, Store};
	let nonce = std::time::SystemTime::now()
		.duration_since(std::time::UNIX_EPOCH)
		.unwrap()
		.as_nanos();
	let path = std::env::temp_dir().join(format!("rooms-records-{}-{nonce:x}", std::process::id()));
	std::fs::create_dir(&path).unwrap();
	let schemas: Vec<_> = records::SCHEMAS
		.iter()
		.map(|schema| Schema {
			id: schema.id,
			version: schema.version,
			max_payload: schema.max_payload,
			max_edges: schema.max_edges,
		})
		.collect();
	let mut store = Store::open(&path, [45; 16], true, 256 * 1024 * 1024, &schemas, Limits::default()).unwrap();
	store.close().unwrap();
	drop(store);
	std::fs::remove_dir_all(path).unwrap();
}
