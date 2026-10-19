//! The multiplexed-transport table, as C layout only (ADR-0024): the shape a
//! transport archive fills when one readiness descriptor serves many stable
//! connection ids. Drained ready records and non-blocking per-connection
//! try-I/O plug into the driver archive (`libglowcap_driver`) across a
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
//! Handle-producing callbacks transfer outputs only on `GLOWCAP_OK`. On any
//! error the provider retains and cleans partial work and leaves output slots
//! untouched. Finish callbacks consume the announced operation on every return.

const locator = @import("locator.zig");
const transport_provider = @import("transport_provider.zig");

/// Readiness bits in `GlowcapMultiplexedReadyEvent.events`. One drained record may
/// carry several at once.
pub const GLOWCAP_MULTIPLEXED_EV_READABLE: u32 = 1;
pub const GLOWCAP_MULTIPLEXED_EV_WRITABLE: u32 = 2;
pub const GLOWCAP_MULTIPLEXED_EV_CLOSED: u32 = 4;
pub const GLOWCAP_MULTIPLEXED_EV_ACCEPT: u32 = 8;
pub const GLOWCAP_MULTIPLEXED_EV_CONNECT: u32 = 16;
pub const GLOWCAP_MULTIPLEXED_EV_LISTEN: u32 = 32;

/// Version of the required `GlowcapMultiplexedTransport` prefix. Registrants also set
/// `struct_size`, so a loop can reject an older table without reading beyond
/// the memory its provider supplied and can accept a future tail it does not
/// need.
pub const GLOWCAP_MULTIPLEXED_TRANSPORT_ABI_VERSION: u32 = 1;

/// One drained readiness record. `subject` is the connection id for
/// connection events, the caller's request id for a connect event, and the
/// driver-minted listener route id for listen and accept events.
pub const GlowcapMultiplexedReadyEvent = extern struct {
    subject: u64,
    events: u32,
};

/// The runtime's one OS-pollable readiness descriptor. Level-shaped by
/// contract: it reads ready while drained records are pending.
pub const GlowcapMultiplexedReadinessFdFn = *const fn (ctx: ?*anyopaque) callconv(.c) i32;

/// Drain up to `cap` pending records into `out`, clearing the descriptor's
/// coalesced wake. On `GLOWCAP_OK`, writes the number of records to `out_count`
/// and leaves `out_failure` empty. On failure, leaves `out_count` untouched and
/// describes the exact provider failure in `out_failure`.
pub const GlowcapMultiplexedDrainReadyFn = *const fn (
    ctx: ?*anyopaque,
    out: ?[*]GlowcapMultiplexedReadyEvent,
    cap: usize,
    out_count: ?*usize,
    out_failure: ?*transport_provider.GlowcapProviderFailure,
) callconv(.c) i32;

/// Begin a dial toward a complete borrowed locator without waiting for
/// transport completion. `origin` names the session that introduced a handoff
/// dial, or is null (`GlowcapDialOrigin`). Completion arrives as a connect
/// record carrying `request_id`. Returns `GLOWCAP_OK` or a `GLOWCAP_ERR_*`
/// refusal.
pub const GlowcapMultiplexedStartConnectFn = *const fn (
    ctx: ?*anyopaque,
    request_id: u64,
    locator_view: ?*const locator.GlowcapLocatorView,
    options: ?*const transport_provider.GlowcapTransportOperationOptions,
    origin: ?*const transport_provider.GlowcapDialOrigin,
    out_failure: ?*transport_provider.GlowcapProviderFailure,
) callconv(.c) i32;

/// Claim the connection a completed connect record announced, writing its
/// id into `*out_conn`. A failed dial surfaces its `GLOWCAP_ERR_*` reason
/// here.
pub const GlowcapMultiplexedFinishConnectFn = *const fn (
    ctx: ?*anyopaque,
    request_id: u64,
    out_conn: ?*u64,
    out_failure: ?*transport_provider.GlowcapProviderFailure,
) callconv(.c) i32;

