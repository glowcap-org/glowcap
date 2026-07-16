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

use core::ffi::{c_int, c_uchar};

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
// `drain_ready` record. A record may carry several at once.
pub const PANCAKE_IROH_EV_READABLE: u32 = 1;
pub const PANCAKE_IROH_EV_WRITABLE: u32 = 2;
pub const PANCAKE_IROH_EV_CLOSED: u32 = 4;
pub const PANCAKE_IROH_EV_ACCEPT: u32 = 8;

/// One readiness record drained by `pancake_iroh_netlayer_drain_ready` — the
/// `#[repr(C)]` counterpart of the header's `PancakeIrohReadyEvent`. `conn` is
/// null for an accept record (claim it with `try_accept`) and otherwise the ready
/// connection's handle; `events` is the `PANCAKE_IROH_EV_*` bitset.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct PancakeIrohReadyEvent {
	pub conn: *mut PancakeIrohConn,
	pub events: u32,
}

// Pin the hand-mirrored layout on LP64 (the linux x86_64/aarch64 targets the
// gates run), the same posture as `sys::driver`'s action pin: a field added or
// reordered on either side moves an offset and fails the build loudly instead
// of misrouting the first drained record. Expected values come from
// `layouts_gen` (`zig build gen-binding-ffi-layouts`), reflected off the real
// Zig `PancakeIrohReadyEvent`.
const _: () = {
	use core::mem::{offset_of, size_of};
	assert!(size_of::<PancakeIrohReadyEvent>() == PANCAKE_IROH_READY_EVENT_SIZE);
	assert!(offset_of!(PancakeIrohReadyEvent, conn) == PANCAKE_IROH_READY_EVENT_CONN_OFF);
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

extern "C" {
	pub fn pancake_iroh_netlayer_new(
		secret_seed: *const c_uchar,
		secret_seed_len: usize,
		config: *const PancakeIrohConfig,
		out_netlayer: *mut *mut PancakeIrohNetlayer,
	) -> c_int;
	pub fn pancake_iroh_netlayer_close(netlayer: *mut PancakeIrohNetlayer);
	pub fn pancake_iroh_netlayer_release(netlayer: *mut PancakeIrohNetlayer);
	pub fn pancake_iroh_netlayer_node_id(
		netlayer: *mut PancakeIrohNetlayer,
		out: *mut c_uchar,
		cap: usize,
		out_len: *mut usize,
	) -> c_int;
	pub fn pancake_iroh_netlayer_direct_addrs(
		netlayer: *mut PancakeIrohNetlayer,
		out: *mut c_uchar,
		cap: usize,
		out_len: *mut usize,
	) -> c_int;
	pub fn pancake_iroh_conn_release(conn: *mut PancakeIrohConn);

	// The event-driven loop surface (ADR-0057): the netlayer's one I/O model.
	// Park on the readiness fd, drain records when it signals, and drive
	// non-blocking byte I/O, one task serves many connections.
	pub fn pancake_iroh_netlayer_readiness_fd(netlayer: *mut PancakeIrohNetlayer) -> c_int;
	pub fn pancake_iroh_netlayer_drain_ready(
		netlayer: *mut PancakeIrohNetlayer,
		out_events: *mut PancakeIrohReadyEvent,
		out_cap: usize,
		out_count: *mut usize,
	) -> c_int;
	pub fn pancake_iroh_netlayer_try_accept(
		netlayer: *mut PancakeIrohNetlayer,
		out_conn: *mut *mut PancakeIrohConn,
	) -> c_int;
	pub fn pancake_iroh_netlayer_try_connect(
		netlayer: *mut PancakeIrohNetlayer,
		node_id: *const c_uchar,
		node_id_len: usize,
		addr_hints: *const c_uchar,
		addr_hints_len: usize,
		out_conn: *mut *mut PancakeIrohConn,
	) -> c_int;
	pub fn pancake_iroh_conn_try_read(
		conn: *mut PancakeIrohConn,
		buf: *mut c_uchar,
		len: usize,
		out_read: *mut usize,
	) -> c_int;
	pub fn pancake_iroh_conn_try_write(
		conn: *mut PancakeIrohConn,
		buf: *const c_uchar,
		len: usize,
		out_written: *mut usize,
	) -> c_int;

	// The iroh transport archive carries its own thread-local last-error, read
	// through `pancake_iroh_last_error` rather than the ocapn family's
	// `pancake_last_error`.
	pub fn pancake_iroh_last_error(out_buf: *mut c_uchar, cap: usize) -> usize;
	pub fn pancake_iroh_clear_last_error();
}
