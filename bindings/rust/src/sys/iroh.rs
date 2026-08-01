//! Raw FFI for the iroh transport archive
//! (`libpancake_net_transport_iroh`).
//!
//! Linked only with the `iroh` feature (ADR-0055/ADR-0059). Unlike the static
//! TCP and in-process archives, this is a dynamic companion that links the Rust
//! iroh sidecar; it exports only the `pancake_iroh_*` family and its own
//! thread-local last-error (`pancake_iroh_last_error`), sharing no core symbol.
//! The shared frame and context types it speaks are reused by layout from
//! [`crate::sys`].
#![allow(dead_code)]

use super::layouts_gen::*;

#[repr(C)]
pub struct PancakeIrohNetlayer {
	_private: [u8; 0],
}
#[repr(C)]
pub struct PancakeIrohConn {
	_private: [u8; 0],
}

// Readiness event bits (the header's PANCAKE_IROH_EV_*), carried by a
// `drain_ready` record; values from the generated constant mirror, so they
// cannot drift from the C ABI. A record may carry several at once.
pub const PANCAKE_IROH_EV_READABLE: u32 = crate::abi_constants_gen::IROH_EV_READABLE;
pub const PANCAKE_IROH_EV_WRITABLE: u32 = crate::abi_constants_gen::IROH_EV_WRITABLE;
pub const PANCAKE_IROH_EV_CLOSED: u32 = crate::abi_constants_gen::IROH_EV_CLOSED;
pub const PANCAKE_IROH_EV_ACCEPT: u32 = crate::abi_constants_gen::IROH_EV_ACCEPT;
pub const PANCAKE_IROH_EV_CONNECT: u32 = crate::abi_constants_gen::IROH_EV_CONNECT;

/// One readiness record drained by `pancake_iroh_netlayer_drain_ready` — the
/// `#[repr(C)]` counterpart of the header's `PancakeIrohReadyEvent`.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct PancakeIrohReadyEvent {
	pub subject: usize,
	pub events: u32,
}

// Pin the hand-mirrored layout on LP64 (the linux x86_64/aarch64 targets the
// gates run), the same posture as `sys::host`'s action pin: a field added or
// reordered on either side moves an offset and fails the build loudly instead
// of misrouting the first drained record. Expected values come from
// `layouts_gen` (`zig build gen-binding-ffi-layouts`), reflected off the real
// Zig `PancakeIrohReadyEvent`.
const _: () = {
	use core::mem::{offset_of, size_of};
	assert!(size_of::<PancakeIrohReadyEvent>() == PANCAKE_IROH_READY_EVENT_SIZE);
	assert!(offset_of!(PancakeIrohReadyEvent, subject) == PANCAKE_IROH_READY_EVENT_SUBJECT_OFF);
	assert!(offset_of!(PancakeIrohReadyEvent, events) == PANCAKE_IROH_READY_EVENT_EVENTS_OFF);
};

/// `#[repr(C)]` counterpart of the header's `PancakeIrohConfig`. `reachability`
/// is mandatory; `connect_timeout_ms` is the per-endpoint stream-establishment
/// deadline (0 = the built-in default). Construct with `..Default::default()`
/// (or the `Default` impl) so a field a later version adds stays 0 rather than
/// reading uninitialized memory — the header's zero-init contract.
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct PancakeIrohConfig {
	pub reachability: u32,
	pub connect_timeout_ms: u64,
}

// Pinned against `layouts_gen` (`zig build gen-binding-ffi-layouts`),
// reflected off the real Zig `PancakeIrohConfig`.
const _: () = {
	use core::mem::{offset_of, size_of};
	assert!(size_of::<PancakeIrohConfig>() == PANCAKE_IROH_CONFIG_SIZE);
	assert!(offset_of!(PancakeIrohConfig, reachability) == PANCAKE_IROH_CONFIG_REACHABILITY_OFF);
	assert!(
		offset_of!(PancakeIrohConfig, connect_timeout_ms)
			== PANCAKE_IROH_CONFIG_CONNECT_TIMEOUT_MS_OFF
	);
};

// The raw extern block is generated (`iroh_fns_gen.rs`, `zig build
// gen-binding-rust-ffi`): types reflected from the Zig exports, parameter
// names from the generated C header. Re-exported here so consumers keep
// their `sys::iroh::pancake_iroh_*` paths.
pub use super::iroh_fns_gen::*;
