//! FFI allocation policy and structured-diagnostic ownership.

#[cfg(feature = "async")]
use crate::abi_constants_gen;
use crate::{
	Error, FailureEvent, FailureLayer, FailureScope, Result, error_slot, panic_message, record_runtime_failure, sys,
};

error_slot::error_slot!(
	// Maps a non-OK ocapn-family return code to an `Error` carrying the
	// message the slot recorded at the moment the call failed. status-allow: state at observation
	pub(crate) fn check;
	/// The calling thread's last recorded ocapn-family error message, or `None` if
	/// none is set. The host family and each transport keep their own slots, read
	/// by their own family errors internally.
	pub fn last_error;
	sys::glowcap_last_error
);

/// The linked `libglowcap_ocapn`'s ABI version as `(major, minor, patch)`. Compare it
/// against the header constants the binding was built against to detect skew.
pub fn abi_version() -> (u32, u32, u32) {
	let (mut major, mut minor, mut patch) = (0u32, 0u32, 0u32);
	// SAFETY: `major`, `minor`, and `patch` are local `u32`s borrowed for the call; the callee writes each and keeps no
	// pointer.
	unsafe { sys::glowcap_abi_version(&mut major, &mut minor, &mut patch) };
	(major, minor, patch)
}

/// A host-supplied allocation backend for a [`Context`]. Every method must be
/// thread-safe. The library may call them from any thread that touches a handle
/// created in the context.
pub trait ContextAllocator: Send + Sync {
	/// Return a block of at least `size` bytes aligned to `alignment`, or null on
	/// failure.
	fn alloc(&self, size: usize, alignment: usize) -> *mut u8;
	/// Release a block previously returned by [`alloc`](ContextAllocator::alloc). status-allow: ownership and operation ordering
	///
	/// # Safety
	/// `ptr` must have come from this allocator with the same `size`/`alignment`.
	unsafe fn free(&self, ptr: *mut u8, size: usize, alignment: usize);
}

// A panic must never cross an extern "C" frame (that is undefined behavior),
// and a `ContextAllocator` is user code: a panicking alloc degrades to the null
// the C side already handles as out-of-memory, and a panicking free is
// swallowed (the block leaks, the process survives).
pub(crate) unsafe extern "C" fn alloc_trampoline(
	user_data: *mut core::ffi::c_void,
	size: usize,
	alignment: usize,
) -> *mut core::ffi::c_void {
	match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
		// SAFETY: `user_data` is the pointer this context handed the C side at
		// construction, and the C side keeps the boxed allocator alive for the
		// context's whole life.
		let allocator = unsafe { &*(user_data as *const Box<dyn ContextAllocator>) };
		allocator.alloc(size, alignment) as *mut core::ffi::c_void
	})) {
		Ok(ptr) => ptr,
		Err(payload) => {
			record_runtime_failure(
				FailureLayer::Binding,
				"context-allocator-alloc-panic",
				Error::with_detail(sys::ERR_INTERNAL, panic_message(payload.as_ref())),
			);
			core::ptr::null_mut()
		}
	}
}

pub(crate) unsafe extern "C" fn free_trampoline(
	user_data: *mut core::ffi::c_void,
	ptr: *mut core::ffi::c_void,
	size: usize,
	alignment: usize,
) {
	if let Err(payload) = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
		// SAFETY: as `alloc_trampoline` for the allocator itself, alive for the
		// context's whole life; the block coming back is one this same
		// allocator gave the C side, under the size and alignment it repeats.
		unsafe {
			let allocator = &*(user_data as *const Box<dyn ContextAllocator>);
			allocator.free(ptr as *mut u8, size, alignment);
		}
	})) {
		record_runtime_failure(
			FailureLayer::Binding,
			"context-allocator-free-panic",
			Error::with_detail(sys::ERR_INTERNAL, panic_message(payload.as_ref())),
		);
	}
}

/// Shared FFI allocation policy retained by every high-level handle family
/// that cannot express the borrow in its public type.
pub(crate) struct ContextInner {
	pub(crate) raw: *mut sys::GlowcapContext,
	// Kept alive (and freed after `glowcap_context_release`) for the custom
	// allocator path; null for the default-allocator context.
	allocator: *mut Box<dyn ContextAllocator>,
}

/// An allocation scope. A Host created in it with [`crate::Host::new_in`]
/// routes every FFI allocation through it, and shared Host state retains
/// the FFI policy directly.
pub struct Context {
	pub(crate) inner: std::rc::Rc<ContextInner>,
}

