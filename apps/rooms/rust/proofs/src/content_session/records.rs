//! Payload codecs preserve typed fields and refuse mismatched page inputs.
use super::{Directory, References, Room, Source, custody, fixture, key, nz, workspace};
use rooms_application::{
	content::session::records,
	fields::{List, Text},
};
mod bridge;
mod outgoing;

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
			Retained::Line(field) => RetainedField::Line(Held {
				key: field.key,
				reference: (),
			}),
			Retained::SourceBlob(field) => RetainedField::SourceBlob(Held {
				key: field.key,
				reference: (),
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
	outgoing::run();
	bridge::run();
	terminal_refusals();
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
		introduction: Some(workspace::Introduction {
			access: key(4, 2),
			name: key(5, 3),
			callback: key(6, 4),
			opening: Text::new("opening".into()).unwrap(),
			registration: Text::new("00000000-0000-4000-8000-000000000001".into()).unwrap(),
		}),
		adopted: false,
		outgoing: None,
		operation: Text::new("operation".into()).unwrap(),
		canonical_intent: Text::new("x".repeat(60000).into()).unwrap(),
		resource_generation: nz(u64::MAX),
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
		outgoing: List::default(),
		bridges: Default::default(),
		effects: List::new(vec![receipt]).unwrap(),
	};
	let encoded = records::encode(&record).unwrap();
	graph(&encoded);
	assert_eq!(encoded.binding.resource, 41);
	assert!(encoded.workspace.len() > 1);
	assert!(encoded.effects[0].len() > 1);
	assert!(encoded.effects[0].iter().skip(1).all(|page| page.fields.is_empty()));
	let workspace: Vec<_> = encoded.workspace.iter().map(Vec::as_slice).collect();
	let decoded = records::decode(
		custody::ResourceBinding { resource: 41 },
		&workspace,
		encoded.custody.iter().map(restored).collect(),
		&encoded.provenance.iter().map(Vec::as_slice).collect::<Vec<_>>(),
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
	assert_eq!(effect.introduction, record.effects.as_slice()[0].introduction);
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
	assert_eq!(records::SCHEMAS.len(), 4);
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

fn terminal_refusals() {
	for diagnostic in [
		"rate-limited: retry-after-ms=1000; scope=message",
		"glowcap error -2: target was not admitted",
	] {
		let receipt = custody::EffectReceipt::<References> {
			introduction: None,
			operation: Text::new("refused".into()).unwrap(),
			outgoing: None,
			adopted: false,
			canonical_intent: Text::new("original intent".into()).unwrap(),
			resource_generation: nz(1),
			source: custody::Held {
				key: key(1, 1),
				reference: Source(7),
			},
			targets: List::default(),
			outcome: custody::Outcome::Refused {
				reason: Text::new(diagnostic.into()).unwrap(),
			},
		};
		let pages = records::encode_effect(&receipt).unwrap();
		let decoded = records::decode_effect(pages.iter().map(restored).collect()).unwrap();
		let custody::Outcome::Refused { reason } = decoded.outcome else {
			panic!("known absence must remain distinct from uncertainty")
		};
		assert_eq!(reason.text().as_str(), Some(diagnostic));
		assert!(!decoded.adopted);
		assert_eq!(decoded.source.reference.0, 7);
	}
}

fn graph(encoded: &records::Encoded<'_, References, i32>) {
	let input: Vec<_> = encoded
		.workspace
		.iter()
		.map(|payload| records::GraphPage {
			schema: records::WORKSPACE.id,
			version: records::WORKSPACE.version,
			payload,
			field_count: 0,
		})
		.chain(encoded.custody.iter().map(|page| records::GraphPage {
			schema: records::CUSTODY.id,
			version: records::CUSTODY.version,
			payload: &page.payload,
			field_count: page.fields.len(),
		}))
		.chain(encoded.provenance.iter().map(|payload| records::GraphPage {
			schema: records::PROVENANCE.id,
			version: records::PROVENANCE.version,
			payload,
			field_count: 0,
		}))
		.chain(encoded.effects.iter().flatten().map(|page| records::GraphPage {
			schema: records::EFFECT.id,
			version: records::EFFECT.version,
			payload: &page.payload,
			field_count: page.fields.len(),
		}))
		.collect();
	let fields: Vec<_> = encoded.custody.iter().chain(encoded.effects.iter().flatten()).collect();
	let decode = |input: &[records::GraphPage<'_>]| {
		records::decode_graph(
			custody::ResourceBinding { resource: 41 },
			input,
			|page, coordinate, index| {
				let page = page
					.checked_sub(encoded.workspace.len())
					.map(|page| {
						if page >= encoded.custody.len() {
							page - encoded.provenance.len()
						} else {
							page
						}
					})
					.and_then(|page| fields.get(page))
					.ok_or(records::Error::Fields)?;
				let field = restored(page)
					.fields
					.into_iter()
					.nth(index)
					.ok_or(records::Error::Fields)?;
				assert_eq!(field.borrowed().coordinate(), coordinate);
				Ok(field)
			},
		)
	};
	assert!(decode(&input).is_ok());
	let mut reordered = input.clone();
	reordered.swap(0, 1);
	assert!(decode(&reordered).is_err());
	assert!(decode(&input[..input.len() - 1]).is_err());
	let mut wrong_version = input.clone();
	wrong_version[1].version += 1;
	assert!(decode(&wrong_version).is_err());
	let mut missing_fields = input.clone();
	missing_fields[encoded.workspace.len()].field_count -= 1;
	assert!(decode(&missing_fields).is_err());
	let mut disguised = input.clone();
	disguised[0].field_count = 1;
	assert!(decode(&disguised).is_err());
	let mut unexpected_family = input.clone();
	unexpected_family[encoded.workspace.len()].schema = records::WORKSPACE.id;
	assert!(decode(&unexpected_family).is_err());
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
