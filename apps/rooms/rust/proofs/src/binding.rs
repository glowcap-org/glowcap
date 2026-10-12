//! The real Rust binding consumes target-reflected C layouts on both hosts.
use glowcap::{Context, ContextAllocator, HintValue, Locator, SturdyRef};
use std::alloc::{Layout, alloc, dealloc};

struct RustHeap;
impl ContextAllocator for RustHeap {
	fn alloc(&self, size: usize, alignment: usize) -> *mut u8 {
		// A zero-size request still gets a real block, as the binding's own `RustAllocator` does, because the global
		// allocator contract forbids a zero-size layout.
		match Layout::from_size_align(size.max(1), alignment) {
			// SAFETY: `layout` has a nonzero size and the valid alignment the C side requested; the returned pointer,
			// or null on failure, goes back to the C side, which pairs it with `free` below.
			Ok(layout) => unsafe { alloc(layout) },
			Err(_) => core::ptr::null_mut(),
		}
	}
	unsafe fn free(&self, pointer: *mut u8, size: usize, alignment: usize) {
		// SAFETY: the trait's contract: `pointer` came from this allocator's
		// `alloc` under the same size and alignment, including its `max(1)`.
		unsafe { dealloc(pointer, Layout::from_size_align(size.max(1), alignment).unwrap()) };
	}
}

pub fn run() {
	for _ in 0..32 {
		let context = Context::with_allocator(Box::new(RustHeap)).unwrap();
		assert!(context.next_failure().unwrap().is_none());
		let mut locator = Locator::bare("tcp", "[::1]:9000");
		locator.hint_wire_form = glowcap::HintWireForm::Map;
		locator
			.hints
			.insert("label".into(), HintValue::String("room café".into()));
		locator.hints.insert("epoch".into(), HintValue::Integer(7));
		locator.hints.insert("public".into(), HintValue::Boolean(false));
		locator
			.hints
			.insert("nonce".into(), HintValue::Bytes(vec![0, 128, 255]));
		assert!(!glowcap::encode_peer_locator(&locator).unwrap().is_empty());
		// Textual URIs carry string hints; typed hints travel in locator records.
		locator.hints.retain(|_, value| matches!(value, HintValue::String(_)));
		let reference = SturdyRef {
			locator,
			swissnum: vec![0, 1, 128, 255],
		};
		let uri =
			glowcap::format_sturdyref(&reference.locator, &reference.swissnum, glowcap::CaptpVersion::V1_0).unwrap();
		assert_eq!(
			glowcap::parse_sturdyref(&uri, glowcap::CaptpVersion::V1_0).unwrap(),
			reference
		);
		assert_eq!(
			glowcap::designator_host_port("[::1]:9000").unwrap(),
			("::1".into(), 9000)
		);
		assert!(glowcap::parse_locator("not a locator").is_err());
		// Keep Rust-owned bytes live while the C vocabulary allocates its views.
		let held = vec![0xa5; 131_072];
		let parsed = glowcap::parse_sturdyref(&uri, glowcap::CaptpVersion::V1_0).unwrap();
		assert_eq!(parsed, reference);
		assert!(held.iter().all(|byte| *byte == 0xa5));
	}
}
