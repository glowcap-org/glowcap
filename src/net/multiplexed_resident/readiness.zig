//! Readiness vocabulary for multiplexed residents.
//!
//! A resident reports readiness through one pollable descriptor and drains
//! stable records into caller-owned storage. These names describe that edge
//! between the resident and the runtime; they own no connection state.

/// `try_read` and `try_write` return this when the operation cannot make
/// progress without blocking. Distinct from 0 (clean end of stream on read; a
/// full window's zero-byte write) and -1 (a dead connection). The iroh
/// sidecar's `PANCAKE_IROH_WOULD_BLOCK` is the same value, so its trampolines
/// pass results through unchanged.
pub const would_block: isize = -2;

pub const ContractError = error{ProviderContract};

/// Readiness bits in `ReadyEvent.events`. One drained record may carry
/// several at once.
pub const ev_readable: u32 = 1;
pub const ev_writable: u32 = 2;
pub const ev_closed: u32 = 4;
pub const ev_accept: u32 = 8;
pub const ev_connect: u32 = 16;
pub const ev_listen: u32 = 32;

/// One drained readiness record. `subject` is the connection id for
/// connection events, the caller's request id for `ev_connect`, and the
/// driver-minted listener route id for `ev_listen` / `ev_accept`.
/// Provider-owned connection ids are stable and never reused for the resident's
/// lifetime; request and listener ids belong to the caller's namespace within
/// this runtime.
pub const ReadyEvent = struct {
    subject: usize,
    events: u32,
};
