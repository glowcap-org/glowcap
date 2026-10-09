//! Sender leases protect exact backing before the first read; retirement wins.
use super::*;

pub(super) fn run() {
	repeatable();
	let mut pool = Sources::default();
	let held: Vec<_> = (0..4).map(|_| retain(&mut pool, MAX_FILE_BYTES, ())).collect();
	let lease = held[0].lease();
	let other_lease = held[0].lease();
	// A whole-batch refusal cannot partially expire an unrelated sibling.
	assert!(matches!(
		pool.retain((0..4).map(|_| (description(MAX_FILE_BYTES), ())).collect()),
		Err(Error::Capacity)
	));
	assert!(held[1].read(0, 1).unwrap().is_some());
	let next = retain(&mut pool, MAX_FILE_BYTES, ());
	assert!(matches!(held[1].read(0, 1), Err(Error::Expired)));
	assert!(lease.blob().read(0, 1).unwrap().is_some());
	assert_eq!(pool.usage().bytes, sources::MAX_BYTES);
	drop(lease);
	let _next = retain(&mut pool, MAX_FILE_BYTES, ());
	assert!(
		other_lease.blob().read(0, 1).unwrap().is_some(),
		"one remaining lease still pins the original source"
	);
	let read = other_lease.blob().read(0, 1).unwrap().unwrap();
	other_lease.blob().expire();
	assert!(matches!(other_lease.blob().read(0, 1), Err(Error::Expired)));
	assert_eq!(
		pool.usage().bytes,
		sources::MAX_BYTES,
		"explicit expiry leaves active read custody charged"
	);
	drop(read);
	assert_eq!(pool.usage().bytes, sources::MAX_BYTES - MAX_FILE_BYTES);
	drop(other_lease);
	let lease = next.lease();
	drop(pool);
	assert!(
		matches!(lease.blob().read(0, 1), Err(Error::Expired)),
		"a lease cannot outlive its pool's authority"
	);

	let mut pool = Sources::default();
	let blob = retain(&mut pool, 1, ());
	let lease = blob.lease();
	let read = blob.read(0, 1).unwrap().unwrap();
	read.finish(1).unwrap();
	assert_eq!(
		pool.usage(),
		sources::Usage::default(),
		"consumed coverage retires even leased backing"
	);
	assert!(matches!(lease.blob().read(0, 1), Err(Error::Expired)));
}

fn repeatable() {
	let mut pool = Sources::default();
	let blob = pool
		.retain_repeatable(vec![(description(1), ())])
		.unwrap()
		.pop()
		.unwrap();
	let lease = blob.lease();
	for _ in 0..3 {
		blob.read(0, 1).unwrap().unwrap().finish(1).unwrap();
	}
	assert_eq!(
		pool.usage().bytes,
		1,
		"independent full readers retain one backing charge"
	);
	let mut leases = vec![lease];
	for _ in 1..sources::MAX_SOURCES {
		let next = pool
			.retain_repeatable(vec![(description(1), ())])
			.unwrap()
			.pop()
			.unwrap();
		leases.push(next.lease());
	}
	assert!(matches!(
		pool.retain_repeatable(vec![(description(1), ())]),
		Err(Error::Capacity)
	));
	assert!(
		blob.read(0, 1).unwrap().is_some(),
		"pressure refusal preserves held backing"
	);
	drop(pool);
	assert!(
		matches!(blob.read(0, 1), Err(Error::Expired)),
		"repeatable sources still expire with their owner"
	);
}
