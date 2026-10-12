//! Application admission authority: exact allowance, atomic debit and bounded
//! retention. Injected monotonic time covers churn without sleeping.
use super::*;
fn charge(key: u64, class: Class, amount: u32) -> Charge<u64> {
	Charge { key, class, amount }
}

#[test]
fn cleanup_reserve_survives_full_tables_without_resetting_existing_debt() {
	let profile = Profile::default().with_rate(Class::Cleanup, Rate::new(2, 2));
	let mut registry = Registry::new(profile, 1);
	let mut reserve = CleanupReserve::new(Rate::new(2, 2));
	registry.admit(&[charge(1, Class::Message, 12)], 0).unwrap();
	registry
		.admit_cleanup(&[charge(2, Class::Cleanup, 1)], 0, &mut reserve)
		.unwrap();
	registry
		.admit_cleanup(&[charge(3, Class::Cleanup, 1)], 0, &mut reserve)
		.unwrap();
	assert!(matches!(
		registry.admit_cleanup(&[charge(4, Class::Cleanup, 1)], 0, &mut reserve),
		Err(Refusal::Throttled {
			class: Class::Cleanup,
			..
		})
	));
	assert_eq!(registry.len(), 1);
	assert_eq!(
		registry.admit(&[charge(2, Class::Message, 1)], 0),
		Err(Refusal::Capacity)
	);
	registry
		.admit_cleanup(&[charge(1, Class::Cleanup, 2)], 0, &mut reserve)
		.unwrap();
	// Missing ancestry cannot hide the retained subject's exhausted allowance.
	assert!(matches!(
		registry.admit_cleanup(
			&[charge(1, Class::Cleanup, 1), charge(5, Class::Cleanup, 1)],
			0,
			&mut reserve
		),
		Err(Refusal::Throttled {
			class: Class::Cleanup,
			..
		})
	));
	registry
		.admit_cleanup(&[charge(6, Class::Cleanup, 1)], 30_000, &mut reserve)
		.unwrap();
	let stats = registry.statistics();
	assert_eq!(stats.admitted, 5);
	assert_eq!(stats.refused, 3);
}

