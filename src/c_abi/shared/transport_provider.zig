//! C-stable transport provider packages. A package contains one or more
//! profiles, each tagged with the execution model it actually implements.
//! Stream transports keep per-listener/per-connection handles and readiness
//! descriptors; multiplexed transports keep one shared readiness descriptor and
//! stable connection ids through `PancakeMultiplexedTransport`. The driver normalizes
//! registration and locator semantics, not incompatible ownership models.
//!
//! Handle-producing callbacks transfer outputs only when they return
//! `PANCAKE_OK`. On every other status the provider retains and cleans any
//! partial work and leaves output slots untouched. `finish_connect` and
//! `finish_listen` consume their input attempt on every return; cancel is only
//! for an attempt that was never passed to finish.

const std = @import("std");
const model = @import("model");
const foundation = @import("foundation");
const locator = @import("locator.zig");

pub const PANCAKE_TRANSPORT_PROVIDER_ABI_VERSION: u32 = 1;
pub const PANCAKE_TRANSPORT_PROFILE_ABI_VERSION: u32 = 1;
pub const PANCAKE_STREAM_TRANSPORT_ABI_VERSION: u32 = 1;
pub const PANCAKE_LISTEN_READY: u32 = 0;
pub const PANCAKE_LISTEN_PENDING: u32 = 1;
pub const PANCAKE_TRANSPORT_EXEC_STREAM: u32 = 1;
pub const PANCAKE_TRANSPORT_EXEC_MULTIPLEXED: u32 = 2;

pub const PANCAKE_DESIGNATOR_SCHEME_ADDRESS: u32 = 0;
pub const PANCAKE_DESIGNATOR_SCHEME_KEY: u32 = 1;

pub const PANCAKE_SEALED_CHANNEL_NONE: u32 = 0;
pub const PANCAKE_SEALED_CHANNEL_NOISE_XK: u32 = 1;

pub const PANCAKE_WIRE_FRAMING_BYTE_STREAM: u32 = 0;
pub const PANCAKE_WIRE_FRAMING_MESSAGE: u32 = 1;

/// Optional carrier acquisition or byte-lifecycle phase on a structured
/// provider failure. Zero means that this provider cannot name a carrier
/// phase; progress states such as would-block never use this field.
pub const PANCAKE_CARRIER_PHASE_NONE: u32 = 0;
pub const PANCAKE_CARRIER_PHASE_RESOLVE: u32 = 1;
pub const PANCAKE_CARRIER_PHASE_CONNECT: u32 = 2;
pub const PANCAKE_CARRIER_PHASE_SECURE_HANDSHAKE: u32 = 3;
pub const PANCAKE_CARRIER_PHASE_WEBSOCKET_UPGRADE: u32 = 4;
pub const PANCAKE_CARRIER_PHASE_REGISTRATION: u32 = 5;
pub const PANCAKE_CARRIER_PHASE_RECEIVE: u32 = 6;
pub const PANCAKE_CARRIER_PHASE_TRANSMIT: u32 = 7;
pub const PANCAKE_CARRIER_PHASE_SHUTDOWN: u32 = 8;

/// The C code for a carrier-failure phase, derived from the enum tag name so
/// the driver archive and every provider archive encode from this one table
/// rather than each keeping a hand-written switch. A phase with no constant
/// here fails to compile at the caller instead of shipping an unknown code.
pub fn carrierPhaseCode(phase: anytype) u32 {
    return switch (phase) {
        inline else => |tag| @field(@This(), "PANCAKE_CARRIER_PHASE_" ++ upperTag(@tagName(tag))),
    };
}

fn upperTag(comptime name: []const u8) *const [name.len]u8 {
    comptime {
        var buf: [name.len]u8 = undefined;
        _ = std.ascii.upperString(&buf, name);
        const frozen = buf;
        return &frozen;
    }
}
pub const PANCAKE_CARRIER_DETAIL_PEER_ALERT: u32 = 1 << 0;
pub const PANCAKE_CARRIER_DETAIL_ENGINE_CODE: u32 = 1 << 1;

