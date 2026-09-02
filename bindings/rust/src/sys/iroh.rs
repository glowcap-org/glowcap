//! Raw FFI for the iroh transport archive
//! (`libglowcap_net_transport_iroh`).
//!
//! Linked only with the `iroh` feature (ADR-0055/ADR-0059). Unlike the static
//! TCP and in-process archives, this is a dynamic companion that links the Rust
//! iroh sidecar; it exports only the `glowcap_iroh_*` family and its own
//! thread-local last-error (`glowcap_iroh_last_error`), sharing no core symbol.
//! The shared frame and context types it speaks are reused by layout from
//! [`crate::sys`].
#![allow(dead_code)]

use super::layouts_gen::*;

#[repr(C)]
pub struct GlowcapIrohNetlayer {
	_private: [u8; 0],
}
#[repr(C)]
pub struct GlowcapIrohConn {
	_private: [u8; 0],
}

// Readiness event bits (the header's GLOWCAP_IROH_EV_*), carried by a
// `drain_ready` record; values from the generated constant mirror, so they
// cannot drift from the C ABI. A record may carry several at once.
pub const GLOWCAP_IROH_EV_READABLE: u32 = crate::abi_constants_gen::IROH_EV_READABLE;
pub const GLOWCAP_IROH_EV_WRITABLE: u32 = crate::abi_constants_gen::IROH_EV_WRITABLE;
pub const GLOWCAP_IROH_EV_CLOSED: u32 = crate::abi_constants_gen::IROH_EV_CLOSED;
pub const GLOWCAP_IROH_EV_ACCEPT: u32 = crate::abi_constants_gen::IROH_EV_ACCEPT;
pub const GLOWCAP_IROH_EV_CONNECT: u32 = crate::abi_constants_gen::IROH_EV_CONNECT;

/// One readiness record drained by `glowcap_iroh_netlayer_drain_ready` — the
/// `#[repr(C)]` counterpart of the header's `GlowcapIrohReadyEvent`.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct GlowcapIrohReadyEvent {
	pub subject: usize,
	pub events: u32,
}

// Pin the hand-mirrored layout on LP64 (the linux x86_64/aarch64 targets the
// gates run), the same posture as `sys::host`'s action pin: a field added or
// reordered on either side moves an offset and fails the build loudly instead
// of misrouting the first drained record. Expected values come from
// `layouts_gen` (`zig build gen-binding-ffi-layouts`), reflected off the real
// Zig `GlowcapIrohReadyEvent`.
const _: () = {
	use core::mem::{offset_of, size_of};
	assert!(size_of::<GlowcapIrohReadyEvent>() == GLOWCAP_IROH_READY_EVENT_SIZE);
	assert!(offset_of!(GlowcapIrohReadyEvent, subject) == GLOWCAP_IROH_READY_EVENT_SUBJECT_OFF);
	assert!(offset_of!(GlowcapIrohReadyEvent, events) == GLOWCAP_IROH_READY_EVENT_EVENTS_OFF);
};

/// `#[repr(C)]` counterpart of the header's `GlowcapIrohConfig`. `reachability`
/// is mandatory; `connect_timeout_ms` is the per-endpoint stream-establishment
/// deadline (0 = the built-in default). Construct with `..Default::default()`
/// (or the `Default` impl) so a field a later version adds stays 0 rather than
/// reading uninitialized memory — the header's zero-init contract.
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct GlowcapIrohConfig {
	pub reachability: u32,
	pub connect_timeout_ms: u64,
	/// How long a connection may go with nothing arriving on it before QUIC
	/// declares it dead, which decides how quickly a peer killed rather than
	/// closed stops counting as connected. 0 keeps the built-in default.
	pub idle_timeout_ms: u64,
	/// Worker threads for this endpoint's runtime; 0 keeps the default.
	pub worker_threads: u32,
}

// Pinned against `layouts_gen` (`zig build gen-binding-ffi-layouts`),
// reflected off the real Zig `GlowcapIrohConfig`.
const _: () = {
	use core::mem::{offset_of, size_of};
	assert!(size_of::<GlowcapIrohConfig>() == GLOWCAP_IROH_CONFIG_SIZE);
	assert!(offset_of!(GlowcapIrohConfig, reachability) == GLOWCAP_IROH_CONFIG_REACHABILITY_OFF);
	assert!(offset_of!(GlowcapIrohConfig, connect_timeout_ms) == GLOWCAP_IROH_CONFIG_CONNECT_TIMEOUT_MS_OFF);
	assert!(offset_of!(GlowcapIrohConfig, idle_timeout_ms) == GLOWCAP_IROH_CONFIG_IDLE_TIMEOUT_MS_OFF);
	assert!(offset_of!(GlowcapIrohConfig, worker_threads) == GLOWCAP_IROH_CONFIG_WORKER_THREADS_OFF);
};

// The raw extern block is generated (`iroh_fns_gen.rs`, `zig build
// gen-binding-rust-ffi`): types reflected from the Zig exports, parameter
// names from the generated C header. Re-exported here so consumers keep
// their `sys::iroh::glowcap_iroh_*` paths.
pub use super::iroh_fns_gen::*;