#[test]
fn failed_multidimensional_admission_consumes_nothing() {
	let mut registry = Registry::new(Profile::default().with_rate(Class::Join, Rate::new(32, 60)), 8);
	registry.admit(&[charge(1, Class::RoomJoin, 4)], 0).unwrap();
	assert!(
		registry
			.admit(&[charge(2, Class::Join, 32), charge(1, Class::RoomJoin, 1)], 0)
			.is_err()
	);
	registry.admit(&[charge(2, Class::Join, 32)], 0).unwrap();
	assert_eq!(
		registry.admit(&[charge(2, Class::Join, 1)], 0),
		Err(Refusal::Throttled {
			class: Class::Join,
			retry_ms: 1000
		})
	);
}
#[test]
fn disconnected_keys_keep_debt_and_new_keys_cannot_evict_them() {
	let mut registry = Registry::new(Profile::default(), 2);
	for key in 0..2 {
		registry.admit(&[charge(key, Class::Connection, 6)], 0).unwrap();
	}
	for key in 2..500 {
		assert_eq!(
			registry.admit(&[charge(key, Class::Connection, 1)], 1),
			Err(Refusal::Capacity)
		);
	}
	assert_eq!(registry.len(), 2);
	assert_eq!(
		registry.admit(&[charge(0, Class::Connection, 1)], 1),
		Err(Refusal::Throttled {
			class: Class::Connection,
			retry_ms: 9999
		})
	);
	registry.admit(&[charge(0, Class::Read, 1)], 1).unwrap();
	registry.admit(&[charge(500, Class::Connection, 1)], 60_000).unwrap();
	assert!(registry.len() <= 2);
}
#[test]
fn healthy_subject_and_other_classes_progress_beside_a_flood() {
	let mut registry = Registry::new(Profile::default(), 8);
	registry
		.admit(&[charge(1, Class::Message, Class::Message.default_rate().burst())], 0)
		.unwrap();
	for _ in 0..1000 {
		assert!(registry.admit(&[charge(1, Class::Message, 1)], 0).is_err());
	}
	registry
		.admit(&[charge(1, Class::Read, 1), charge(2, Class::Message, 1)], 0)
		.unwrap();
	registry.admit(&[charge(1, Class::Message, 1)], 1000).unwrap();
}
#[test]
fn repeated_charges_cannot_bypass_one_burst() {
	let mut registry = Registry::new(Profile::default(), 8);
	assert_eq!(
		registry.admit(&[charge(1, Class::Connection, 4), charge(1, Class::Connection, 4)], 0),
		Err(Refusal::TooLarge {
			class: Class::Connection
		})
	);
	assert!(registry.is_empty());
	registry.admit(&[charge(1, Class::Connection, 6)], 0).unwrap();
}
#[test]
fn retry_time_satisfies_every_dimension() {
	let mut registry = Registry::new(Profile::default(), 8);
	registry
		.admit(&[charge(1, Class::Join, 32), charge(1, Class::Connection, 6)], 0)
		.unwrap();
	let charges = [charge(1, Class::Join, 1), charge(1, Class::Connection, 1)];
	assert_eq!(
		registry.admit(&charges, 0),
		Err(Refusal::Throttled {
			class: Class::Connection,
			retry_ms: 10_000
		})
	);
	registry.admit(&charges, 10_000).unwrap();
}
#[test]
fn clock_regression_and_maximum_timestamp_do_not_create_or_overflow_credit() {
	let mut bucket = Bucket::default();
	let rate = Rate::new(6, 6);
	bucket.debit(rate, 6, 100);
	assert!(bucket.check(rate, 1, 99, Class::Connection).is_err());
	assert!(bucket.check(rate, 1, u64::MAX, Class::Connection).is_ok());
	assert_eq!(
		bucket.check(rate, 7, u64::MAX, Class::Connection),
		Err(Refusal::TooLarge {
			class: Class::Connection
		})
	);
	assert!(Profile::scaled(0).is_none());
	assert!(Profile::scaled(101).is_none());
}
#[test]
fn thirty_second_flapping_obeys_elapsed_allowance() {
	let mut registry = Registry::new(Profile::default(), 8);
	let mut admitted = 0;
	for now in (0..=30_000).step_by(1000) {
		if registry.admit(&[charge(1, Class::Connection, 1)], now).is_ok() {
			admitted += 1;
		}
		registry.admit(&[charge(2, Class::Read, 1)], now).unwrap();
	}
	assert_eq!(admitted, 9);
}

#[test]
fn steady_subject_survives_maintenance_while_idle_restored_rows_retire() {
	let mut registry = Registry::new(Profile::default(), 8);
	registry.admit(&[charge(2, Class::Message, 1)], 0).unwrap();
	for now in (1000..=100_000).step_by(1000) {
		registry.admit(&[charge(1, Class::Message, 1)], now).unwrap();
	}
	assert_eq!(registry.len(), 1);
}

#[test]
fn untrusted_retry_details_cannot_select_an_unbounded_wait() {
	use crate::failure::Failure;
	let reason = Refusal::Throttled {
		class: Class::Join,
		retry_ms: 1000,
	}
	.reason();
	assert_eq!(
		Failure::parse(&reason).unwrap().retry_advice(),
		Some(RetryAdvice {
			class: Class::Join,
			retry_ms: 1000
		})
	);
	for detail in [
		"retry-after-ms=0; scope=join",
		"retry-after-ms=60001; scope=join",
		"retry-after-ms=-1; scope=join",
		"retry-after-ms=1000; scope=unknown",
		"retry-after-ms=1000; scope=join; scope=message",
		"retry-after-ms=1000; scope=join; owner=unknown",
		"retry-after-ms=1000; scope=join; owner=session; owner=http",
	] {
		assert!(RetryAdvice::parse(detail).is_none());
	}
	let attributed = Refusal::Throttled {
		class: Class::Join,
		retry_ms: 1000,
	}
	.reason_at(Owner::Directory);
	assert_eq!(
		Failure::parse(&attributed).unwrap().retry_advice().unwrap().retry_ms,
		1000
	);
	assert!(
		Failure::parse("nick-taken: retry-after-ms=1000; scope=join")
			.unwrap()
			.retry_advice()
			.is_none()
	);
}