/// Locator and channel semantics for one transport symbol. A provider entry
/// points at one profile and one execution implementation, keeping semantic
/// authority independent of the implementation's I/O model.
pub const PancakeTransportProfile = extern struct {
    abi_version: u32,
    struct_size: usize,
    transport_name: ?[*]const u8,
    transport_name_len: usize,
    designator_scheme: u32,
    sealed_channel: u32,
    wire_framing: u32,
    max_packet_bytes: usize,
};

/// Borrowed provider-owned configuration for one dial or listener operation.
/// The driver validates the null/size shape and forwards it unchanged to the
/// provider selected by the locator or transport symbol. The provider owns the
/// payload type and must copy any values retained after the start callback.
/// A null pointer with size zero means inherit provider defaults.
pub const PancakeTransportOperationOptions = extern struct {
    data: ?*const anyopaque,
    size: usize,
};

/// Structured failure output for provider callbacks that expose this output.
/// The callback receives caller-owned storage and must leave it empty on success.
/// On failure, `result` matches the returned PANCAKE_ERR_* status and
/// `primary_name` names the provider's exact cause. A non-zero
/// `secondary_count` carries the first cleanup/consequence name and its stable
/// result; later consequences are represented by the count. Cause names are
/// immutable process-lifetime identifiers (normally string literals), allowing
/// the driver to retain them without allocating or copying on the wire path.
pub const PancakeProviderFailure = extern struct {
    result: i32,
    carrier_phase: u32,
    carrier_detail_flags: u32,
    carrier_verification_flags: u32,
    carrier_peer_alert: u32,
    carrier_engine_code: i32,
    primary_name: ?[*]const u8,
    primary_name_len: usize,
    secondary_result: i32,
    secondary_name: ?[*]const u8,
    secondary_name_len: usize,
    secondary_count: u32,
};

pub fn emptyProviderFailure() PancakeProviderFailure {
    return .{
        .result = 0,
        .carrier_phase = PANCAKE_CARRIER_PHASE_NONE,
        .carrier_detail_flags = 0,
        .carrier_verification_flags = 0,
        .carrier_peer_alert = 0,
        .carrier_engine_code = 0,
        .primary_name = null,
        .primary_name_len = 0,
        .secondary_result = 0,
        .secondary_name = null,
        .secondary_name_len = 0,
        .secondary_count = 0,
    };
}

/// Move a connection's retained provider failure into the caller's slot and
/// clear it, so one take reports each failure exactly once. Every provider
/// archive's `take_failure` callback is this over its own connection type.
pub fn takeProviderFailure(failure: *PancakeProviderFailure, out_failure: ?*PancakeProviderFailure) void {
    const slot = out_failure orelse return;
    slot.* = failure.*;
    failure.* = std.mem.zeroes(PancakeProviderFailure);
}

pub fn setProviderFailure(out: ?*PancakeProviderFailure, result: i32, cause: anyerror) void {
    const slot = out orelse return;
    const name = @errorName(cause);
    slot.* = emptyProviderFailure();
    slot.result = result;
    slot.primary_name = name.ptr;
    slot.primary_name_len = name.len;
}

/// Project one neutral failure chain onto the fixed provider callback record.
/// The callback's returned status remains the primary classification authority;
/// `secondaryResult` supplies the transport family's stable classification for
/// the first later consequence. Names come from the chain so a failure that
/// crossed an earlier archive boundary is not flattened back to its Zig proxy
/// error name.
pub fn setProviderFailureChain(
    out: ?*PancakeProviderFailure,
    result: i32,
    failure: foundation.FailureChain,
    secondaryResult: anytype,
) void {
    const slot = out orelse return;
    slot.* = emptyProviderFailure();
    const primary_name = failure.primaryName();
    slot.result = result;
    slot.primary_name = primary_name.ptr;
    slot.primary_name_len = primary_name.len;
    const secondary = failure.secondary_cause orelse return;
    const secondary_name = failure.secondaryName().?;
    slot.secondary_result = secondaryResult(secondary);
    slot.secondary_name = secondary_name.ptr;
    slot.secondary_name_len = secondary_name.len;
    slot.secondary_count = failure.secondary_count;
}

