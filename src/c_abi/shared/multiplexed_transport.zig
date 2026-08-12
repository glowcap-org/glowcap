//! The multiplexed-transport table, as C layout only (ADR-0112): the shape a
//! transport archive fills when one readiness descriptor serves many stable
//! connection ids. Drained ready records and non-blocking per-connection
//! try-I/O plug into the driver archive (`libpancake_driver`) across a
//! compulsory artifact boundary (a sidecar no Zig archive can contain).
//!
//! This leaf declares no `export fn` (the `c_abi_shared` charter): the
//! transport archive exports one filler for the table, and the driver archive
//! adapts the filled table back into the Zig `net.MultiplexedResident`
//! contract. Nothing allocates across the table: listener metadata and bytes
//! land in caller buffers, events drain into caller arrays, and connection ids
//! are the transport runtime's stable integers, never addresses.
//!
//! Every function is called from the one thread that steps the loop, and
//! `ctx` must outlive its registration.

const locator = @import("locator.zig");
const transport_provider = @import("transport_provider.zig");

/// `try_read` / `try_write` result when the operation cannot progress
/// without blocking. Distinct from 0 (clean end of stream on read; a full
/// window's zero-byte write) and -1 (a dead connection). The same value as
/// the Zig contract's `net.multiplexed_resident.would_block` and the iroh
/// sidecar's `PANCAKE_IROH_WOULD_BLOCK`, so trampolines pass results through
/// unchanged.
pub const PANCAKE_MULTIPLEXED_WOULD_BLOCK: isize = -2;

/// Readiness bits in `PancakeMultiplexedReadyEvent.events`. One drained record may
/// carry several at once.
pub const PANCAKE_MULTIPLEXED_EV_READABLE: u32 = 1;
pub const PANCAKE_MULTIPLEXED_EV_WRITABLE: u32 = 2;
pub const PANCAKE_MULTIPLEXED_EV_CLOSED: u32 = 4;
pub const PANCAKE_MULTIPLEXED_EV_ACCEPT: u32 = 8;
pub const PANCAKE_MULTIPLEXED_EV_CONNECT: u32 = 16;

/// Version of the required `PancakeMultiplexedTransport` prefix. Registrants also set
/// `struct_size`, so a loop can reject an older table without reading beyond
/// the memory its provider supplied and can accept a future tail it does not
/// need.
pub const PANCAKE_MULTIPLEXED_TRANSPORT_ABI_VERSION: u32 = 1;

/// One drained readiness record. `subject` is the connection id for
/// connection events, the caller's request id for a connect event, and the
/// driver-minted listener route id for an accept event.
pub const PancakeMultiplexedReadyEvent = extern struct {
    subject: u64,
    events: u32,
};

/// The runtime's one OS-pollable readiness descriptor. Level-shaped by
/// contract: it reads ready while drained records are pending.
pub const PancakeMultiplexedReadinessFdFn = *const fn (ctx: ?*anyopaque) callconv(.c) i32;

/// Drain up to `cap` pending records into `out`, clearing the descriptor's
/// coalesced wake. Returns how many records were written.
pub const PancakeMultiplexedDrainReadyFn = *const fn (
    ctx: ?*anyopaque,
    out: ?[*]PancakeMultiplexedReadyEvent,
    cap: usize,
) callconv(.c) usize;

/// Begin a dial toward a complete borrowed locator without waiting for
/// transport completion. Completion arrives as a connect record carrying
/// `request_id`. Returns `PANCAKE_OK` or a `PANCAKE_ERR_*` refusal.
pub const PancakeMultiplexedStartConnectFn = *const fn (
    ctx: ?*anyopaque,
    request_id: u64,
    locator_view: ?*const locator.PancakeLocatorView,
) callconv(.c) i32;

/// Claim the connection a completed connect record announced, writing its
/// id into `*out_conn`. A failed dial surfaces its `PANCAKE_ERR_*` reason
/// here.
pub const PancakeMultiplexedFinishConnectFn = *const fn (
    ctx: ?*anyopaque,
    request_id: u64,
    out_conn: ?*u64,
) callconv(.c) i32;

/// Claim one externally established provider connection by its stable,
/// provider-scoped subject. Success transfers one connection ownership edge
/// to the driver; `conn_close` retires that edge.
pub const PancakeMultiplexedClaimExternalFn = *const fn (
    ctx: ?*anyopaque,
    subject: u64,
    out_conn: ?*u64,
) callconv(.c) i32;