/// Claim one externally established provider connection by its stable,
/// provider-scoped subject. Success transfers one connection ownership edge
/// to the driver. `conn_close` retires that edge.
pub const GlowcapMultiplexedClaimExternalFn = *const fn (
    ctx: ?*anyopaque,
    subject: u64,
    out_conn: ?*u64,
    out_failure: ?*transport_provider.GlowcapProviderFailure,
) callconv(.c) i32;

/// Begin accepting one provider profile through the runtime. `route_id` is minted
/// by the driver and must be the subject of this listener's accept events.
/// `transport` is the selected package entry, not a second dispatch guess. A nonempty
/// `requested_designator` is the identity or address the caller expects this
/// provider to own. Empty asks the provider to publish its canonical
/// designator. `identity_designator` is the durable key of the Host the
/// listener serves, which a key-designated profile publishes, exactly as the
/// stream listen receives it. Immediate completion writes `GLOWCAP_LISTEN_READY` and the
/// provider-owned listener handle. Externally paced setup writes
/// `GLOWCAP_LISTEN_PENDING`, then emits a listen event carrying `route_id`.
/// PENDING is legal only when the table supplies both `finish_listen` and
/// `cancel_listen`. An immediate-only provider must return READY.
pub const GlowcapMultiplexedListenFn = *const fn (
    ctx: ?*anyopaque,
    route_id: u64,
    transport: ?[*]const u8,
    transport_len: usize,
    requested_designator: ?[*]const u8,
    requested_designator_len: usize,
    identity_designator: ?[*]const u8,
    identity_designator_len: usize,
    options: ?*const transport_provider.GlowcapTransportOperationOptions,
    out_result: ?*transport_provider.GlowcapListenResult,
    out_failure: ?*transport_provider.GlowcapProviderFailure,
) callconv(.c) i32;

pub const GlowcapMultiplexedFinishListenFn = *const fn (
    ctx: ?*anyopaque,
    route_id: u64,
    out_listener: ?*?*anyopaque,
    out_failure: ?*transport_provider.GlowcapProviderFailure,
) callconv(.c) i32;

/// Claim one accepted connection from `listener_ctx` into `out_conn`.
/// `GLOWCAP_ERR_WOULD_BLOCK`
/// means the coalesced accept queue has drained. Other failures use the normal
/// `GLOWCAP_ERR_*` vocabulary.
pub const GlowcapMultiplexedFinishAcceptFn = *const fn (
    listener_ctx: ?*anyopaque,
    out_conn: ?*u64,
    out_failure: ?*transport_provider.GlowcapProviderFailure,
) callconv(.c) i32;

/// Stop accepting. Idempotent. The runtime and dial side stay alive. An
/// asynchronously retiring provider returns GLOWCAP_ERR_WOULD_BLOCK with an
/// empty failure, emits EV_LISTEN for the route after joining, then returns
/// the claim-once terminal outcome when called again.
pub const GlowcapMultiplexedStopListenFn = *const fn (
    listener_ctx: ?*anyopaque,
    out_failure: ?*transport_provider.GlowcapProviderFailure,
) callconv(.c) i32;

/// One subject id (a dial's request id, or a connection id) and no result:
/// the shape `cancel_connect` and `conn_close` share. One typedef because
/// the two signatures are identical. Each field's contract is on the field.
pub const GlowcapMultiplexedSubjectFn = *const fn (
    ctx: ?*anyopaque,
    subject: u64,
    out_failure: ?*transport_provider.GlowcapProviderFailure,
) callconv(.c) i32;

pub const GlowcapMultiplexedConnTakeFailureFn = *const fn (
    ctx: ?*anyopaque,
    conn: u64,
    out_failure: ?*transport_provider.GlowcapProviderFailure,
) callconv(.c) void;

/// Read into `buf`: bytes read, 0 on clean end of stream, -1 on a dead
/// connection, `GLOWCAP_TRANSPORT_WOULD_BLOCK` when nothing is pending.
pub const GlowcapMultiplexedTryReadFn = *const fn (
    ctx: ?*anyopaque,
    conn: u64,
    buf: ?[*]u8,
    cap: usize,
) callconv(.c) isize;

