//! Pending sender capacity survives codec round trips and concurrent imports.
use super::*;
use rooms_application::content::session::outgoing::{Origin, Update};

fn update() -> Update {
	Update {
		origin: Origin {
			line: key(1, 2),
			source: key(1, 2),
			route: key(1, 1),
			id: rooms_application::fields::SafeInteger::new(2).unwrap(),
			generation: Text::new("incarnation:sent".into()).unwrap(),
			directory: workspace::Id::new("directory".into()).unwrap(),
			conversation: workspace::Id::new("conversation".into()).unwrap(),
			from: Text::new("sender".into()).unwrap(),
			previews: Default::default(),
			files: List::default(),
		},
		existing: false,
		files: List::default(),
	}
}
pub(super) fn run() {
	diagnostic_reservation();
	let mut custody = custody::Custody::<References>::default();
	custody.set_next_identity(rooms_application::fields::SafeInteger::new(4).unwrap());
	custody
		.insert_directory_access(custody::Held {
			key: key(1, 1),
			reference: Directory,
		})
		.unwrap();
	let mut raw = fixture();
	raw["conversations"][0]["access"] = serde_json::Value::Null;
	raw["conversations"][0]["reconnect"] = "manual".into();
	let receipt = custody::EffectReceipt {
		introduction: None,
		operation: Text::new("pending-sender".into()).unwrap(),
		outgoing: Some(update()),
		adopted: false,
		canonical_intent: Text::new("original intent".into()).unwrap(),
		resource_generation: nz(1),
		source: custody::Held {
			key: key(1, 1),
			reference: Source(7),
		},
		targets: List::default(),
		outcome: custody::Outcome::Unresolved,
	};
	let mut record = workspace::Record {
		binding: custody::ResourceBinding { resource: 41 },
		intent: workspace::Intent::decode(&raw.to_string()).unwrap(),
		custody,
		outgoing: List::default(),
		bridges: Default::default(),
		effects: List::new(vec![receipt]).unwrap(),
	};
	let encoded = records::encode(&record).unwrap();
	let restored_effect = records::decode_effect(encoded.effects[0].iter().map(restored).collect()).unwrap();
	assert_eq!(
		restored_effect.outgoing,
		Some(update()),
		"private reservation round trips with its receipt"
	);
	drop(encoded);
	record
		.custody
		.set_next_identity(rooms_application::fields::SafeInteger::new(2).unwrap());
	assert!(
		matches!(records::encode(&record), Err(records::Error::Fields)),
		"saved counter must fence every pending generation"
	);
	record
		.custody
		.set_next_identity(rooms_application::fields::SafeInteger::new(4).unwrap());
	// A new import cannot occupy a pending slot, even at a different generation.
	record
		.custody
		.insert_line(custody::Held {
			key: key(1, 99),
			reference: (),
		})
		.unwrap();
	assert!(matches!(records::encode(&record), Err(records::Error::Fields)));
	record.custody.remove_line(key(1, 99)).unwrap();
	for slot in 2..=custody::MAX_FIELDS_PER_ROLE as u64 {
		record
			.custody
			.insert_line(custody::Held {
				key: key(slot, 1),
				reference: (),
			})
			.unwrap();
	}
	assert!(
		records::encode(&record).is_ok(),
		"one pending line fits beside 255 held lines"
	);
	let mut second = update();
	second.origin.line = key(257, 3);
	second.origin.source = key(2, 3);
	assert!(
		record
			.effects
			.try_push(custody::EffectReceipt {
				introduction: None,
				operation: Text::new("second-sender".into()).unwrap(),
				outgoing: Some(second),
				adopted: false,
				canonical_intent: Text::new("second intent".into()).unwrap(),
				resource_generation: nz(1),
				source: custody::Held {
					key: key(1, 1),
					reference: Source(7),
				},
				targets: List::default(),
				outcome: custody::Outcome::Unresolved,
			})
			.is_ok()
	);
	assert!(
		matches!(records::encode(&record), Err(records::Error::Capacity)),
		"concurrent pending posts share the same role limit"
	);
	record.effects.as_mut_slice()[1].outcome = custody::Outcome::KnownAbsent;
	assert!(
		records::encode(&record).is_ok(),
		"known absence releases its reservation"
	);
	// Payload pressure can fit the input graph but must leave room for the result.
	let page = vec![0; records::PAGE_BYTES];
	assert!(records::check_budget(core::iter::repeat_n(page.as_slice(), 21)).is_ok());
	assert!(matches!(
		records::check_reservations(&record, core::iter::repeat_n(page.as_slice(), 21)),
		Err(records::Error::Capacity)
	));
	// Once settled, private provenance uses exact strong custody and survives
	// independent receipt eviction. Workspace export contains none of it.
	record.effects = List::default();
	record
		.custody
		.insert_line(custody::Held {
			key: key(1, 2),
			reference: (),
		})
		.unwrap();
	record
		.custody
		.insert_session_access(custody::Held {
			key: key(1, 2),
			reference: Source(9),
		})
		.unwrap();
	assert!(record.outgoing.try_push(update().origin.clone()).is_ok());
	let encoded = records::encode(&record).unwrap();
	let pages: Vec<_> = encoded
		.workspace
		.iter()
		.map(|payload| records::GraphPage {
			schema: records::WORKSPACE.id,
			version: 1,
			payload,
			field_count: 0,
		})
		.chain(encoded.custody.iter().map(|page| records::GraphPage {
			schema: records::CUSTODY.id,
			version: 1,
			payload: &page.payload,
			field_count: page.fields.len(),
		}))
		.chain(encoded.provenance.iter().map(|payload| records::GraphPage {
			schema: records::PROVENANCE.id,
			version: 1,
			payload,
			field_count: 0,
		}))
		.collect();
	let graph = records::decode_graph(
		custody::ResourceBinding { resource: 41 },
		&pages,
		|page, coordinate, index| {
			let field = restored(&encoded.custody[page - encoded.workspace.len()])
				.fields
				.into_iter()
				.nth(index)
				.unwrap();
			assert_eq!(coordinate, field.borrowed().coordinate());
			Ok(field)
		},
	)
	.unwrap();
	assert_eq!(graph.outgoing.as_slice(), &[update().origin]);
	let decoded = records::decode(
		custody::ResourceBinding { resource: 41 },
		&encoded.workspace.iter().map(Vec::as_slice).collect::<Vec<_>>(),
		encoded.custody.iter().map(restored).collect(),
		&encoded.provenance.iter().map(Vec::as_slice).collect::<Vec<_>>(),
		Vec::new(),
	)
	.unwrap();
	assert_eq!(decoded.outgoing.as_slice(), &[update().origin]);
	assert!(
		!serde_json::to_string(&decoded.intent)
			.unwrap()
			.contains("incarnation:sent")
	);
	drop(encoded);
	record.custody.remove_line(key(1, 2)).unwrap();
	assert!(
		matches!(records::encode(&record), Err(records::Error::Fields)),
		"payload provenance cannot substitute for missing line custody"
	);
}