impl Context {
	/// A context backed by the FFI library allocator, or by Rust
	/// allocation when linked into the same Wasm memory as the application.
	pub fn new() -> Result<Context> {
		Ok(Context {
			inner: std::rc::Rc::new(ContextInner::new()?),
		})
	}

	/// A context that routes every allocation through `allocator`.
	pub fn with_allocator(allocator: Box<dyn ContextAllocator>) -> Result<Context> {
		Ok(Context {
			inner: std::rc::Rc::new(ContextInner::with_allocator(allocator)?),
		})
	}

	/// Atomically claim the oldest unreturnable failure retained by this
	/// context. A claimed event cannot reappear. Events recorded concurrently
	/// remain ordered for later claims.
	pub fn next_failure(&self) -> Result<Option<FailureEvent>> {
		self.inner.next_failure()
	}

	/// Atomically claim every unreturnable failure retained by this
	/// context, in observation order.
	pub fn take_failures(&self) -> Result<Vec<FailureEvent>> {
		let mut failures = Vec::new();
		while let Some(failure) = self.next_failure()? {
			failures.push(failure);
		}
		Ok(failures)
	}

	#[cfg(feature = "async")]
	pub(crate) fn retain_inner(&self) -> std::rc::Rc<ContextInner> {
		std::rc::Rc::clone(&self.inner)
	}
}

impl ContextInner {
	#[cfg(target_arch = "wasm32")]
	pub(crate) fn new() -> Result<Self> {
		Self::with_allocator(Box::new(RustAllocator))
	}

	fn with_allocator(allocator: Box<dyn ContextAllocator>) -> Result<Self> {
		require_ocapn_archive()?;
		let user_data = Box::into_raw(Box::new(allocator));
		let c_allocator = sys::GlowcapAllocator {
			alloc: alloc_trampoline,
			free: free_trampoline,
			user_data: user_data as *mut core::ffi::c_void,
		};
		let mut raw: *mut sys::GlowcapContext = core::ptr::null_mut();
		// SAFETY: `c_allocator` is a local `GlowcapAllocator` borrowed for the call, with the trampolines above and
		// `user_data` the `Box::into_raw` pointer just made, which only `ContextInner::drop` frees; `raw` is an
		// out-parameter the callee fills.
		let rc = unsafe { sys::glowcap_context_new_with_allocator(&c_allocator, &mut raw) };
		if rc != sys::OK {
			// SAFETY: `user_data` came from the `Box::into_raw` above and the call failed, so the C side holds no
			// context that could use it; this is the only `Box::from_raw` on that pointer for this path.
			unsafe { drop(Box::from_raw(user_data)) };
			return Err(Error::from_code(rc));
		}
		Ok(Self {
			raw,
			allocator: user_data,
		})
	}

	#[cfg(not(target_arch = "wasm32"))]
	pub(crate) fn new() -> Result<Self> {
		require_ocapn_archive()?;
		let mut raw: *mut sys::GlowcapContext = core::ptr::null_mut();
		// SAFETY: `raw` is a local out-parameter the callee fills with the new context handle, which
		// `ContextInner::drop` releases.
		check(unsafe { sys::glowcap_context_new(&mut raw) })?;
		Ok(Self {
			raw,
			allocator: core::ptr::null_mut(),
		})
	}

