//! C-stable transport provider packages. A package contains one or more
//! profiles, each tagged with the execution model it actually implements.
//! Stream transports keep per-listener/per-connection handles and readiness
//! descriptors; multiplexed transports keep one shared readiness descriptor and
//! stable connection ids through `PancakeMultiplexedTransport`. The driver normalizes
//! registration and locator semantics, not incompatible ownership models.

const model = @import("model");
const locator = @import("locator.zig");

pub const PANCAKE_TRANSPORT_PROVIDER_ABI_VERSION: u32 = 1;
pub const PANCAKE_TRANSPORT_PROFILE_ABI_VERSION: u32 = 1;
pub const PANCAKE_STREAM_TRANSPORT_ABI_VERSION: u32 = 1;
pub const PANCAKE_TRANSPORT_EXEC_STREAM: u32 = 1;
pub const PANCAKE_TRANSPORT_EXEC_MULTIPLEXED: u32 = 2;

pub const PANCAKE_DESIGNATOR_SCHEME_ADDRESS: u32 = 0;
pub const PANCAKE_DESIGNATOR_SCHEME_KEY: u32 = 1;

pub const PANCAKE_SEALED_CHANNEL_NONE: u32 = 0;
pub const PANCAKE_SEALED_CHANNEL_NOISE_XK: u32 = 1;

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
};

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
    };
}

pub const PancakeStreamStartConnectFn = *const fn (
    ctx: ?*anyopaque,
    locator_view: ?*const locator.PancakeLocatorView,
    out_attempt: ?*?*anyopaque,
    out_readiness_fd: ?*i32,
) callconv(.c) i32;

pub const PancakeStreamFinishConnectFn = *const fn (
    attempt: ?*anyopaque,
    out_conn: ?*?*anyopaque,
    out_readiness_fd: ?*i32,
) callconv(.c) i32;

pub const PancakeStreamCancelConnectFn = *const fn (
    attempt: ?*anyopaque,
) callconv(.c) void;

pub const PancakeStreamListenFn = *const fn (
    ctx: ?*anyopaque,
    requested_designator: ?[*]const u8,
    requested_designator_len: usize,
    identity_designator: ?[*]const u8,
    identity_designator_len: usize,
    out_listener: ?*?*anyopaque,
) callconv(.c) i32;

pub const PancakeStreamListenerWaitFn = *const fn (
    ctx: ?*anyopaque,
    listener: ?*anyopaque,
    timeout_ms: i32,
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
) callconv(.c) i32;

/// Validate and canonicalize a replacement locator for an active listener,
/// projecting the provider-owned result through the synchronous sink.
pub const PancakeTransportListenerAdvertiseFn = *const fn (
    listener_ctx: ?*anyopaque,
    locator_view: ?*const locator.PancakeLocatorView,
    sink_ctx: ?*anyopaque,
    sink: locator.PancakeLocatorSinkFn,
) callconv(.c) i32;

pub const PancakeStreamAcceptFn = *const fn (
    ctx: ?*anyopaque,
    listener: ?*anyopaque,
    out_conn: ?*?*anyopaque,
    out_readiness_fd: ?*i32,
) callconv(.c) i32;

pub const PancakeStreamListenerCloseFn = *const fn (
    ctx: ?*anyopaque,
    listener: ?*anyopaque,
) callconv(.c) void;

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
) callconv(.c) void;

/// One stream-native transport profile. Connection callbacks are required;
/// staged dial and listen are each complete or absent operation groups. A
/// dial attempt owns its readiness descriptor until exactly one finish or
/// cancel consumes it. Callbacks
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
    listener_wait_ready: ?PancakeStreamListenerWaitFn,
    listener_wait_acceptable: ?PancakeStreamListenerWaitFn,
    listener_readiness_fd: ?PancakeStreamListenerReadinessFdFn,
    listener_locator: ?PancakeTransportListenerLocatorFn,
    listener_advertise: ?PancakeTransportListenerAdvertiseFn,
    accept: ?PancakeStreamAcceptFn,
    listener_close: ?PancakeStreamListenerCloseFn,
    read: ?PancakeStreamReadFn,
    write_all: ?PancakeStreamWriteAllFn,
    conn_close: ?PancakeStreamConnCloseFn,
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

pub const PancakeTransportRetainFn = *const fn (ctx: ?*anyopaque) callconv(.c) i32;
pub const PancakeTransportReleaseFn = *const fn (ctx: ?*anyopaque) callconv(.c) void;

/// A provider package installed atomically through the driver's generic
/// registration verb. The driver copies every table and retains one package
/// lease before publication; it releases that lease only after all listeners,
/// connections, and copied callbacks have retired.
pub const PancakeTransportProvider = extern struct {
    abi_version: u32,
    struct_size: usize,
    entries: ?[*]const PancakeTransportProviderEntry,
    entry_count: usize,
    lease_ctx: ?*anyopaque,
    retain: ?PancakeTransportRetainFn,
    release: ?PancakeTransportReleaseFn,
};
