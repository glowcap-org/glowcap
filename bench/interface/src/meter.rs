//! Operation phase markers and optional diagnostic allocators.
#![allow(unsafe_code)]
#[cfg(feature = "allocation-metrics")]
#[allow(unsafe_code)]
#[path = "allocation.rs"]
mod allocation;
#[cfg(feature = "allocation-metrics")]
pub use allocation::{Meter, NativeAllocator, RUST, RustAllocator};
#[cfg(not(feature = "allocation-metrics"))]
#[derive(Default)]
pub struct Meter;
#[cfg(not(feature = "allocation-metrics"))]
impl Meter {
	pub fn new() -> Self {
		Self
	}
}

unsafe extern "C" {
	fn interface_bench_begin();
	fn interface_bench_end(phase: *const std::ffi::c_char);
}
pub fn begin() {
	// SAFETY: benchmark-only linked phase marker has no arguments or ownership.
	unsafe { interface_bench_begin() };
}
pub fn end(phase: &std::ffi::CStr) {
	// SAFETY: linked marker borrows the nul-terminated name during this call.
	unsafe { interface_bench_end(phase.as_ptr()) };
}