pub fn failProviderChain(
    out: ?*PancakeProviderFailure,
    result: i32,
    failure: foundation.FailureChain,
    secondaryResult: anytype,
) i32 {
    setProviderFailureChain(out, result, failure, secondaryResult);
    return result;
}

pub fn providerFailureEmpty(report: PancakeProviderFailure) bool {
    return report.result == 0 and report.carrier_phase == PANCAKE_CARRIER_PHASE_NONE and
        report.carrier_detail_flags == 0 and report.carrier_verification_flags == 0 and
        report.carrier_peer_alert == 0 and report.carrier_engine_code == 0 and
        report.primary_name == null and report.primary_name_len == 0 and
        report.secondary_result == 0 and report.secondary_name == null and
        report.secondary_name_len == 0 and report.secondary_count == 0;
}

pub fn failProvider(out: ?*PancakeProviderFailure, result: i32, cause: anyerror) i32 {
    setProviderFailure(out, result, cause);
    return result;
}

pub fn operationOptionsAreInherited(raw: ?*const PancakeTransportOperationOptions) bool {
    const options = raw orelse return true;
    return options.data == null and options.size == 0;
}

/// Project the model-owned locator/channel semantics into their C layout.
/// Transport archives call this rather than maintaining parallel switches.
pub fn profileFromMetadata(metadata: model.transport.Metadata) PancakeTransportProfile {
    return .{
        .abi_version = PANCAKE_TRANSPORT_PROFILE_ABI_VERSION,
        .struct_size = @sizeOf(PancakeTransportProfile),
        .transport_name = metadata.symbol.ptr,
        .transport_name_len = metadata.symbol.len,
        .designator_scheme = switch (metadata.designator_scheme) {
            .address => PANCAKE_DESIGNATOR_SCHEME_ADDRESS,
            .key => PANCAKE_DESIGNATOR_SCHEME_KEY,
        },
        .sealed_channel = if (metadata.sealed_channel)
            PANCAKE_SEALED_CHANNEL_NOISE_XK
        else
            PANCAKE_SEALED_CHANNEL_NONE,
        .wire_framing = switch (metadata.wire_framing) {
            .byte_stream => PANCAKE_WIRE_FRAMING_BYTE_STREAM,
            .message => PANCAKE_WIRE_FRAMING_MESSAGE,
        },
        .max_packet_bytes = metadata.max_packet_bytes,
    };
}

pub const PancakeStreamStartConnectFn = *const fn (
    ctx: ?*anyopaque,
    locator_view: ?*const locator.PancakeLocatorView,
    options: ?*const PancakeTransportOperationOptions,
    out_attempt: ?*?*anyopaque,
    out_readiness_fd: ?*i32,
    out_failure: ?*PancakeProviderFailure,
) callconv(.c) i32;

pub const PancakeStreamFinishConnectFn = *const fn (
    attempt: ?*anyopaque,
    out_conn: ?*?*anyopaque,
    out_readiness_fd: ?*i32,
    out_failure: ?*PancakeProviderFailure,
) callconv(.c) i32;

pub const PancakeStreamCancelConnectFn = *const fn (
    attempt: ?*anyopaque,
    out_failure: ?*PancakeProviderFailure,
) callconv(.c) i32;

pub const PancakeStreamFinishListenFn = *const fn (
    attempt: ?*anyopaque,
    out_listener: ?*?*anyopaque,
    out_failure: ?*PancakeProviderFailure,
) callconv(.c) i32;

pub const PancakeStreamCancelListenFn = *const fn (
    attempt: ?*anyopaque,
    out_failure: ?*PancakeProviderFailure,
) callconv(.c) i32;

