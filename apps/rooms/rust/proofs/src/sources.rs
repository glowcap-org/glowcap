use super::arguments::Arg;
use rooms_application::files::{
	sources::{self, Error, Sources},
	FileDescription, CHUNK_BYTES, MAX_FILE_BYTES,
};
use std::{cell::Cell, rc::Rc};
fn description(size: usize) -> FileDescription {
	FileDescription::parse("file", "application/octet-stream", size as u64, 0, 0).unwrap()
}
fn retain<S>(pool: &mut Sources<S>, size: usize, source: S) -> sources::Blob<S> {
	pool.retain(vec![(description(size), source)]).unwrap().pop().unwrap()
}
pub fn run() {
	receiver_budget();
	let captured: serde_json::Value = serde_json::from_str(include_str!("../fixtures/direct-sources.json")).unwrap();
	assert_eq!(
		captured["limits"],
		serde_json::json!({"files":sources::MAX_SOURCES,"bytes":sources::MAX_BYTES,"chunk":CHUNK_BYTES})
	);
	for trace in captured["traces"].as_array().unwrap() {
		let mut pool = Sources::default();
		let blob = retain(&mut pool, trace["size"].as_u64().unwrap() as usize, ());
		if trace["fail"] == true {
			blob.expire();
		}
		let mut calls = Vec::new();
		for row in trace["reads"].as_array().unwrap() {
			let offset = row["offset"]
				.as_i64()
				.map(|n| Arg::Integer(n.into()))
				.unwrap_or(Arg::Float(0.));
			let result = blob.read_call("read", &[offset, Arg::Integer(row["maximum"].as_i64().unwrap().into())]);
			let length = match result {
				Err(_) => None,
				Ok(None) => Some(0),
				Ok(Some(read)) => {
					let range = read.range();
					calls.push((range.start, range.len()));
					read.finish(range.len()).unwrap();
					Some(range.len())
				}
			};
			assert_eq!(serde_json::json!(length), row["length"], "{}", trace["name"]);
		}
		assert_eq!(serde_json::json!(calls), trace["calls"]);
	}
	let mut pool = Sources::default();
	let blob = retain(&mut pool, CHUNK_BYTES + 1, ());
	assert!(blob.read_call("read", &[Arg::Float(0.), Arg::Integer(1)]).is_err());
	assert!(blob
		.read_call("read", &[Arg::Integer(0), Arg::Integer(1), Arg::Null])
		.is_err());
	assert!(blob.read(0, 0).is_err());
	// Out-of-order coverage does not discard a source whose prefix has a gap.
	let last = blob.read(CHUNK_BYTES as u64, 1).unwrap().unwrap();
	assert_eq!(last.range(), CHUNK_BYTES..CHUNK_BYTES + 1);
	last.finish(1).unwrap();
	let first = blob.read(0, u64::MAX).unwrap().unwrap();
	assert_eq!(first.range(), 0..CHUNK_BYTES);
	assert_eq!(first.finish(1), Err(Error::Reply));
	blob.read(0, u64::MAX).unwrap().unwrap().finish(CHUNK_BYTES).unwrap();
	assert_eq!(pool.usage().files, 1);
	blob.read(CHUNK_BYTES as u64, 1).unwrap().unwrap().finish(1).unwrap();
	assert!(matches!(blob.read(0, 1), Err(Error::Expired)));
	assert!(blob.read(u64::MAX, 1).unwrap().is_none());
	assert_eq!(pool.usage(), Default::default());
	let empty = retain(&mut pool, 0, ());
	assert!(empty.read(0, 1).unwrap().is_none());
	assert_eq!(pool.usage().files, 0);
	let blob = retain(&mut pool, 1, ());
	let reads: Vec<_> = (0..sources::MAX_READS)
		.map(|_| blob.read(0, 1).unwrap().unwrap())
		.collect();
	assert!(matches!(blob.read(0, 1), Err(Error::Reads)));
	blob.expire();
	assert_eq!(pool.usage().bytes, 1);
	drop(reads);
	assert_eq!(pool.usage().bytes, 0);
	let mut held = Vec::new();
	for _ in 0..sources::MAX_SOURCES {
		held.push(retain(&mut pool, 1, ()));
	}
	let extra = retain(&mut pool, 1, ());
	assert!(matches!(held[0].read(0, 1), Err(Error::Expired)));
	assert_eq!(pool.usage().files, sources::MAX_SOURCES);
	drop((held, extra));
	assert_eq!(pool.usage().files, 0);
	// Pinned bytes cannot be evicted out of accounting. Admission preflight
	// refuses without expiring siblings when no full batch can fit.
	let held: Vec<_> = (0..4).map(|_| retain(&mut pool, MAX_FILE_BYTES, ())).collect();
	let read = held[0].read(0, 1).unwrap().unwrap();
	assert!(matches!(
		pool.retain((0..4).map(|_| (description(MAX_FILE_BYTES), ())).collect()),
		Err(Error::Capacity)
	));
	assert!(held[1].read(0, 1).unwrap().is_some());
	drop(read);
	let replacement = retain(&mut pool, MAX_FILE_BYTES, ());
	assert!(matches!(held[0].read(0, 1), Err(Error::Expired)));
	assert_eq!(pool.usage().bytes, sources::MAX_BYTES);
	assert!(matches!(
		pool.retain((0..5).map(|_| (description(MAX_FILE_BYTES), ())).collect()),
		Err(Error::Bytes)
	));
	assert!(replacement.read(0, 1).unwrap().is_some());
	drop(pool);
	assert!(matches!(replacement.read(0, 1), Err(Error::Expired)));
	// An in-flight source is dropped only after its final read releases it.
	struct DropCount(Rc<Cell<usize>>);
	impl Drop for DropCount {
		fn drop(&mut self) {
			self.0.set(self.0.get() + 1)
		}
	}
	let dropped = Rc::new(Cell::new(0));
	let mut pool = Sources::default();
	let blob = retain(&mut pool, 1, DropCount(dropped.clone()));
	let read = blob.read(0, 1).unwrap().unwrap();
	blob.expire();
	assert_eq!(dropped.get(), 0);
	assert_eq!(pool.usage().bytes, 1);
	drop(read);
	assert_eq!(dropped.get(), 1);
	assert_eq!(pool.usage().bytes, 0);
}

