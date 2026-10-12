//! Link and allocation probe over the existing C ABI. Only pointer/scalar
//! functions and the allocator callback table cross here. `binding` exercises
//! the real Rust Context and locator wrappers. Async Host argument marshaling
//! and network dispatch are proved by the browser-host scenarios rather than
//! duplicated in this focused artifact.
use std::{
	alloc::{Layout, alloc, dealloc},
	ffi::c_void,
	ptr::null_mut,
};

type Behavior =
	unsafe extern "C" fn(*mut c_void, *mut c_void, *const u8, usize, *const c_void, usize, *mut c_void) -> i32;

#[repr(C)]
struct Allocator {
	alloc: unsafe extern "C" fn(*mut c_void, usize, usize) -> *mut c_void,
	free: unsafe extern "C" fn(*mut c_void, *mut c_void, usize, usize),
	user_data: *mut c_void,
}

unsafe extern "C" {
	fn glowcap_context_new_with_allocator(allocator: *const Allocator, out: *mut *mut c_void) -> i32;
	fn glowcap_context_release(context: *mut c_void);
	fn glowcap_host_new_in(
		context: *mut c_void,
		seed: *const u8,
		seed_len: usize,
		frame_cap: usize,
		verify_partner: u32,
		codec: u32,
		captp_version: u32,
		features: u32,
		local_turn_budget: u32,
		out: *mut *mut c_void,
	) -> i32;
	fn glowcap_host_release(host: *mut c_void) -> i32;
	fn glowcap_host_publish(
		host: *mut c_void,
		name: *const u8,
		name_len: usize,
		behavior: Behavior,
		ctx: *mut c_void,
		free: unsafe extern "C" fn(*mut c_void),
	) -> i32;
	fn glowcap_host_designator_from_seed(seed: *const u8, seed_len: usize, out: *mut u8, out_len: usize) -> i32;
}

#[derive(Default)]
struct Counts {
	live_bytes: usize,
	allocations: usize,
	retired: usize,
}

unsafe extern "C" fn allocate(ctx: *mut c_void, size: usize, alignment: usize) -> *mut c_void {
	let Ok(layout) = Layout::from_size_align(size, alignment) else {
		return null_mut();
	};
	// SAFETY: `layout` came from the size and alignment the host asked for, and
	// `ctx` is the `Counts` this proof handed the context at construction and
	// keeps alive past every host using it.
	unsafe {
		let ptr = alloc(layout);
		if !ptr.is_null() {
			let counts = &mut *ctx.cast::<Counts>();
			counts.live_bytes += size;
			counts.allocations += 1;
		}
		ptr.cast()
	}
}

unsafe extern "C" fn free(ctx: *mut c_void, ptr: *mut c_void, size: usize, alignment: usize) {
	// SAFETY: the same `Counts`, and the block coming back is one `allocate`
	// gave the host under the size and alignment it repeats here.
	unsafe {
		let counts = &mut *ctx.cast::<Counts>();
		counts.live_bytes -= size;
		dealloc(ptr.cast(), Layout::from_size_align(size, alignment).unwrap());
	}
}

unsafe extern "C" fn behavior(
	_: *mut c_void,
	_: *mut c_void,
	_: *const u8,
	_: usize,
	_: *const c_void,
	_: usize,
	_: *mut c_void,
) -> i32 {
	-1
}

unsafe extern "C" fn retire(ctx: *mut c_void) {
	// SAFETY: the same `Counts` the allocator callbacks carry.
	unsafe { (*ctx.cast::<Counts>()).retired += 1 };
}

pub fn run() {
	// Repeat alternating Rust and Zig allocation, including memory growth in
	// Wasm. Every pointer remains in the one linked memory. The context routes
	// host allocation through Rust and must outlive every host using it.
	for _ in 0..4 {
		let mut counts = Counts::default();
		let counts_ptr = core::ptr::addr_of_mut!(counts).cast();
		let allocator = Allocator {
			alloc: allocate,
			free,
			user_data: counts_ptr,
		};
		let mut context = null_mut();
		let mut host = null_mut();
		let seed = [0x5a; 64];
		let rust_buffer = vec![0xa5; 2 * 1024 * 1024];
		std::hint::black_box(&rust_buffer);
		// SAFETY: `allocator` is a local `Allocator` whose `user_data` is `counts_ptr`, the address of the local
		// `counts`, which outlives the context and host (both released inside this block, before `counts` is read);
		// `seed` is a 64-byte local array viewed as its full 64 bytes and, for the designator, its first 32, and
		// `designator` is a 64-byte local array viewed with its own length; `b"rooms"` is a 5-byte literal; `context`
		// and `host` are local out-parameters the callees fill, each handle is used only after its constructor returned
		// 0 (asserted), and the host is released before the context.
		unsafe {
			assert_eq!(glowcap_context_new_with_allocator(&allocator, &mut context), 0);
			assert_eq!(
				glowcap_host_new_in(
					context,
					seed.as_ptr(),
					seed.len(),
					1024 * 1024,
					1,
					1,
					0,
					31,
					64,
					&mut host
				),
				0
			);
			let mut designator = [0; 64];
			assert_eq!(
				glowcap_host_designator_from_seed(seed.as_ptr(), 32, designator.as_mut_ptr(), designator.len()),
				0
			);
			assert!(designator.iter().all(u8::is_ascii_hexdigit));
			assert_eq!(
				glowcap_host_publish(host, b"rooms".as_ptr(), 5, behavior, counts_ptr, retire),
				0
			);
			assert_eq!(counts.retired, 0);
			assert_eq!(glowcap_host_release(host), 0);
			glowcap_context_release(context);
		}
		assert_eq!(counts.retired, 1);
		assert!(counts.allocations > 0);
		assert_eq!(counts.live_bytes, 0);
		assert!(rust_buffer.iter().all(|byte| *byte == 0xa5));
	}
}
