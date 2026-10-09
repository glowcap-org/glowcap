//! Codec-valid session capacity witnesses, shared with storage consumers.
use rooms_application::{
	content::session::{custody, records, workspace},
	fields::{List, Text},
};
use std::marker::PhantomData;

pub const FIELDS: usize =
	custody::MAX_CUSTODY_FIELDS + custody::MAX_EFFECTS * (1 + custody::MAX_TARGET_FIELDS + custody::MAX_RESULT_FIELDS);
pub struct References<C>(PhantomData<C>);

macro_rules! roles {
	($($role:ident),*) => {
		impl<C> custody::References for References<C> { $(type $role = C;)* }
		pub fn field<C>(role: custody::Role, slot: u64, reference: C) -> custody::RetainedField<References<C>> {
			match role { $(custody::Role::$role => custody::RetainedField::$role(custody::Held {
				key: key(slot), reference,
			}),)* }
		}
		pub fn reference<'a, C>(field: &custody::Retained<'a, References<C>>) -> &'a C {
			match field { $(custody::Retained::$role(held) => &held.reference,)* }
		}
	};
}
roles!(
	SessionAccess,
	SessionControl,
	RoomAccess,
	DirectoryAccess,
	DirectAccess,
	DirectInbox,
	ArchiveAccess,
	Operator,
	Operations,
	IrcConnection,
	Offer,
	AcceptedAccess,
	RoomControl,
	ArchiveControl,
	CreationReceipt,
	PublicationLease,
	RoomSeat,
	RoomTopic,
	RoomInbox,
	RoomFiles,
	Line,
	DirectoryName,
	DirectoryInbox,
	SourceBlob
);
fn key<K>(slot: u64) -> custody::FieldKey<K> {
	custody::FieldKey::new(slot.try_into().unwrap(), u64::MAX.try_into().unwrap())
}

