//! Benchmark-only allocation observation. Native contexts delegate directly to
//! System, bypassing the Rust global meter. Each allocation belongs to one row.
use glowcap::ContextAllocator;
use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::{
	Arc,
	atomic::{AtomicBool, AtomicI64, AtomicU64, Ordering::Relaxed},
};

#[derive(Default)]
pub struct Meter {
	enabled: AtomicBool,
	allocations: AtomicU64,
	requested: AtomicU64,
	live: AtomicI64,
}
#[derive(Clone, Copy, Debug)]
pub struct Snapshot {
	pub allocations: u64,
	pub requested: u64,
	pub live: i64,
}
impl Meter {
	pub const fn new() -> Self {
		Self {
			enabled: AtomicBool::new(false),
			allocations: AtomicU64::new(0),
			requested: AtomicU64::new(0),
			live: AtomicI64::new(0),
		}
	}
	fn allocated(&self, size: usize) {
		if self.enabled.load(Relaxed) {
			self.live.fetch_add(size as i64, Relaxed);
			self.allocations.fetch_add(1, Relaxed);
			self.requested.fetch_add(size as u64, Relaxed);
		}
	}
	fn freed(&self, size: usize) {
		if self.enabled.load(Relaxed) {
			self.live.fetch_sub(size as i64, Relaxed);
		}
	}
	pub fn start(&self) -> Snapshot {
		self.allocations.store(0, Relaxed);
		self.requested.store(0, Relaxed);
		self.live.store(0, Relaxed);
		self.enabled.store(true, Relaxed);
		self.snapshot()
	}
	pub fn stop(&self, before: Snapshot) -> Snapshot {
		self.enabled.store(false, Relaxed);
		let after = self.snapshot();
		Snapshot {
			allocations: after.allocations,
			requested: after.requested,
			live: after.live - before.live,
		}
	}
	fn snapshot(&self) -> Snapshot {
		Snapshot {
			allocations: self.allocations.load(Relaxed),
			requested: self.requested.load(Relaxed),
			live: self.live.load(Relaxed),
		}
	}
}

pub struct RustAllocator;
pub static RUST: Meter = Meter::new();
// SAFETY: all operations preserve System's pointer/layout contract, and counters
// have no allocator dependencies. Reallocation counts one positive request.
unsafe impl GlobalAlloc for RustAllocator {
	unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
		// SAFETY: the GlobalAlloc caller supplies a valid layout.
		let pointer = unsafe { System.alloc(layout) };
		if !pointer.is_null() {
			RUST.allocated(layout.size());
		}
		pointer
	}
	unsafe fn dealloc(&self, pointer: *mut u8, layout: Layout) {
		// SAFETY: the caller repeats this live System allocation's layout.
		unsafe { System.dealloc(pointer, layout) };
		RUST.freed(layout.size());
	}
	unsafe fn realloc(&self, pointer: *mut u8, layout: Layout, size: usize) -> *mut u8 {
		// SAFETY: the caller owns this block and supplies its layout and new size.
		let next = unsafe { System.realloc(pointer, layout, size) };
		if !next.is_null() {
			RUST.freed(layout.size());
			RUST.allocated(size);
		}
		next
	}
}

pub struct NativeAllocator(pub Arc<Meter>);
impl ContextAllocator for NativeAllocator {
	fn alloc(&self, size: usize, alignment: usize) -> *mut u8 {
		let layout = Layout::from_size_align(size.max(1), alignment).unwrap();
		// SAFETY: valid layout; System deliberately bypasses the Rust meter.
		let pointer = unsafe { System.alloc(layout) };
		if !pointer.is_null() {
			self.0.allocated(size);
		}
		pointer
	}
	unsafe fn free(&self, pointer: *mut u8, size: usize, alignment: usize) {
		let layout = Layout::from_size_align(size.max(1), alignment).unwrap();
		// SAFETY: the ContextAllocator contract repeats this allocation's layout.
		unsafe { System.dealloc(pointer, layout) };
		self.0.freed(size);
	}
}