fn receiver_budget() {
	use rooms_application::files::receiving::{selection_fits, Budget, Usage};
	let largest = description(MAX_FILE_BYTES);
	assert!(selection_fits(core::iter::repeat_n(&largest, 4)));
	assert!(!selection_fits(core::iter::repeat_n(&largest, 5)));
	let empty = description(0);
	assert!(selection_fits(core::iter::repeat_n(&empty, 8)));
	assert!(!selection_fits(core::iter::repeat_n(&empty, 9)));
	let budget = Budget::default();
	assert!(budget.can_admit_many(8, sources::MAX_BYTES, 0, 0));
	assert!(!budget.can_admit_many(sources::MAX_READS + 1, 0, 0, 0));
	assert!(!budget.can_admit_many(1, sources::MAX_BYTES + 1, 0, 0));
	let mut held = (0..4)
		.map(|_| budget.reserve(MAX_FILE_BYTES).unwrap())
		.collect::<Vec<_>>();
	assert!(!budget.can_admit(1, 0, 0));
	assert!(budget.can_admit(1, 1, MAX_FILE_BYTES));
	assert!(!budget.can_admit(1, 5, MAX_FILE_BYTES));
	for charge in &mut held {
		charge.captured();
	}
	assert_eq!(
		budget.usage(),
		Usage {
			files: 4,
			bytes: sources::MAX_BYTES,
			active: 0
		}
	);
	assert!(budget.reserve(1).is_none());
	drop(held);
	assert_eq!(budget.usage(), Usage::default());
	let mut held = (0..sources::MAX_READS)
		.map(|_| budget.reserve(0).unwrap())
		.collect::<Vec<_>>();
	assert!(budget.reserve(0).is_none());
	for charge in &mut held {
		charge.captured();
	}
	for _ in sources::MAX_READS..sources::MAX_SOURCES {
		let mut charge = budget.reserve(0).unwrap();
		charge.captured();
		held.push(charge);
	}
	assert!(budget.reserve(0).is_none(), "zero-byte metadata is count bounded");
	drop(held);
	assert_eq!(budget.usage(), Usage::default());
}