#[cfg(test)]
#[test]
fn aggregate_custody_admission_survives_role_growth_and_exact_removal() {
	let mut held = custody::Custody::<References<()>>::default();
	for &role in custody::Role::ALL {
		for slot in 1..=custody::MAX_FIELDS_PER_ROLE as u64 {
			if held.len() == custody::MAX_CUSTODY_FIELDS {
				break;
			}
			held.insert(field(role, slot, ())).unwrap();
		}
	}
	assert_eq!(held.len(), held.fields().count());
	assert_eq!(
		held.insert(field(custody::Role::RoomSeat, 1, ())),
		Err(custody::Refusal::Capacity)
	);
	let coordinate = custody::Coordinate {
		role: custody::Role::RoomAccess,
		key: key(1),
	};
	assert!(held.remove(coordinate).is_some());
	assert!(held.remove(coordinate).is_none());
	held.insert(field(custody::Role::RoomSeat, 1, ())).unwrap();
	assert_eq!(held.len(), custody::MAX_CUSTODY_FIELDS);
	assert_eq!(held.len(), held.fields().count());
}
pub fn intent() -> workspace::Intent {
	workspace::Intent::decode(
		&serde_json::json!({
			"version": 1, "directories": [], "conversations": [], "invitations": [], "active": null,
			"standing": "", "ignored": [], "keepHistory": true, "connection": "relay", "archive": null,
			"archiveControl": null, "operators": [], "peering": []
		})
		.to_string(),
	)
	.unwrap()
}
pub fn candidate<C>(revision: u64, mut next: impl FnMut() -> C) -> workspace::Record<References<C>, ()> {
	let mut custody = custody::Custody::default();
	for &role in custody::Role::ALL {
		for slot in 1..=custody::MAX_FIELDS_PER_ROLE as u64 {
			if custody.len() == custody::MAX_CUSTODY_FIELDS {
				break;
			}
			custody.insert(field(role, slot, next())).unwrap();
		}
	}
	let mut intent = intent();
	intent.standing = Text::new(format!("revision-{revision}").into()).unwrap();
	// Eight workspace fragments plus 48 custody and eight effect pages fill
	// the graph. Every text remains within its UTF-16 field allowance.
	intent.ignored = List::new(vec![Text::new("é".repeat(4096).into()).unwrap(); 44]).unwrap();
	let effects = (0..custody::MAX_EFFECTS)
		.map(|index| custody::EffectReceipt {
			introduction: None,
			outgoing: None,
			adopted: false,
			operation: Text::new(format!("effect-{index}").into()).unwrap(),
			canonical_intent: Text::new(format!("{revision}{}", "x".repeat(40000)).into()).unwrap(),
			resource_generation: u64::MAX.try_into().unwrap(),
			source: custody::Held {
				key: key(1),
				reference: next(),
			},
			targets: List::new(
				(1..=custody::MAX_TARGET_FIELDS)
					.map(|slot| field(custody::Role::RoomAccess, slot as u64, next()))
					.collect(),
			)
			.unwrap(),
			outcome: custody::Outcome::Committed {
				result: Text::new("applied".into()).unwrap(),
				retained: List::new(
					(1..=custody::MAX_RESULT_FIELDS)
						.map(|slot| field(custody::Role::ArchiveAccess, slot as u64, next()))
						.collect(),
				)
				.unwrap(),
			},
		})
		.collect();
	workspace::Record {
		binding: custody::ResourceBinding { resource: () },
		intent,
		custody,
		outgoing: List::default(),
		bridges: Default::default(),
		effects: List::new(effects).unwrap(),
	}
}
pub fn payload_bytes<C>(encoded: &records::Encoded<'_, References<C>, ()>) -> usize {
	encoded.workspace.iter().map(Vec::len).sum::<usize>()
		+ encoded.provenance.iter().map(Vec::len).sum::<usize>()
		+ encoded
			.custody
			.iter()
			.chain(encoded.effects.iter().flatten())
			.map(|page| page.payload.len())
			.sum::<usize>()
}
fn restored<C: Clone>(page: &records::Page<'_, References<C>>) -> records::RestoredPage<References<C>> {
	records::RestoredPage {
		payload: page.payload.clone(),
		fields: page
			.fields
			.iter()
			.map(|held| {
				let coordinate = held.coordinate();
				field(coordinate.role, coordinate.key.slot().get(), reference(held).clone())
			})
			.collect(),
	}
}
fn round_trip<C: Clone>(encoded: &records::Encoded<'_, References<C>, ()>) -> workspace::Record<References<C>, ()> {
	records::decode(
		custody::ResourceBinding { resource: () },
		&encoded.workspace.iter().map(Vec::as_slice).collect::<Vec<_>>(),
		encoded.custody.iter().map(restored).collect(),
		&encoded.provenance.iter().map(Vec::as_slice).collect::<Vec<_>>(),
		encoded
			.effects
			.iter()
			.map(|pages| pages.iter().map(restored).collect())
			.collect(),
	)
	.unwrap()
}
pub fn run() {
	let mut identity = 0usize;
	let record = candidate(1, || {
		identity += 1;
		identity
	});
	assert_eq!(identity, FIELDS);
	let encoded = records::encode(&record).unwrap();
	assert_eq!(encoded.workspace.len(), 8);
	assert_eq!(encoded.custody.len(), 48);
	assert!(encoded.effects.iter().all(|pages| pages.len() == 1));
	assert_eq!(
		encoded.workspace.len() + encoded.custody.len() + encoded.provenance.len() + encoded.effects.len(),
		records::MAX_PAGES
	);
	assert!(payload_bytes(&encoded) < custody::MAX_AUTHORITY_BYTES);
	let decoded = round_trip(&encoded);
	assert_eq!(decoded.intent, record.intent);
	let decoded = records::encode(&decoded).unwrap();
	let original = encoded.custody.iter().chain(encoded.effects.iter().flatten());
	let restored = decoded.custody.iter().chain(decoded.effects.iter().flatten());
	let mut count = 0;
	for (original, restored) in original.zip(restored) {
		assert_eq!(original.payload, restored.payload);
		assert_eq!(original.fields.len(), restored.fields.len());
		for (original, restored) in original.fields.iter().zip(&restored.fields) {
			assert_eq!(original.coordinate(), restored.coordinate());
			assert_eq!(reference(original), reference(restored));
			count += 1;
		}
	}
	assert_eq!(count, FIELDS);
	payload_boundary();
}
fn payload_boundary() {
	// A separate accepted shape reaches the aggregate byte bound. Filling all
	// roles reserves 48 small coordinate pages, preventing byte saturation.
	let mut record = workspace::Record::<References<usize>, ()> {
		binding: custody::ResourceBinding { resource: () },
		intent: intent(),
		custody: custody::Custody::default(),
		outgoing: List::default(),
		bridges: Default::default(),
		effects: List::new(Vec::new()).unwrap(),
	};
	let mut padding = vec![Text::new("x".repeat(4096).into()).unwrap(); 255];
	padding.push(Text::new("".into()).unwrap());
	record.intent.ignored = List::new(padding.clone()).unwrap();
	let bytes = payload_bytes(&records::encode(&record).unwrap());
	let remaining = custody::MAX_AUTHORITY_BYTES - bytes;
	padding[255] = Text::new("x".repeat(remaining).into()).unwrap();
	record.intent.ignored = List::new(padding.clone()).unwrap();
	let encoded = records::encode(&record).unwrap();
	assert_eq!(payload_bytes(&encoded), custody::MAX_AUTHORITY_BYTES);
	assert_eq!(round_trip(&encoded).intent, record.intent);
	padding[255] = Text::new("x".repeat(remaining + 1).into()).unwrap();
	record.intent.ignored = List::new(padding).unwrap();
	assert!(matches!(records::encode(&record), Err(records::Error::Capacity)));
}