fn diagnostic_reservation() {
	for intent in ["original intent", "{\"bridge\":{}}"] {
		let receipt: custody::EffectReceipt<References> = custody::EffectReceipt {
			introduction: None,
			operation: Text::new("pending-diagnostic".into()).unwrap(),
			outgoing: None,
			adopted: false,
			canonical_intent: Text::new(intent.into()).unwrap(),
			resource_generation: nz(1),
			source: custody::Held {
				key: key(1, 1),
				reference: Source(7),
			},
			targets: List::default(),
			outcome: custody::Outcome::Unresolved,
		};
		let mut record = workspace::Record {
			binding: custody::ResourceBinding { resource: 41 },
			intent: workspace::Intent::decode(&fixture().to_string()).unwrap(),
			custody: Default::default(),
			outgoing: Default::default(),
			bridges: Default::default(),
			effects: List::new(vec![receipt]).unwrap(),
		};
		let page = vec![0; records::PAGE_BYTES];
		assert!(records::check_budget(core::iter::repeat_n(page.as_slice(), 21)).is_ok());
		assert!(
			matches!(
				records::check_reservations(&record, core::iter::repeat_n(page.as_slice(), 21)),
				Err(records::Error::Capacity)
			),
			"every pending effect leaves physical space for its bounded terminal diagnostic"
		);
		record.effects.as_mut_slice()[0].outcome = custody::Outcome::KnownAbsent;
		assert!(records::check_reservations(&record, core::iter::repeat_n(page.as_slice(), 21)).is_ok());
	}
}
