//! Admission hot-path cost and retained registry bounds. No network benchmark.
use rooms_application::admission::{Charge, Class, Profile, Registry};
use std::{
	alloc::{GlobalAlloc, Layout, System},
	hint::black_box,
	sync::atomic::{AtomicUsize, Ordering},
	time::Instant,
};
struct Measured;
static ALLOCATIONS: AtomicUsize = AtomicUsize::new(0);
static BYTES: AtomicUsize = AtomicUsize::new(0);
// SAFETY: this meter forwards each allocation and release unchanged to System.
// Counters store only integers; they never allocate or retain caller pointers.
unsafe impl GlobalAlloc for Measured {
	unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
		ALLOCATIONS.fetch_add(1, Ordering::Relaxed);
		BYTES.fetch_add(layout.size(), Ordering::Relaxed);
		// SAFETY: `layout` is the caller's, which `GlobalAlloc::alloc` requires to have nonzero size; this meter
		// forwards it unchanged to `System.alloc`, so that contract passes straight through.
		unsafe { System.alloc(layout) }
	}
	unsafe fn dealloc(&self, pointer: *mut u8, layout: Layout) {
		// SAFETY: `pointer` and `layout` are the caller's, which `GlobalAlloc::dealloc` requires to match a block this
		// allocator returned; `alloc` and `realloc` forward to `System`, so `pointer` is a `System` block with that
		// layout.
		unsafe { System.dealloc(pointer, layout) }
	}
	unsafe fn realloc(&self, pointer: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
		ALLOCATIONS.fetch_add(1, Ordering::Relaxed);
		BYTES.fetch_add(new_size, Ordering::Relaxed);
		// SAFETY: `pointer`, `layout`, and `new_size` are the caller's, which `GlobalAlloc::realloc` requires to
		// describe a block this allocator returned and a valid nonzero `new_size`; `alloc` and `dealloc` forward to
		// `System`, so `System.realloc` owns that block.
		unsafe { System.realloc(pointer, layout, new_size) }
	}
}
#[global_allocator]
static ALLOCATOR: Measured = Measured;
fn sample(work: impl FnOnce()) -> (u128, usize, usize) {
	let before = (ALLOCATIONS.load(Ordering::Relaxed), BYTES.load(Ordering::Relaxed));
	let start = Instant::now();
	work();
	let elapsed = start.elapsed().as_nanos();
	(
		elapsed,
		ALLOCATIONS.load(Ordering::Relaxed) - before.0,
		BYTES.load(Ordering::Relaxed) - before.1,
	)
}
fn main() {
	const CALLS: u64 = 100_000;
	let charges = [
		Charge {
			key: [1u8; 33],
			class: Class::Message,
			amount: 1,
		},
		Charge {
			key: [1u8; 33],
			class: Class::MessageBytes,
			amount: 32,
		},
	];
	let mut registry = Registry::new(Profile::default(), 8192);
	registry.admit(&charges, 0).unwrap();
	let baseline = sample(|| {
		for i in 1..=CALLS {
			black_box((black_box(&charges), black_box(i * 1000)));
		}
	});
	let admitted = sample(|| {
		for i in 1..=CALLS {
			registry.admit(black_box(&charges), black_box(i * 1000)).unwrap();
		}
	});
	assert_eq!(admitted.1, 0, "steady admitted traffic allocated policy rows");
	let refused = sample(|| {
		for _ in 0..CALLS {
			let _ = black_box(registry.admit(&charges, CALLS * 1000));
		}
	});
	assert_eq!(refused.1, 0, "refusal allocated before diagnostic rendering");
	let mut full = Registry::new(Profile::default(), 8192);
	let retained = sample(|| {
		for i in 0u64..8192 {
			let mut key = [0; 33];
			key[..8].copy_from_slice(&i.to_be_bytes());
			full.admit(
				&[Charge {
					key,
					class: Class::Connection,
					amount: 6,
				}],
				0,
			)
			.unwrap();
		}
	});
	println!(
		"borrowed baseline ns/op={}; admitted ns/op={}; refused ns/op={}; hot allocations={}; retained rows={}; tree requested bytes={}",
		baseline.0 / u128::from(CALLS),
		admitted.0 / u128::from(CALLS),
		refused.0 / u128::from(CALLS),
		admitted.1,
		full.len(),
		retained.2
	);
}