	#[cfg(feature = "async")]
	pub(crate) fn report_failure(
		&self,
		layer: FailureLayer,
		scope: FailureScope,
		scope_id: u64,
		operation_id: u64,
		operation: &str,
		error: &Error,
	) {
		let runtime_layer = layer;
		let layer = match layer {
			FailureLayer::Core => abi_constants_gen::FAILURE_LAYER_CORE,
			FailureLayer::Driver => abi_constants_gen::FAILURE_LAYER_DRIVER,
			FailureLayer::Transport => abi_constants_gen::FAILURE_LAYER_TRANSPORT,
			FailureLayer::Binding => abi_constants_gen::FAILURE_LAYER_BINDING,
			FailureLayer::ApplicationObserver => abi_constants_gen::FAILURE_LAYER_APPLICATION_OBSERVER,
		};
		let scope = match scope {
			FailureScope::Process => abi_constants_gen::FAILURE_SCOPE_PROCESS,
			FailureScope::Context => abi_constants_gen::FAILURE_SCOPE_CONTEXT,
			FailureScope::Host => abi_constants_gen::FAILURE_SCOPE_HOST,
			FailureScope::Session => abi_constants_gen::FAILURE_SCOPE_SESSION,
			FailureScope::Listener => abi_constants_gen::FAILURE_SCOPE_LISTENER,
			FailureScope::Transport => abi_constants_gen::FAILURE_SCOPE_TRANSPORT,
			FailureScope::Operation => abi_constants_gen::FAILURE_SCOPE_OPERATION,
		};
		let secondary = error.secondary.first();
		let report = sys::GlowcapFailureReport {
			abi_version: 1,
			struct_size: core::mem::size_of::<sys::GlowcapFailureReport>(),
			layer,
			scope_kind: scope,
			scope_id,
			operation_id,
			primary_result: error.code,
			secondary_result: secondary.map_or(0, |failure| failure.code),
			secondary_count: error.secondary_count,
			operation: operation.as_ptr(),
			operation_len: operation.len(),
			primary_name: error.diagnostic_name().as_ptr(),
			primary_name_len: error.diagnostic_name().len(),
			primary_message: error.detail.as_deref().map_or(core::ptr::null(), str::as_ptr),
			primary_message_len: error.detail.as_deref().map_or(0, str::len),
			secondary_name: secondary.map_or(core::ptr::null(), |failure| failure.diagnostic_name().as_ptr()),
			secondary_name_len: secondary.map_or(0, |failure| failure.diagnostic_name().len()),
			secondary_message: secondary
				.and_then(|failure| failure.detail.as_deref())
				.map_or(core::ptr::null(), str::as_ptr),
			secondary_message_len: secondary
				.and_then(|failure| failure.detail.as_deref())
				.map_or(0, str::len),
		};
		// Recording is observational. If the preferred Context refuses its own
		// diagnostic input, retain both facts in the bounded surviving queue
		// without replacing the protocol or teardown outcome.
		// SAFETY: `self.raw` is this `ContextInner`'s handle from `glowcap_context_new`, released only by its `Drop`;
		// `report` is a local `GlowcapFailureReport` borrowed for the call, whose text pointers borrow `operation` and
		// `error` for the same call, and the callee copies bounded prefixes and retains no report pointer.
		let rc = unsafe { sys::glowcap_context_report_failure(self.raw, &report) };
		if rc != sys::OK {
			record_runtime_failure(runtime_layer, operation, error.clone());
			record_runtime_failure(FailureLayer::Binding, "diagnostic.record", Error::from_code(rc));
		}
	}