/// Tagged ownership result shared by stream and multiplexed listener setup.
/// READY carries only `listener`. Stream PENDING carries `attempt` plus a
/// readiness descriptor; multiplexed PENDING carries neither because its
/// driver-minted route id and shared descriptor already identify completion.
/// A provider may return PENDING only when its execution table supplies the
/// complete finish/cancel listener-completion pair.
pub const PancakeListenResult = extern struct {
    state: u32,
    listener: ?*anyopaque,
    attempt: ?*anyopaque,
    readiness_fd: i32,
};

pub const PancakeStreamListenFn = *const fn (
    ctx: ?*anyopaque,
    requested_designator: ?[*]const u8,
    requested_designator_len: usize,
    identity_designator: ?[*]const u8,
    identity_designator_len: usize,
    options: ?*const PancakeTransportOperationOptions,
    out_result: ?*PancakeListenResult,
    out_failure: ?*PancakeProviderFailure,
) callconv(.c) i32;

pub const PancakeStreamListenerWaitFn = *const fn (
    ctx: ?*anyopaque,
    listener: ?*anyopaque,
    timeout_ms: i32,
    out_failure: ?*PancakeProviderFailure,
) callconv(.c) i32;

pub const PancakeStreamListenerReadinessFdFn = *const fn (
    ctx: ?*anyopaque,
    listener: ?*anyopaque,
) callconv(.c) i32;

/// Project one listener's complete locator through a synchronous sink. The
/// callback context is the provider-owned stream or multiplexed listener handle;
/// provider may keep every projected view on its stack.
pub const PancakeTransportListenerLocatorFn = *const fn (
    listener_ctx: ?*anyopaque,
    sink_ctx: ?*anyopaque,
    sink: locator.PancakeLocatorSinkFn,
    out_failure: ?*PancakeProviderFailure,
) callconv(.c) i32;

/// Validate and canonicalize a replacement locator for an active listener,
/// projecting the provider-owned result through the synchronous sink.
pub const PancakeTransportListenerAdvertiseFn = *const fn (
    listener_ctx: ?*anyopaque,
    locator_view: ?*const locator.PancakeLocatorView,
    sink_ctx: ?*anyopaque,
    sink: locator.PancakeLocatorSinkFn,
    out_failure: ?*PancakeProviderFailure,
) callconv(.c) i32;

/// Query or copy opaque provider-owned listener restoration state. Writes the
/// complete size to `out_len`; a short output is untouched and returns
/// `PANCAKE_ERR_BUFFER_TOO_SMALL`.
pub const PancakeTransportListenerRestorationStateFn = *const fn (
    listener_ctx: ?*anyopaque,
    out: ?[*]u8,
    cap: usize,
    out_len: ?*usize,
    out_failure: ?*PancakeProviderFailure,
) callconv(.c) i32;

pub const PancakeStreamAcceptFn = *const fn (
    ctx: ?*anyopaque,
    listener: ?*anyopaque,
    out_conn: ?*?*anyopaque,
    out_readiness_fd: ?*i32,
    out_failure: ?*PancakeProviderFailure,
) callconv(.c) i32;

pub const PancakeStreamListenerCloseFn = *const fn (
    ctx: ?*anyopaque,
    listener: ?*anyopaque,
    out_failure: ?*PancakeProviderFailure,
) callconv(.c) i32;

pub const PancakeStreamReadFn = *const fn (
    ctx: ?*anyopaque,
    conn: ?*anyopaque,
    out: ?[*]u8,
    cap: usize,
) callconv(.c) isize;

/// Write the complete borrowed slice before returning. The callback returns
/// `PANCAKE_OK` only after all bytes are consumed; partial progress is not a
/// result in the blocking stream execution model.
pub const PancakeStreamWriteAllFn = *const fn (
    ctx: ?*anyopaque,
    conn: ?*anyopaque,
    bytes: ?[*]const u8,
    len: usize,
) callconv(.c) i32;

pub const PancakeStreamConnCloseFn = *const fn (
    ctx: ?*anyopaque,
    conn: ?*anyopaque,
    out_failure: ?*PancakeProviderFailure,
) callconv(.c) i32;