/// Write from `bytes`: bytes consumed (the resident owns them once counted),
/// -1 on a dead connection, `GLOWCAP_TRANSPORT_WOULD_BLOCK` or 0 when the window is
/// full. A writable record follows either refusal.
pub const GlowcapMultiplexedTryWriteFn = *const fn (
    ctx: ?*anyopaque,
    conn: u64,
    bytes: ?[*]const u8,
    len: usize,
) callconv(.c) isize;

/// Write the channel-authenticated remote durable key (32 bytes) into
/// `out_key` and return exactly 1 when this transport proves one (iroh's remote
/// node id). Return exactly 0 on a transport whose channel proves nothing. Any
/// other status is a provider contract violation and fails the driver loop.
pub const GlowcapMultiplexedConnRemoteKeyFn = *const fn (
    ctx: ?*anyopaque,
    conn: u64,
    out_key: ?[*]u8,
) callconv(.c) i32;

/// One multiplexed transport, as a filled function table: the
/// mirror of `net.MultiplexedResident.VTable` with C-stable types. Readiness and
/// connection callbacks are mandatory. Dial and the base listener capability
/// are each complete or absent. Listener completion is a separate optional
/// pair: `finish_listen` and `cancel_listen` are both present exactly when
/// `listen` may return PENDING. Callback presence is the sole capability
/// authority. Field contracts are on the typedefs above and in the generated
/// header.
pub const GlowcapMultiplexedTransport = extern struct {
    abi_version: u32,
    struct_size: usize,
    ctx: ?*anyopaque,
    readiness_fd: ?GlowcapMultiplexedReadinessFdFn,
    drain_ready: ?GlowcapMultiplexedDrainReadyFn,
    start_connect: ?GlowcapMultiplexedStartConnectFn,
    finish_connect: ?GlowcapMultiplexedFinishConnectFn,
    claim_external: ?GlowcapMultiplexedClaimExternalFn = null,
    /// Abandon a dial by request id. Idempotent, and valid after its connect
    /// record was announced but before `finish_connect` claimed it: the
    /// resident releases the unclaimed connection. Asynchronous retirement
    /// returns success first, emits CONNECT when joined, and makes the exact
    /// cleanup chain claimable by a repeated call for the same request id.
    cancel_connect: ?GlowcapMultiplexedSubjectFn,
    listen: ?GlowcapMultiplexedListenFn,
    /// Consume one PENDING route on every return. Present exactly with
    /// `cancel_listen`. Absent for an immediate-only listener.
    finish_listen: ?GlowcapMultiplexedFinishListenFn,
    /// Abandon one PENDING route before finish. Present exactly with
    /// `finish_listen` and idempotent after the route has already failed. It
    /// also claims an active listener's asynchronous stop outcome after the
    /// provider emits LISTEN for that route.
    cancel_listen: ?GlowcapMultiplexedSubjectFn,
    listener_locator: ?transport_provider.GlowcapTransportListenerLocatorFn,
    listener_advertise: ?transport_provider.GlowcapTransportListenerAdvertiseFn,
    listener_restoration_state: ?transport_provider.GlowcapTransportListenerRestorationStateFn = null,
    finish_accept: ?GlowcapMultiplexedFinishAcceptFn,
    stop_listen: ?GlowcapMultiplexedStopListenFn,
    try_read: ?GlowcapMultiplexedTryReadFn,
    try_write: ?GlowcapMultiplexedTryWriteFn,
    /// Close and release one connection. Asynchronous retirement returns
    /// success first, emits CLOSED after joining, and makes the exact cleanup
    /// chain claimable by a repeated call. Later records then drain to nothing.
    conn_close: ?GlowcapMultiplexedSubjectFn,
    conn_take_failure: ?GlowcapMultiplexedConnTakeFailureFn,
    conn_remote_key: ?GlowcapMultiplexedConnRemoteKeyFn,
};