	pub(crate) fn next_failure(&self) -> Result<Option<FailureEvent>> {
		// SAFETY: `GlowcapFailureEvent` is a plain C struct of integers and null pointers; all-zero is a valid value,
		// and the callee fills it before it is read.
		let mut event: sys::GlowcapFailureEvent = unsafe { core::mem::zeroed() };
		let mut required = 0usize;
		let first =
			// SAFETY: `self.raw` is this `ContextInner`'s handle, released only by its `Drop`; `event` and `required`
			// are local out-parameters the callee fills, and the null payload with capacity zero asks for the size
			// only.
			unsafe { sys::glowcap_context_next_failure(self.raw, &mut event, core::ptr::null_mut(), 0, &mut required) };
		if first == sys::WOULD_BLOCK {
			return Ok(None);
		}
		if first != sys::ERR_BUFFER_TOO_SMALL && first != sys::OK {
			return Err(Error::from_code(first));
		}
		let mut payload = vec![0u8; required];
		if first == sys::ERR_BUFFER_TOO_SMALL {
			// SAFETY: as the first `glowcap_context_next_failure` call above; `payload` is a live `Vec<u8>` of
			// `payload.len()` bytes the callee writes during the call and whose storage the `event` text pointers then
			// reference.
			let rc = unsafe {
				sys::glowcap_context_next_failure(
					self.raw,
					&mut event,
					payload.as_mut_ptr(),
					payload.len(),
					&mut required,
				)
			};
			check(rc)?;
		}

		unsafe fn text(ptr: *const u8, len: usize, field: &str) -> Result<String> {
			if len == 0 {
				return Ok(String::new());
			}
			if ptr.is_null() {
				return Err(Error::with_detail(
					sys::ERR_INTERNAL,
					format!("glowcap ABI returned a null {field} with nonzero length"),
				));
			}
			// SAFETY: the callers pass pointers the callee wrote into `event` that reference the caller-owned `payload`
			// storage, which outlives every `text` call; `ptr` is non-null here and `len` bytes were written there, and
			// the slice is copied out before returning.
			let bytes = unsafe { core::slice::from_raw_parts(ptr, len) };
			let value = core::str::from_utf8(bytes).map_err(|_| {
				Error::with_detail(
					sys::ERR_INTERNAL,
					format!("glowcap ABI returned invalid UTF-8 in {field}"),
				)
			})?;
			Ok(value.to_owned())
		}

		Ok(Some(FailureEvent {
			sequence: event.sequence,
			dropped_before: event.dropped_before,
			layer: FailureLayer::from_abi(event.layer)?,
			scope: FailureScope::from_abi(event.scope_kind)?,
			scope_id: event.scope_id,
			operation_id: event.operation_id,
			primary_result: event.primary_result,
			secondary_result: event.secondary_result,
			secondary_count: event.secondary_count,
			truncated_fields: event.flags,
			// SAFETY: `event.operation` and its length were filled by `glowcap_context_next_failure` and point into
			// `payload`, a live local until this statement ends; `text` only reads that range and returns an owned
			// `String`.
			operation: unsafe { text(event.operation, event.operation_len, "failure operation")? },
			// SAFETY: as `operation` above, for `event.primary_name`.
			primary_name: unsafe { text(event.primary_name, event.primary_name_len, "primary failure name")? },
			// SAFETY: as `operation` above, for `event.primary_message`.
			primary_message: unsafe {
				text(
					event.primary_message,
					event.primary_message_len,
					"primary failure message",
				)?
			},
			// SAFETY: as `operation` above, for `event.secondary_name`.
			secondary_name: unsafe { text(event.secondary_name, event.secondary_name_len, "secondary failure name")? },
			// SAFETY: as `operation` above, for `event.secondary_message`.
			secondary_message: unsafe {
				text(
					event.secondary_message,
					event.secondary_message_len,
					"secondary failure message",
				)?
			},
		}))
	}
}

fn require_ocapn_archive() -> Result<()> {
	crate::require_archive_fingerprint(
		"ocapn",
		// SAFETY: `glowcap_ocapn_archive_fingerprint` takes no arguments and returns an integer by value, so it touches
		// no Rust memory.
		unsafe { sys::glowcap_ocapn_archive_fingerprint() },
		sys::OCAPN_ARCHIVE_FINGERPRINT,
	)
}

impl Drop for ContextInner {
	fn drop(&mut self) {
		// Release the context first, it frees its tables through the allocator,
		// then drop the host allocator the trampolines borrowed.
		// SAFETY: `self.raw` is the handle from `glowcap_context_new` or `glowcap_context_new_with_allocator`, released
		// exactly once here because `Drop` runs once; every handle created through the context is released first by the
		// types that retain `ContextInner`.
		unsafe { sys::glowcap_context_release(self.raw) };
		if !self.allocator.is_null() {
			// SAFETY: `self.allocator` is the non-null `Box::into_raw` pointer made in `with_allocator`, freed exactly
			// once here and only after `glowcap_context_release` has stopped the C side from calling the trampolines.
			unsafe { drop(Box::from_raw(self.allocator)) };
		}
	}
}

// One allocator owns the linked module's application and Host heap. FFI
// contexts keep the library allocator; Wasm contexts route through Rust so a
// consumer's global allocator governs both sides of the direct C calls.
#[cfg(target_arch = "wasm32")]
struct RustAllocator;
#[cfg(target_arch = "wasm32")]
impl ContextAllocator for RustAllocator {
	fn alloc(&self, size: usize, alignment: usize) -> *mut u8 {
		match std::alloc::Layout::from_size_align(size.max(1), alignment) {
			Ok(layout) => unsafe { std::alloc::alloc(layout) },
			Err(_) => core::ptr::null_mut(),
		}
	}
	unsafe fn free(&self, ptr: *mut u8, size: usize, alignment: usize) {
		// SAFETY: the trait's contract: `ptr` came from this allocator's
		// `alloc` under the same size and alignment, including its `max(1)`.
		unsafe {
			std::alloc::dealloc(
				ptr,
				std::alloc::Layout::from_size_align(size.max(1), alignment).unwrap(),
			);
		}
	}
}