/// Atomically claim the connection's first retained read/write failure into
/// `out_failure`. Write the all-zero value when no failure remains.
pub const PancakeStreamConnTakeFailureFn = *const fn (
    ctx: ?*anyopaque,
    conn: ?*anyopaque,
    out_failure: ?*PancakeProviderFailure,
) callconv(.c) void;

/// One stream-native transport profile. Connection callbacks are required;
/// staged dial and the base listener capability are each complete or absent
/// operation groups. Listener completion is a separate optional finish/cancel
/// pair; without it `listen` must return READY. A
/// dial attempt owns its readiness descriptor until exactly one finish or
/// cancel consumes it, and a PENDING listener attempt has the same ownership
/// rule. Callbacks
/// return `PANCAKE_OK` or a `PANCAKE_ERR_*` value except `read`, whose
/// byte-count contract is explicit; handles and descriptors remain
/// provider-owned until the matching close callback.
pub const PancakeStreamTransport = extern struct {
    abi_version: u32,
    struct_size: usize,
    ctx: ?*anyopaque,
    start_connect: ?PancakeStreamStartConnectFn,
    finish_connect: ?PancakeStreamFinishConnectFn,
    cancel_connect: ?PancakeStreamCancelConnectFn,
    listen: ?PancakeStreamListenFn,
    finish_listen: ?PancakeStreamFinishListenFn = null,
    cancel_listen: ?PancakeStreamCancelListenFn = null,
    listener_wait_acceptable: ?PancakeStreamListenerWaitFn,
    listener_readiness_fd: ?PancakeStreamListenerReadinessFdFn,
    listener_locator: ?PancakeTransportListenerLocatorFn,
    listener_advertise: ?PancakeTransportListenerAdvertiseFn,
    listener_restoration_state: ?PancakeTransportListenerRestorationStateFn = null,
    accept: ?PancakeStreamAcceptFn,
    listener_close: ?PancakeStreamListenerCloseFn,
    read: ?PancakeStreamReadFn,
    write_all: ?PancakeStreamWriteAllFn,
    conn_close: ?PancakeStreamConnCloseFn,
    conn_take_failure: ?PancakeStreamConnTakeFailureFn,
};

/// One tagged package entry. `implementation` points to
/// `PancakeStreamTransport` for STREAM or `PancakeMultiplexedTransport` for
/// MULTIPLEXED. Multiplexed entries in one package share a runtime exactly when they
/// point to the same implementation table; the table's context and callbacks
/// then have one lease, readiness descriptor, and connection namespace.
pub const PancakeTransportProviderEntry = extern struct {
    profile: ?*const PancakeTransportProfile,
    execution_model: u32,
    implementation: ?*const anyopaque,
};

pub const PancakeTransportRetainFn = *const fn (
    ctx: ?*anyopaque,
    out_failure: ?*PancakeProviderFailure,
) callconv(.c) i32;
pub const PancakeTransportReleaseFn = *const fn (
    ctx: ?*anyopaque,
    out_failure: ?*PancakeProviderFailure,
) callconv(.c) i32;
/// Decide whether two packages produced by this provider implementation carry
/// the same complete effective configuration. The driver calls this only when
/// both packages advertise the same profile set and use this exact callback;
/// return 1 for equivalent and 0 for different.
pub const PancakeTransportProviderSameConfigurationFn = *const fn (
    ctx: ?*anyopaque,
    other_ctx: ?*anyopaque,
) callconv(.c) u8;

/// A provider package installed atomically through the driver's generic
/// registration verb. The driver copies every table and retains one package
/// lease before publication; it releases that lease only after all listeners,
/// connections, and copied callbacks have retired. Re-registering the same
/// profile set is idempotent only when `same_configuration` is the same
/// function and reports equivalent package contexts.
pub const PancakeTransportProvider = extern struct {
    abi_version: u32,
    struct_size: usize,
    entries: ?[*]const PancakeTransportProviderEntry,
    entry_count: usize,
    lease_ctx: ?*anyopaque,
    same_configuration: ?PancakeTransportProviderSameConfigurationFn,
    retain: ?PancakeTransportRetainFn,
    release: ?PancakeTransportReleaseFn,
};
