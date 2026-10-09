//! Replay pressure cannot retire unresolved or privately pinned effects.
use super::{References, Source, custody, key};
use rooms_application::{
	content::session::effects,
	fields::{List, Text},
};

fn receipt(id: usize) -> custody::EffectReceipt<References> {
	custody::EffectReceipt {
		introduction: None,
		outgoing: None,
		adopted: false,
		operation: Text::new(format!("effect-{id}").into()).unwrap(),
		canonical_intent: Text::new("intent".into()).unwrap(),
		resource_generation: super::nz(1),
		source: custody::Held {
			key: key(1, 1),
			reference: Source(7),
		},
		targets: List::new(Vec::new()).unwrap(),
		outcome: custody::Outcome::Unresolved,
	}
}
pub fn run() {
	use effects::Refusal;
	let mut receipts = List::new(Vec::new()).unwrap();
	for id in 1..=custody::MAX_EFFECTS {
		effects::reserve(&mut receipts, receipt(id), |_| false).unwrap();
	}
	assert_eq!(
		effects::reserve(&mut receipts, receipt(9), |_| false),
		Err(Refusal::Capacity)
	);
	let original = receipt(1);
	assert_eq!(
		effects::settle(
			&mut receipts,
			&original.operation,
			&Source(8),
			&original.canonical_intent,
			custody::Outcome::KnownAbsent
		),
		Err(Refusal::Source)
	);
	assert_eq!(
		effects::settle(
			&mut receipts,
			&original.operation,
			&Source(7),
			&original.canonical_intent,
			custody::Outcome::KnownAbsent
		),
		Ok(true)
	);
	assert_eq!(
		effects::settle(
			&mut receipts,
			&original.operation,
			&Source(7),
			&original.canonical_intent,
			custody::Outcome::KnownAbsent
		),
		Ok(false)
	);
	assert_eq!(
		effects::settle(
			&mut receipts,
			&original.operation,
			&Source(7),
			&original.canonical_intent,
			custody::Outcome::Committed {
				result: Text::new("null".into()).unwrap(),
				retained: List::new(Vec::new()).unwrap()
			}
		),
		Err(Refusal::Settled)
	);
	assert_eq!(
		effects::reserve(&mut receipts, receipt(9), |_| true),
		Err(Refusal::Capacity)
	);
	effects::reserve(&mut receipts, receipt(9), |_| false).unwrap();
	assert!(matches!(
		effects::recover(&receipts, &original.operation, &Source(7)),
		Err(Refusal::Unknown)
	));
	let mut receipts = List::new(Vec::new()).unwrap();
	for id in 1..=custody::MAX_EFFECTS {
		effects::reserve(&mut receipts, receipt(id), |_| false).unwrap();
	}
	let first = receipt(1);
	effects::settle(
		&mut receipts,
		&first.operation,
		&Source(7),
		&first.canonical_intent,
		custody::Outcome::Committed {
			result: Text::new("result".into()).unwrap(),
			retained: List::new(vec![custody::RetainedField::RoomAccess(custody::Held {
				key: key(1, 1),
				reference: super::Room(9),
			})])
			.unwrap(),
		},
	)
	.unwrap();
	assert_eq!(
		effects::reserve(&mut receipts, receipt(9), |_| false),
		Err(Refusal::Capacity),
		"a committed capability remains recoverable until adoption"
	);
	receipts.as_mut_slice()[0].adopted = true;
	effects::reserve(&mut receipts, receipt(9), |_| false).unwrap();
	let mut receipts = List::default();
	for id in 1..=custody::MAX_EFFECTS * 2 {
		let original = receipt(id);
		effects::reserve(&mut receipts, receipt(id), |_| false).unwrap();
		effects::settle(
			&mut receipts,
			&original.operation,
			&Source(7),
			&original.canonical_intent,
			custody::Outcome::Unknown {
				reason: Text::new("observation failed".into()).unwrap(),
			},
		)
		.unwrap();
	}
	assert_eq!(
		receipts.as_slice().len(),
		custody::MAX_EFFECTS,
		"terminal diagnostics stay in a bounded replay window"
	);
	assert_eq!(
		effects::reserve(&mut receipts, receipt(99), |_| true),
		Err(Refusal::Capacity)
	);
}