/// Begin accepting one provider profile through the runtime. `route_id` is minted
/// by the driver and must be the subject of this listener's accept events;
/// `transport` is the selected package entry, not a second dispatch guess. A nonempty
/// `requested_designator` is the identity or address the caller expects this
/// provider to own; empty asks the provider to publish its canonical
/// designator. On success `out_listener` receives the provider-owned handle
/// passed to the locator, accept, and stop callbacks.
pub const PancakeMultiplexedStartListenFn = *const fn (
    ctx: ?*anyopaque,
    route_id: u64,
    transport: ?[*]const u8,
    transport_len: usize,
    requested_designator: ?[*]const u8,
    requested_designator_len: usize,
    out_listener: ?*?*anyopaque,
) callconv(.c) i32;

/// Claim one accepted connection from `listener_ctx` into `out_conn`.
/// `PANCAKE_ERR_WOULD_BLOCK`
/// means the coalesced accept queue has drained; other failures use the normal
/// `PANCAKE_ERR_*` vocabulary.
pub const PancakeMultiplexedFinishAcceptFn = *const fn (
    listener_ctx: ?*anyopaque,
    out_conn: ?*u64,
) callconv(.c) i32;

/// Stop accepting. Idempotent; the runtime and dial side stay alive.
pub const PancakeMultiplexedStopListenFn = *const fn (listener_ctx: ?*anyopaque) callconv(.c) void;

/// One subject id (a dial's request id, or a connection id) and no result:
/// the shape `cancel_connect` and `conn_close` share. One typedef because
/// the two signatures are identical; each field's contract is on the field.
pub const PancakeMultiplexedSubjectFn = *const fn (ctx: ?*anyopaque, subject: u64) callconv(.c) void;

/// Read into `buf`: bytes read, 0 on clean end of stream, -1 on a dead
/// connection, `PANCAKE_MULTIPLEXED_WOULD_BLOCK` when nothing is pending.
pub const PancakeMultiplexedTryReadFn = *const fn (
    ctx: ?*anyopaque,
    conn: u64,
    buf: ?[*]u8,
    cap: usize,
) callconv(.c) isize;

/// Write from `bytes`: bytes consumed (the resident owns them once counted),
/// -1 on a dead connection, `PANCAKE_MULTIPLEXED_WOULD_BLOCK` or 0 when the window is
/// full. A writable record follows either refusal.
pub const PancakeMultiplexedTryWriteFn = *const fn (
    ctx: ?*anyopaque,
    conn: u64,
    bytes: ?[*]const u8,
    len: usize,
) callconv(.c) isize;

/// Write the channel-authenticated remote durable key (32 bytes) into
/// `out_key` and return exactly 1 when this transport proves one (iroh's remote
/// node id); return exactly 0 on a transport whose channel proves nothing. Any
/// other status is a provider contract violation and fails the driver loop.
pub const PancakeMultiplexedConnRemoteKeyFn = *const fn (
    ctx: ?*anyopaque,
    conn: u64,
    out_key: ?[*]u8,
) callconv(.c) i32;

/// One multiplexed transport, as a filled function table: the
/// mirror of `net.MultiplexedResident.VTable` with C-stable types. Readiness and
/// connection callbacks are mandatory; each dial/listen operation group is
/// either complete or absent, so callback presence is the sole capability
/// authority. Field contracts are on the typedefs above and in the generated
/// header.
pub const PancakeMultiplexedTransport = extern struct {
    abi_version: u32,
    struct_size: usize,
    ctx: ?*anyopaque,
    readiness_fd: ?PancakeMultiplexedReadinessFdFn,
    drain_ready: ?PancakeMultiplexedDrainReadyFn,
    start_connect: ?PancakeMultiplexedStartConnectFn,
    finish_connect: ?PancakeMultiplexedFinishConnectFn,
    claim_external: ?PancakeMultiplexedClaimExternalFn = null,
    /// Abandon a dial by request id. Idempotent, and valid after its connect
    /// record was announced but before `finish_connect` claimed it: the
    /// resident releases the unclaimed connection.
    cancel_connect: ?PancakeMultiplexedSubjectFn,
    start_listen: ?PancakeMultiplexedStartListenFn,
    listener_locator: ?transport_provider.PancakeTransportListenerLocatorFn,
    listener_advertise: ?transport_provider.PancakeTransportListenerAdvertiseFn,
    finish_accept: ?PancakeMultiplexedFinishAcceptFn,
    stop_listen: ?PancakeMultiplexedStopListenFn,
    try_read: ?PancakeMultiplexedTryReadFn,
    try_write: ?PancakeMultiplexedTryWriteFn,
    /// Close and release one connection. Later records naming the id drain
    /// to nothing.
    conn_close: ?PancakeMultiplexedSubjectFn,
    conn_remote_key: ?PancakeMultiplexedConnRemoteKeyFn,
};
