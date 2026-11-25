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
		disposition: custody::Disposition::Held,
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
	receipts.as_mut_slice()[0].disposition = custody::Disposition::Adopted;
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
	released();
}

/// A release never deletes a receipt: it settles an unresolved one as given up
/// and forfeits an unadopted result, and only the replay window's ordinary
/// eviction removes it.
fn released() {
	use effects::Refusal;
	let release = |receipts: &mut custody::EffectReceipts<References>, id: usize, running: bool| {
		let original = receipt(id);
		effects::release(
			receipts,
			&original.operation,
			&Source(7),
			&original.canonical_intent,
			running,
		)
	};
	// The receipt's disposition and its outcome, named by the word
	// `effect-status` would answer and, when unknown, whether it was released.
	let find = |receipts: &custody::EffectReceipts<References>, id: usize| {
		effects::recover(receipts, &receipt(id).operation, &Source(7)).map(|receipt| {
			let outcome = match &receipt.outcome {
				custody::Outcome::Unresolved => "unresolved",
				custody::Outcome::Unknown { reason } if reason.text().as_str() == Some(effects::RELEASED_UNKNOWN) => {
					"released unknown"
				}
				custody::Outcome::Unknown { .. } => "unknown",
				custody::Outcome::KnownAbsent | custody::Outcome::Refused { .. } => "unsent",
				custody::Outcome::Committed { .. } => "committed",
			};
			(receipt.disposition, outcome)
		})
	};
	// A running executor keeps its receipt as it is, because it would settle a
	// receipt its source gave up.
	let mut receipts = List::default();
	effects::reserve(&mut receipts, receipt(1), |_| false).unwrap();
	assert_eq!(release(&mut receipts, 1, true), Ok(effects::Released::Running));
	assert_eq!(effects::Released::Running.answer(), effects::Release::Running);
	assert_eq!(find(&receipts, 1), Ok((custody::Disposition::Held, "unresolved")));
	assert!(!effects::holds_place(&receipts.as_slice()[0], true));
	assert!(effects::holds_place(&receipts.as_slice()[0], false));
	// With no running executor, the unresolved receipt settles as released and
	// stays, so it frees its place and answers for its operation.
	assert_eq!(release(&mut receipts, 1, false), Ok(effects::Released::Now));
	assert_eq!(effects::Released::Now.answer(), effects::Release::Released);
	assert_eq!(
		find(&receipts, 1),
		Ok((custody::Disposition::Released, "released unknown"))
	);
	assert!(!effects::holds_place(&receipts.as_slice()[0], false));
	assert_eq!(
		effects::reserve(&mut receipts, receipt(1), |_| false),
		Err(Refusal::Unresolved),
		"a released operation is never reserved again while its receipt is held"
	);
	// A second release changes nothing.
	assert_eq!(release(&mut receipts, 1, false), Ok(effects::Released::Before));
	assert_eq!(effects::Released::Before.answer(), effects::Release::Released);
	// A late result cannot overwrite the released outcome.
	let original = receipt(1);
	assert_eq!(
		effects::settle(
			&mut receipts,
			&original.operation,
			&Source(7),
			&original.canonical_intent,
			custody::Outcome::Committed {
				result: Text::new("late".into()).unwrap(),
				retained: List::new(Vec::new()).unwrap()
			}
		),
		Err(Refusal::Settled)
	);
	assert_eq!(
		find(&receipts, 1),
		Ok((custody::Disposition::Released, "released unknown"))
	);
	// Filling the window evicts settled receipts, the released one among
	// them, and that eviction alone frees its id.
	let mut receipts = List::default();
	for id in 1..=custody::MAX_EFFECTS {
		effects::reserve(&mut receipts, receipt(id), |_| false).unwrap();
	}
	assert_eq!(release(&mut receipts, 2, false), Ok(effects::Released::Now));
	let first = receipt(1);
	effects::settle(
		&mut receipts,
		&first.operation,
		&Source(7),
		&first.canonical_intent,
		custody::Outcome::KnownAbsent,
	)
	.unwrap();
	effects::reserve(&mut receipts, receipt(9), |_| false).unwrap();
	assert_eq!(
		find(&receipts, 1),
		Err(Refusal::Unknown),
		"the oldest settled receipt goes first"
	);
	assert!(find(&receipts, 2).is_ok(), "the released receipt waits its turn");
	effects::reserve(&mut receipts, receipt(10), |_| false).unwrap();
	assert_eq!(find(&receipts, 2), Err(Refusal::Unknown), "then the released one goes");
	assert_eq!(
		effects::reserve(&mut receipts, receipt(11), |_| false),
		Err(Refusal::Capacity),
		"every place left is unresolved"
	);
	// A receipt whose outcome is unknown outlasts newer ones whose outcome is
	// known, because only its sender cannot tell whether the request ran.
	let mut receipts = List::default();
	for id in 1..=custody::MAX_EFFECTS {
		effects::reserve(&mut receipts, receipt(id), |_| false).unwrap();
	}
	for (id, outcome) in [
		(
			1,
			custody::Outcome::Unknown {
				reason: Text::new("answer lost".into()).unwrap(),
			},
		),
		(2, custody::Outcome::KnownAbsent),
	] {
		let original = receipt(id);
		effects::settle(
			&mut receipts,
			&original.operation,
			&Source(7),
			&original.canonical_intent,
			outcome,
		)
		.unwrap();
	}
	effects::reserve(&mut receipts, receipt(9), |_| false).unwrap();
	assert_eq!(
		find(&receipts, 2),
		Err(Refusal::Unknown),
		"the known outcome goes first"
	);
	assert_eq!(find(&receipts, 1), Ok((custody::Disposition::Held, "unknown")));
	effects::reserve(&mut receipts, receipt(10), |_| false).unwrap();
	assert_eq!(
		find(&receipts, 1),
		Err(Refusal::Unknown),
		"an unknown outcome goes when no known one can"
	);
	// A result awaiting adoption is forfeited: its retained fields are freed,
	// it no longer holds its place, and nothing can adopt it.
	let mut receipts = List::default();
	for id in 1..=custody::MAX_EFFECTS {
		effects::reserve(&mut receipts, receipt(id), |_| false).unwrap();
	}
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
	assert!(effects::awaits_adoption(&receipts.as_slice()[0]));
	assert_eq!(release(&mut receipts, 1, false), Ok(effects::Released::Now));
	let forfeited = &receipts.as_slice()[0];
	assert_eq!(forfeited.disposition, custody::Disposition::Released);
	assert!(matches!(&forfeited.outcome, custody::Outcome::Committed { retained, .. } if retained.is_empty()));
	assert!(!effects::awaits_adoption(forfeited));
	assert!(!effects::holds_place(forfeited, false));
	effects::reserve(&mut receipts, receipt(9), |_| false).unwrap();
	assert_eq!(
		find(&receipts, 1),
		Err(Refusal::Unknown),
		"a forfeited result leaves by eviction"
	);
	// An adopted result is the workspace's: a release changes nothing in the
	// receipt and answers kept, whether or not an executor is said to run.
	let mut receipts = List::default();
	effects::reserve(&mut receipts, receipt(1), |_| false).unwrap();
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
	receipts.as_mut_slice()[0].disposition = custody::Disposition::Adopted;
	for running in [false, true] {
		assert_eq!(release(&mut receipts, 1, running), Ok(effects::Released::Kept));
		let kept = &receipts.as_slice()[0];
		assert_eq!(kept.disposition, custody::Disposition::Adopted);
		assert!(
			matches!(&kept.outcome, custody::Outcome::Committed { retained, .. } if retained.as_slice().len() == 1)
		);
		assert!(!effects::keeps_place(kept));
	}
	assert_eq!(effects::Released::Kept.answer(), effects::Release::Kept);
}
