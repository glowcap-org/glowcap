//! The onion transport's public C ABI — `libpancake_net_transport_onion`.
//!
//! The Tor sibling of the TCP transport (`src/c_abi/net_transport/tcp/`): the same
//! host-driven netlayer boundary, reached through a Tor daemon the deployment
//! already runs. A `PancakeOnionNetlayer` holds where that daemon listens and how
//! it wants to be authenticated; a dial names a version 3 service id and a listen
//! asks Tor for one.
//!
//! Frame movement is identical to TCP's: read a whole owned frame, feed it to the
//! host's peer, step, take outbound, write it back. Only the addressing differs,
//! so the C host's loop is unchanged.
//!
//! Two things a consumer has to know, both of them ADR-0108 decisions rather than
//! implementation details. **pancake starts no Tor**: a netlayer built against
//! endpoints nothing is listening on fails at that call, not at the first dial.
//! And **the service id is an address, not an identity**: Tor proves the far end
//! of the circuit holds the key the address encodes, but the CapTP peer is whoever
//! holds the local endpoint that service forwards to, so nothing here reports a
//! proved peer.
//!
//! This is a *separate archive* from `libpancake_ocapn` (ADR-0059): it imports
//! model types by module and C layouts from `c_abi_shared`, not symbols from the
//! ocapn archive, so it exports only the `pancake_onion_*` family.
//! The transport carries its own per-thread last-error slot, read through
//! `pancake_onion_last_error`.

const std = @import("std");

const net = @import("net");
const model = @import("model");

// The shared C-ABI vocabulary leaf, *not* the ocapn root (ADR-0059).
const c = @import("c_abi_shared");

pub const PANCAKE_ONION_ARCHIVE_FINGERPRINT = c.archive_contract.fingerprint(
    @embedFile("mod.zig"),
    @embedFile("symbols.zig"),
);

pub export fn pancake_onion_archive_fingerprint() u64 {
    return PANCAKE_ONION_ARCHIVE_FINGERPRINT;
}

/// The netlayer handle owns where Tor listens, how to authenticate to it, and the
/// one `std.Io` backend its streams block on. Created and released explicitly by
/// the host; it must outlive every connection and listener made from it.
pub const PancakeOnionNetlayer = opaque {};
/// One onion connection carrying one OCapN session. Owned by the caller; released
/// with `pancake_onion_conn_release`.
pub const PancakeOnionConn = opaque {};
/// A live onion service: the control session that keeps it published and the local
/// endpoint Tor forwards it to. Owned by the caller; released with
/// `pancake_onion_listener_release`, which also withdraws the service.
pub const PancakeOnionListener = opaque {};

const PancakeContext = c.PancakeContext;
const PancakeFrame = c.PancakeFrame;
const PancakeManagedFrame = c.PancakeManagedFrame;

const setLastError = c.setLastError;
const codecFromC = c.codecFromC;

const PANCAKE_OK = c.PANCAKE_OK;
const PANCAKE_ERR_NULL_POINTER = c.PANCAKE_ERR_NULL_POINTER;
const PANCAKE_ERR_INVALID_ARGUMENT = c.PANCAKE_ERR_INVALID_ARGUMENT;
const PANCAKE_ERR_INTERNAL = c.PANCAKE_ERR_INTERNAL;
const PANCAKE_ERR_CLOSED = c.PANCAKE_ERR_CLOSED;
const PANCAKE_ERR_IO = c.PANCAKE_ERR_IO;
const PANCAKE_ERR_WOULD_BLOCK = c.PANCAKE_ERR_WOULD_BLOCK;

/// The annotated symbol inventory (crossing semantics per export) the binding
/// FFI-table generators reflect from — see `symbols.zig`.
pub const symbols = @import("symbols.zig");

/// How the control endpoint expects to be authenticated. Mirrors
/// `net.onion.control.Auth`, whose declaration carries the reasoning: these are
/// the three forms a real `torrc` produces.
pub const PANCAKE_ONION_AUTH_NONE: u32 = 0;
/// Authenticate with the bytes of the file `CookieAuthFile` names, sent as
/// hexadecimal. The common default on a distribution's Tor package.
pub const PANCAKE_ONION_AUTH_COOKIE: u32 = 1;
/// Authenticate with the cleartext of a `HashedControlPassword` setup.
pub const PANCAKE_ONION_AUTH_PASSWORD: u32 = 2;

/// The longest service id, and the longest private key blob, a caller must be
/// ready to receive. A version 3 service id is always exactly 56 characters; the
/// key bound is Tor's `ED25519-V3:` form with room to spare.
pub const PANCAKE_ONION_SERVICE_ID_LEN: usize = 56;
pub const PANCAKE_ONION_SERVICE_KEY_CAP: usize = 256;

/// Everything the netlayer needs to reach Tor, and what to ask for when hosting.
///
/// The caller zero-initializes the whole struct and fills the fields it sets, so a
/// field added later reads as zero rather than as stack contents. Every pointer is
/// borrowed for the duration of the `pancake_onion_netlayer_new` call and copied
/// into the handle, so the caller may free its own strings afterwards.
///
/// `socks` is required. `control_endpoint` empty means dial-only, and
/// `pancake_onion_listen` then fails rather than pretending to host. `service_key`
/// empty asks Tor for a fresh service; otherwise it must be the exact bytes a
/// previous `pancake_onion_listen` reported, which is what brings the same onion
/// address back. `forward` empty binds a loopback port and reports it to Tor.
pub const PancakeOnionConfig = extern struct {
    socks: ?[*]const u8 = null,
    socks_len: usize = 0,
    control_endpoint: ?[*]const u8 = null,
    control_endpoint_len: usize = 0,
    /// One of the `PANCAKE_ONION_AUTH_*` constants.
    auth_kind: u32 = 0,
    /// The cookie file's bytes or the password's text, per `auth_kind`. Unread
    /// when `auth_kind` is `_NONE`.
    auth_secret: ?[*]const u8 = null,
    auth_secret_len: usize = 0,
    service_key: ?[*]const u8 = null,
    service_key_len: usize = 0,
    forward: ?[*]const u8 = null,
    forward_len: usize = 0,
};

/// The netlayer's own storage. The configuration text is copied in, because a C
/// caller's strings need not outlive the call that passed them, and the resident
/// borrows its endpoints for its whole life.
const OnionNetlayerPayload = struct {
    threaded: std.Io.Threaded,
    resident: net.onion.Resident,
    allocator: std.mem.Allocator,
    /// One block holding every copied string, so the payload frees in one call.
    text: []u8,
    /// Connect and listen are blocking C calls, but their Tor I/O runs as tasks
    /// in this owner group. Sealing and canceling the group is what lets a
    /// binding close the parent while another OS thread is still inside one of
    /// those calls without waiting for a silent daemon forever.
    tasks: net.OperationOwner,
    /// Covers the complete foreign call, including output copying and child
    /// publication after the cancellable Tor task returns.
    calls: c.ForeignCallBarrier = .{},
    failure_mutex: net.sync.SpinLock = .{},
    terminal_failure: ?net.netlayer.ListenerCloseFailure = null,
    /// Construction, each package lease, and each published provider handle own
    /// one reference. The final release joins every operation before freeing the
    /// resident and its copied configuration.
    references: std.atomic.Value(usize),
    provider_profile: ProviderProfile,
    provider_profile_abi: c.PancakeTransportProfile,
    provider_table: c.PancakeStreamTransport,
    provider_entry: c.PancakeTransportProviderEntry,
    provider: c.PancakeTransportProvider,

    fn io(self: *OnionNetlayerPayload) std.Io {
        return self.threaded.io();
    }

    fn noteFailure(self: *OnionNetlayerPayload, later: net.netlayer.ListenerCloseFailure) void {
        self.failure_mutex.lock();
        defer self.failure_mutex.unlock();
        if (self.terminal_failure) |*recorded|
            recorded.noteChain(later)
        else
            self.terminal_failure = later;
    }

    fn recordedFailure(self: *OnionNetlayerPayload) ?net.netlayer.ListenerCloseFailure {
        self.failure_mutex.lock();
        defer self.failure_mutex.unlock();
        return self.terminal_failure;
    }

    fn initProvider(self: *OnionNetlayerPayload) void {
        self.provider_profile = .{ .owner = self };
        self.provider_profile_abi = c.transport_provider.profileFromMetadata(
            model.transport.Known.onion.metadata(),
        );
        self.provider_table = streamTransport(&self.provider_profile);
        self.provider_entry = .{
            .profile = &self.provider_profile_abi,
            .execution_model = c.transport_provider.PANCAKE_TRANSPORT_EXEC_STREAM,
            .implementation = &self.provider_table,
        };
        self.provider = .{
            .abi_version = c.transport_provider.PANCAKE_TRANSPORT_PROVIDER_ABI_VERSION,
            .struct_size = @sizeOf(c.PancakeTransportProvider),
            .entries = @ptrCast(&self.provider_entry),
            .entry_count = 1,
            .lease_ctx = self,
            .same_configuration = providerSameConfiguration,
            .retain = providerRetain,
            .release = providerRelease,
        };
    }

    fn retain(self: *OnionNetlayerPayload) bool {
        var current = self.references.load(.acquire);
        while (current != 0) {
            if (self.references.cmpxchgWeak(current, current + 1, .acq_rel, .acquire)) |observed| {
                current = observed;
            } else return true;
        }
        return false;
    }

    fn release(self: *OnionNetlayerPayload) ?net.netlayer.ListenerCloseFailure {
        if (self.references.fetchSub(1, .acq_rel) != 1) return null;
        _ = self.calls.beginShutdown(self.io());
        self.tasks.shutdown();
        self.tasks.join();
        self.calls.wait(self.io());
        const failure = self.recordedFailure();
        const alloc = self.allocator;
        self.threaded.deinit();
        alloc.free(self.text);
        alloc.destroy(self);
        return failure;
    }

    /// Provider children retire while the installed package still owns its
    /// lease. Keeping this separate from final-capable release makes that
    /// lifetime premise executable instead of silently discarding an outcome.
    fn releaseProviderChild(self: *OnionNetlayerPayload) void {
        const prior = self.references.fetchSub(1, .acq_rel);
        std.debug.assert(prior > 1);
    }
};

const ProviderProfile = struct {
    owner: *OnionNetlayerPayload,
};

const RawConn = struct {
    stream: net.onion.resident.RawStream,
    owner: *OnionNetlayerPayload,
    operations: c.ForeignCallBarrier = .{},
    failure: c.PancakeProviderFailure = std.mem.zeroes(c.PancakeProviderFailure),
};

const RawListener = struct {
    listener: *net.onion.Listener,
    locator: model.PeerLocator,
    owner: *OnionNetlayerPayload,
    operations: c.ForeignCallBarrier = .{},
};

const ProviderDialAttempt = struct {
    owner: *OnionNetlayerPayload,
    designator: []u8,
    completion: net.TransportOperationCompletion,
    operation: net.CancelableOperation = undefined,
    result: Result = .pending,

    const Result = union(enum) {
        pending,
        stream: std.Io.net.Stream,
        failure: net.netlayer.DialError,
    };

    fn run(self: *ProviderDialAttempt) std.Io.Cancelable!void {
        self.result = if (net.onion.resident.dialRawStream(
            self.owner.io(),
            self.owner.resident.config.socks,
            self.designator,
        )) |stream|
            .{ .stream = stream }
        else |err|
            .{ .failure = err };
        _ = self.completion.publish();
    }

    fn retire(raw: *anyopaque) void {
        const self: *ProviderDialAttempt = @ptrCast(@alignCast(raw));
        self.destroy();
    }

    fn destroy(self: *ProviderDialAttempt) void {
        switch (self.result) {
            .stream => |stream| stream.close(self.owner.io()),
            .pending, .failure => {},
        }
        self.completion.deinit();
        const allocator = self.owner.allocator;
        allocator.free(self.designator);
        allocator.destroy(self);
    }
};

const ProviderListenAttempt = struct {
    owner: *OnionNetlayerPayload,
    requested_designator: []u8,
    completion: net.TransportOperationCompletion,
    operation: net.CancelableOperation = undefined,
    result: Result = .pending,

    const Result = union(enum) {
        pending,
        listener: *net.onion.Listener,
        failure: net.netlayer.ListenFailure,
    };

    fn run(self: *ProviderListenAttempt) std.Io.Cancelable!void {
        self.result = switch (net.onion.Listener.create(
            self.owner.allocator,
            self.owner.io(),
            self.owner.resident.config,
        )) {
            .ready => |listener| blk: {
                if (self.requested_designator.len != 0 and
                    !std.mem.eql(u8, self.requested_designator, listener.designator()))
                {
                    var failure = net.netlayer.ListenFailure.init(error.InvalidAddress);
                    if (listener.deinit()) |cleanup| failure.noteChain(cleanup);
                    break :blk .{ .failure = failure };
                }
                break :blk .{ .listener = listener };
            },
            .failed => |failure| .{ .failure = failure },
        };
        _ = self.completion.publish();
    }

    fn retire(raw: *anyopaque) void {
        const self: *ProviderListenAttempt = @ptrCast(@alignCast(raw));
        self.destroy();
    }

    fn destroy(self: *ProviderListenAttempt) void {
        switch (self.result) {
            .listener => |listener| if (listener.deinit()) |failure|
                self.owner.noteFailure(failure),
            .pending, .failure => {},
        }
        self.completion.deinit();
        const allocator = self.owner.allocator;
        allocator.free(self.requested_designator);
        allocator.destroy(self);
    }
};

const OnionConnPayload = struct {
    stream: net.FrameStream,
    operations: c.ForeignCallBarrier,
    directions: c.ConnDirectionGates,
    read_buf: []u8,
    write_buf: []u8,
    allocator: std.mem.Allocator,
};

const OnionListenerPayload = struct {
    listener: *net.onion.Listener,
    operations: c.ForeignCallBarrier,
    io: std.Io,
    allocator: std.mem.Allocator,
};

const conn_lifecycle = c.ConnLifecycle(OnionConnPayload);
const beginConn = conn_lifecycle.begin;
const abortConn = conn_lifecycle.abort;
const destroyConn = conn_lifecycle.destroy;
const conn_frame_ops = c.ConnFrameOps(OnionConnPayload);

fn authEqual(a: net.onion.control.Auth, b: net.onion.control.Auth) bool {
    return switch (a) {
        .none => b == .none,
        .cookie => |left| switch (b) {
            .cookie => |right| std.mem.eql(u8, left, right),
            else => false,
        },
        .password => |left| switch (b) {
            .password => |right| std.mem.eql(u8, left, right),
            else => false,
        },
    };
}

fn providerSameConfiguration(ctx: ?*anyopaque, other_ctx: ?*anyopaque) callconv(.c) u8 {
    const left: *OnionNetlayerPayload = @ptrCast(@alignCast(ctx orelse return 0));
    const right: *OnionNetlayerPayload = @ptrCast(@alignCast(other_ctx orelse return 0));
    const a = left.resident.config;
    const b = right.resident.config;
    return @intFromBool(
        std.mem.eql(u8, a.socks, b.socks) and
            std.mem.eql(u8, a.control_endpoint, b.control_endpoint) and
            authEqual(a.auth, b.auth) and
            std.mem.eql(u8, a.service_key, b.service_key) and
            std.mem.eql(u8, a.forward, b.forward),
    );
}

fn providerRetain(ctx: ?*anyopaque, out_failure: ?*c.PancakeProviderFailure) callconv(.c) i32 {
    const payload: *OnionNetlayerPayload = @ptrCast(@alignCast(ctx orelse {
        c.transport_provider.setProviderFailure(out_failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
        return PANCAKE_ERR_NULL_POINTER;
    }));
    if (payload.retain()) return PANCAKE_OK;
    c.transport_provider.setProviderFailure(out_failure, PANCAKE_ERR_CLOSED, error.Closed);
    return PANCAKE_ERR_CLOSED;
}

fn providerRelease(ctx: ?*anyopaque, out_failure: ?*c.PancakeProviderFailure) callconv(.c) i32 {
    const payload: *OnionNetlayerPayload = @ptrCast(@alignCast(ctx orelse return PANCAKE_OK));
    if (payload.release()) |failure| {
        c.setLastErrorChain("onion provider release", failure);
        const code = providerListenError(failure.cause);
        return c.transport_provider.failProviderChain(out_failure, code, failure, providerListenError);
    }
    return PANCAKE_OK;
}

fn profileFrom(ctx: ?*anyopaque) *ProviderProfile {
    return @ptrCast(@alignCast(ctx.?));
}

fn streamTransport(profile: *ProviderProfile) c.PancakeStreamTransport {
    return .{
        .abi_version = c.transport_provider.PANCAKE_STREAM_TRANSPORT_ABI_VERSION,
        .struct_size = @sizeOf(c.PancakeStreamTransport),
        .ctx = profile,
        .start_connect = providerStartConnect,
        .finish_connect = providerFinishConnect,
        .cancel_connect = providerCancelConnect,
        .listen = providerListen,
        .finish_listen = providerFinishListen,
        .cancel_listen = providerCancelListen,
        .listener_wait_acceptable = providerListenerWaitAcceptable,
        .listener_readiness_fd = providerListenerReadinessFd,
        .listener_locator = providerListenerLocator,
        .listener_advertise = providerListenerAdvertise,
        .listener_restoration_state = providerListenerRestorationState,
        .accept = providerAccept,
        .listener_close = providerListenerClose,
        .read = providerRead,
        .write_all = providerWriteAll,
        .conn_close = providerConnClose,
        .conn_take_failure = providerConnTakeFailure,
    };
}

fn providerListenerRestorationState(
    listener_raw: ?*anyopaque,
    out: ?[*]u8,
    cap: usize,
    out_len: ?*usize,
    out_failure: ?*c.PancakeProviderFailure,
) callconv(.c) i32 {
    const len_slot = out_len orelse
        return c.transport_provider.failProvider(out_failure, c.PANCAKE_ERR_NULL_POINTER, error.NullPointer);
    len_slot.* = 0;
    const listener = rawListener(listener_raw);
    if (!listener.operations.acquire(listener.owner.io()))
        return c.transport_provider.failProvider(out_failure, c.PANCAKE_ERR_CLOSED, error.Closed);
    defer listener.operations.release(listener.owner.io());
    const state = listener.listener.serviceKey();
    len_slot.* = state.len;
    if (cap < state.len) return c.PANCAKE_ERR_BUFFER_TOO_SMALL;
    if (state.len != 0) {
        const dest = out orelse
            return c.transport_provider.failProvider(out_failure, c.PANCAKE_ERR_NULL_POINTER, error.NullPointer);
        @memcpy(dest[0..state.len], state);
    }
    return c.PANCAKE_OK;
}

fn rawListener(raw: ?*anyopaque) *RawListener {
    return @ptrCast(@alignCast(raw.?));
}

fn rawConn(raw: ?*anyopaque) *RawConn {
    return @ptrCast(@alignCast(raw.?));
}

fn onionLocatorFromView(view: *const c.PancakeLocatorView) ?model.PeerLocator {
    if (view.abi_version != c.PANCAKE_LOCATOR_VIEW_ABI_VERSION or
        view.struct_size < @sizeOf(c.PancakeLocatorView) or
        view.hint_count != 0 or
        view.hint_wire_form != c.PANCAKE_HINTS_BOOLEAN_FALSE)
        return null;
    return c.locator_adapter.fromView(view, &.{}) catch null;
}

fn providerStartConnect(
    ctx: ?*anyopaque,
    locator_view: ?*const c.PancakeLocatorView,
    options: ?*const c.PancakeTransportOperationOptions,
    out_attempt: ?*?*anyopaque,
    out_readiness_fd: ?*i32,
    out_failure: ?*c.PancakeProviderFailure,
) callconv(.c) i32 {
    if (!c.transport_provider.operationOptionsAreInherited(options))
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_INVALID_ARGUMENT, error.InvalidOptions);
    const profile = profileFrom(ctx);
    const slot = out_attempt orelse return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
    const fd_slot = out_readiness_fd orelse return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
    const view = locator_view orelse return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
    const locator = onionLocatorFromView(view) orelse
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_INVALID_ARGUMENT, error.InvalidAddress);
    if (!std.mem.eql(u8, locator.transport, model.transport.Known.onion.metadata().symbol))
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_INVALID_ARGUMENT, error.InvalidAddress);
    const attempt = profile.owner.allocator.create(ProviderDialAttempt) catch |err| {
        c.transport_provider.setProviderFailure(out_failure, PANCAKE_ERR_INTERNAL, err);
        return c.failInternal("onion provider connect admission", err);
    };
    const designator = profile.owner.allocator.dupe(u8, locator.designator) catch |err| {
        profile.owner.allocator.destroy(attempt);
        c.transport_provider.setProviderFailure(out_failure, PANCAKE_ERR_INTERNAL, err);
        return c.failInternal("onion provider connect designator", err);
    };
    attempt.* = .{
        .owner = profile.owner,
        .designator = designator,
        .completion = net.TransportOperationCompletion.init() catch |err| {
            profile.owner.allocator.free(designator);
            profile.owner.allocator.destroy(attempt);
            c.transport_provider.setProviderFailure(out_failure, PANCAKE_ERR_INTERNAL, err);
            return c.failInternal("onion provider connect completion", err);
        },
    };
    profile.owner.tasks.startCancelable(
        &attempt.operation,
        ProviderDialAttempt.run,
        .{attempt},
        attempt,
        ProviderDialAttempt.retire,
    ) catch |err| {
        attempt.destroy();
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_IO, err);
    };
    slot.* = attempt;
    fd_slot.* = attempt.completion.readinessFd();
    return PANCAKE_OK;
}

fn providerFinishConnect(
    attempt_raw: ?*anyopaque,
    out_conn: ?*?*anyopaque,
    out_readiness_fd: ?*i32,
    out_failure: ?*c.PancakeProviderFailure,
) callconv(.c) i32 {
    const attempt: *ProviderDialAttempt = @ptrCast(@alignCast(attempt_raw orelse
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer)));
    const slot = out_conn orelse {
        _ = providerCancelConnect(attempt, null);
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
    };
    const fd_slot = out_readiness_fd orelse {
        _ = providerCancelConnect(attempt, null);
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
    };
    const claimed = attempt.completion.claim() catch |err| {
        _ = attempt.owner.tasks.reap(&attempt.operation);
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_IO, err);
    };
    if (!claimed) return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_CLOSED, error.Closed);
    attempt.completion.wake.drain() catch |err| {
        _ = attempt.owner.tasks.reap(&attempt.operation);
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_IO, err);
    };
    const result = attempt.result;
    attempt.result = .pending;
    switch (result) {
        .failure => |err| {
            _ = attempt.owner.tasks.reap(&attempt.operation);
            const code = providerDialError(err);
            return c.transport_provider.failProvider(out_failure, code, err);
        },
        .pending => unreachable,
        .stream => |stream| {
            if (!attempt.owner.retain()) {
                stream.close(attempt.owner.io());
                _ = attempt.owner.tasks.reap(&attempt.operation);
                return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_CLOSED, error.Closed);
            }
            const conn = attempt.owner.allocator.create(RawConn) catch |err| {
                stream.close(attempt.owner.io());
                attempt.owner.releaseProviderChild();
                _ = attempt.owner.tasks.reap(&attempt.operation);
                return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_INTERNAL, err);
            };
            conn.* = .{
                .stream = net.onion.resident.RawStream.init(
                    attempt.owner.io(),
                    stream,
                    &[_]u8{},
                    &[_]u8{},
                ),
                .owner = attempt.owner,
                .operations = .{},
            };
            slot.* = conn;
            fd_slot.* = @intCast(conn.stream.readinessFd());
            _ = attempt.owner.tasks.reap(&attempt.operation);
            return PANCAKE_OK;
        },
    }
}

fn providerCancelConnect(attempt_raw: ?*anyopaque, _: ?*c.PancakeProviderFailure) callconv(.c) i32 {
    const attempt: *ProviderDialAttempt = @ptrCast(@alignCast(attempt_raw orelse return PANCAKE_OK));
    if (attempt.completion.cancel())
        _ = attempt.owner.tasks.reap(&attempt.operation)
    else
        _ = attempt.owner.tasks.cancel(&attempt.operation);
    return PANCAKE_OK;
}

fn providerListen(
    ctx: ?*anyopaque,
    requested_designator: ?[*]const u8,
    requested_designator_len: usize,
    identity_designator: ?[*]const u8,
    identity_designator_len: usize,
    options: ?*const c.PancakeTransportOperationOptions,
    out_result: ?*c.PancakeListenResult,
    out_failure: ?*c.PancakeProviderFailure,
) callconv(.c) i32 {
    if (!c.transport_provider.operationOptionsAreInherited(options))
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_INVALID_ARGUMENT, error.InvalidOptions);
    const profile = profileFrom(ctx);
    const slot = out_result orelse
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
    const requested = c.sliceFromC(requested_designator, requested_designator_len) catch
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
    _ = c.sliceFromC(identity_designator, identity_designator_len) catch
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
    const attempt = profile.owner.allocator.create(ProviderListenAttempt) catch |err| {
        c.transport_provider.setProviderFailure(out_failure, PANCAKE_ERR_INTERNAL, err);
        return c.failInternal("onion provider listen admission", err);
    };
    const requested_copy = profile.owner.allocator.dupe(u8, requested) catch |err| {
        profile.owner.allocator.destroy(attempt);
        c.transport_provider.setProviderFailure(out_failure, PANCAKE_ERR_INTERNAL, err);
        return c.failInternal("onion provider listen designator", err);
    };
    attempt.* = .{
        .owner = profile.owner,
        .requested_designator = requested_copy,
        .completion = net.TransportOperationCompletion.init() catch |err| {
            profile.owner.allocator.free(requested_copy);
            profile.owner.allocator.destroy(attempt);
            c.transport_provider.setProviderFailure(out_failure, PANCAKE_ERR_INTERNAL, err);
            return c.failInternal("onion provider listen completion", err);
        },
    };
    profile.owner.tasks.startCancelable(
        &attempt.operation,
        ProviderListenAttempt.run,
        .{attempt},
        attempt,
        ProviderListenAttempt.retire,
    ) catch |err| {
        attempt.destroy();
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_IO, err);
    };
    slot.* = .{
        .state = c.PANCAKE_LISTEN_PENDING,
        .listener = null,
        .attempt = attempt,
        .readiness_fd = attempt.completion.readinessFd(),
    };
    return PANCAKE_OK;
}

fn providerFinishListen(
    attempt_raw: ?*anyopaque,
    out_listener: ?*?*anyopaque,
    out_failure: ?*c.PancakeProviderFailure,
) callconv(.c) i32 {
    const attempt: *ProviderListenAttempt = @ptrCast(@alignCast(attempt_raw orelse
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer)));
    const slot = out_listener orelse {
        _ = providerCancelListen(attempt, null);
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
    };
    const claimed = attempt.completion.claim() catch |err| {
        _ = attempt.owner.tasks.reap(&attempt.operation);
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_IO, err);
    };
    if (!claimed) return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_CLOSED, error.Closed);
    attempt.completion.wake.drain() catch |err| {
        _ = attempt.owner.tasks.reap(&attempt.operation);
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_IO, err);
    };
    const result = attempt.result;
    attempt.result = .pending;
    defer _ = attempt.owner.tasks.reap(&attempt.operation);
    switch (result) {
        .failure => |failure| {
            c.setLastErrorChain("onion provider listen", failure);
            const code = providerListenError(failure.cause);
            c.transport_provider.setProviderFailureChain(out_failure, code, failure, providerListenError);
            return code;
        },
        .pending => unreachable,
        .listener => |listener| {
            if (!attempt.owner.retain()) {
                var failure = net.netlayer.ListenFailure.init(error.Closed);
                if (listener.deinit()) |cleanup| failure.noteChain(cleanup);
                c.setLastErrorChain("onion provider listen", failure);
                c.transport_provider.setProviderFailureChain(out_failure, PANCAKE_ERR_CLOSED, failure, providerListenError);
                return PANCAKE_ERR_CLOSED;
            }
            var owns_owner_ref = true;
            defer if (owns_owner_ref) attempt.owner.releaseProviderChild();
            const locator = model.clonePeerLocator(attempt.owner.allocator, .{
                .transport = model.transport.Known.onion.metadata().symbol,
                .designator = listener.designator(),
                .hints = .emptyFalse(),
            }) catch |err| {
                var failure = net.netlayer.ListenFailure.init(err);
                if (listener.deinit()) |cleanup| failure.noteChain(cleanup);
                c.setLastErrorChain("onion provider listener locator", failure);
                c.transport_provider.setProviderFailureChain(out_failure, PANCAKE_ERR_INTERNAL, failure, providerListenError);
                return PANCAKE_ERR_INTERNAL;
            };
            const raw = attempt.owner.allocator.create(RawListener) catch |err| {
                model.freePeerLocator(attempt.owner.allocator, locator);
                var failure = net.netlayer.ListenFailure.init(err);
                if (listener.deinit()) |cleanup| failure.noteChain(cleanup);
                c.setLastErrorChain("onion provider listener", failure);
                c.transport_provider.setProviderFailureChain(out_failure, PANCAKE_ERR_INTERNAL, failure, providerListenError);
                return PANCAKE_ERR_INTERNAL;
            };
            raw.* = .{ .listener = listener, .locator = locator, .owner = attempt.owner, .operations = .{} };
            slot.* = raw;
            owns_owner_ref = false;
            return PANCAKE_OK;
        },
    }
}

fn providerCancelListen(attempt_raw: ?*anyopaque, _: ?*c.PancakeProviderFailure) callconv(.c) i32 {
    const attempt: *ProviderListenAttempt = @ptrCast(@alignCast(attempt_raw orelse return PANCAKE_OK));
    if (attempt.completion.cancel())
        _ = attempt.owner.tasks.reap(&attempt.operation)
    else
        _ = attempt.owner.tasks.cancel(&attempt.operation);
    return PANCAKE_OK;
}

fn providerListenerWaitAcceptable(_: ?*anyopaque, listener: ?*anyopaque, timeout_ms: i32, out_failure: ?*c.PancakeProviderFailure) callconv(.c) i32 {
    const raw = rawListener(listener);
    if (!raw.operations.acquire(raw.owner.io())) return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_CLOSED, error.Closed);
    defer raw.operations.release(raw.owner.io());
    return if (raw.listener.waitAcceptable(timeout_ms) catch |err| return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_IO, err))
        PANCAKE_OK
    else
        PANCAKE_ERR_WOULD_BLOCK;
}

fn providerListenerReadinessFd(_: ?*anyopaque, listener: ?*anyopaque) callconv(.c) i32 {
    const raw = rawListener(listener);
    if (!raw.operations.acquire(raw.owner.io())) return -1;
    defer raw.operations.release(raw.owner.io());
    return @intCast(raw.listener.readinessFd());
}

fn providerListenerLocator(
    listener_raw: ?*anyopaque,
    sink_ctx: ?*anyopaque,
    sink: c.PancakeLocatorSinkFn,
    out_failure: ?*c.PancakeProviderFailure,
) callconv(.c) i32 {
    const listener = rawListener(listener_raw);
    if (!listener.operations.acquire(listener.owner.io()))
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_CLOSED, error.Closed);
    defer listener.operations.release(listener.owner.io());
    var hint_stack: [c.locator_adapter.inline_hint_capacity]c.PancakeLocatorHintView = undefined;
    const view = c.locator_adapter.project(
        listener.locator,
        hint_stack[0..listener.locator.hints.entries.len],
    ) catch |err| {
        setLastError("onion listener locator projection: {s}", .{@errorName(err)});
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_INVALID_ARGUMENT, err);
    };
    return sink(sink_ctx, &view);
}

fn providerListenerAdvertise(
    listener_raw: ?*anyopaque,
    locator_view: ?*const c.PancakeLocatorView,
    sink_ctx: ?*anyopaque,
    sink: c.PancakeLocatorSinkFn,
    out_failure: ?*c.PancakeProviderFailure,
) callconv(.c) i32 {
    const listener = rawListener(listener_raw);
    if (!listener.operations.acquire(listener.owner.io()))
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_CLOSED, error.Closed);
    defer listener.operations.release(listener.owner.io());
    const view = locator_view orelse
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
    const locator = onionLocatorFromView(view) orelse
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_INVALID_ARGUMENT, error.InvalidAddress);
    const canonical = net.netlayer.canonicalizeFixedLocator(
        listener.owner.allocator,
        locator,
        listener.locator.transport,
        listener.locator.designator,
    ) catch |err| return c.transport_provider.failProvider(
        out_failure,
        if (err == error.OutOfMemory) PANCAKE_ERR_INTERNAL else PANCAKE_ERR_INVALID_ARGUMENT,
        err,
    );
    defer model.freePeerLocator(listener.owner.allocator, canonical);
    var c_hint_stack: [c.locator_adapter.inline_hint_capacity]c.PancakeLocatorHintView = undefined;
    const canonical_view = c.locator_adapter.project(
        canonical,
        c_hint_stack[0..canonical.hints.entries.len],
    ) catch |err|
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_INVALID_ARGUMENT, err);
    return sink(sink_ctx, &canonical_view);
}

fn providerAccept(_: ?*anyopaque, listener_raw: ?*anyopaque, out_conn: ?*?*anyopaque, out_readiness_fd: ?*i32, out_failure: ?*c.PancakeProviderFailure) callconv(.c) i32 {
    const listener = rawListener(listener_raw);
    if (!listener.operations.acquire(listener.owner.io())) return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_CLOSED, error.Closed);
    defer listener.operations.release(listener.owner.io());
    const slot = out_conn orelse return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
    const fd_slot = out_readiness_fd orelse return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
    const stream = listener.listener.acceptRawStream() catch |err| return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_IO, err);
    if (!listener.owner.retain()) {
        stream.close(listener.owner.io());
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_CLOSED, error.Closed);
    }
    const conn = listener.owner.allocator.create(RawConn) catch |err| {
        stream.close(listener.owner.io());
        listener.owner.releaseProviderChild();
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_INTERNAL, err);
    };
    conn.* = .{
        .stream = net.onion.resident.RawStream.init(
            listener.owner.io(),
            stream,
            &[_]u8{},
            &[_]u8{},
        ),
        .owner = listener.owner,
        .operations = .{},
    };
    slot.* = conn;
    fd_slot.* = @intCast(conn.stream.readinessFd());
    return PANCAKE_OK;
}

fn providerListenerClose(
    _: ?*anyopaque,
    listener_raw: ?*anyopaque,
    out_failure: ?*c.PancakeProviderFailure,
) callconv(.c) i32 {
    const listener = rawListener(listener_raw);
    const owner = listener.owner;
    if (listener.operations.beginShutdown(owner.io())) listener.listener.shutdown();
    listener.operations.wait(owner.io());
    var failure = listener.listener.deinit();
    model.freePeerLocator(owner.allocator, listener.locator);
    owner.allocator.destroy(listener);
    if (owner.release()) |runtime_failure| {
        if (failure) |*primary|
            primary.noteChain(runtime_failure)
        else
            failure = runtime_failure;
    }
    if (failure) |chain| {
        c.setLastErrorChain("onion provider listener close", chain);
        const code = providerListenError(chain.cause);
        return c.transport_provider.failProviderChain(out_failure, code, chain, providerListenError);
    }
    return PANCAKE_OK;
}

fn providerRead(_: ?*anyopaque, conn_raw: ?*anyopaque, out: ?[*]u8, cap: usize) callconv(.c) isize {
    const conn = rawConn(conn_raw);
    if (!conn.operations.acquire(conn.owner.io())) {
        if (c.transport_provider.providerFailureEmpty(conn.failure)) c.transport_provider.setProviderFailure(&conn.failure, PANCAKE_ERR_CLOSED, error.Closed);
        return -1;
    }
    defer conn.operations.release(conn.owner.io());
    const dest = (out orelse {
        c.transport_provider.setProviderFailure(&conn.failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
        return -1;
    })[0..cap];
    const got = conn.stream.read(dest) catch |err| {
        if (err == error.EndOfStream) return 0;
        if (c.transport_provider.providerFailureEmpty(conn.failure)) c.transport_provider.setProviderFailure(&conn.failure, PANCAKE_ERR_IO, err);
        return -1;
    };
    return @intCast(got);
}

fn providerWriteAll(_: ?*anyopaque, conn_raw: ?*anyopaque, bytes: ?[*]const u8, len: usize) callconv(.c) i32 {
    const conn = rawConn(conn_raw);
    if (!conn.operations.acquire(conn.owner.io())) {
        if (c.transport_provider.providerFailureEmpty(conn.failure)) c.transport_provider.setProviderFailure(&conn.failure, PANCAKE_ERR_CLOSED, error.Closed);
        return PANCAKE_ERR_CLOSED;
    }
    defer conn.operations.release(conn.owner.io());
    const source = bytes orelse {
        c.transport_provider.setProviderFailure(&conn.failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
        return PANCAKE_ERR_NULL_POINTER;
    };
    conn.stream.writeAll(source[0..len]) catch |err| {
        if (c.transport_provider.providerFailureEmpty(conn.failure)) c.transport_provider.setProviderFailure(&conn.failure, PANCAKE_ERR_IO, err);
        return PANCAKE_ERR_IO;
    };
    return PANCAKE_OK;
}

fn providerConnTakeFailure(_: ?*anyopaque, conn_raw: ?*anyopaque, out_failure: ?*c.PancakeProviderFailure) callconv(.c) void {
    const slot = out_failure orelse return;
    const conn = rawConn(conn_raw);
    slot.* = conn.failure;
    conn.failure = std.mem.zeroes(c.PancakeProviderFailure);
}

fn providerConnClose(
    _: ?*anyopaque,
    conn_raw: ?*anyopaque,
    out_failure: ?*c.PancakeProviderFailure,
) callconv(.c) i32 {
    const conn = rawConn(conn_raw);
    const owner = conn.owner;
    var failure: ?net.netlayer.ListenerCloseFailure = null;
    if (conn.operations.beginShutdown(owner.io())) conn.stream.shutdown() catch |err| {
        failure = net.netlayer.ListenerCloseFailure.init(err);
    };
    conn.operations.wait(owner.io());
    conn.stream.close();
    owner.allocator.destroy(conn);
    if (owner.release()) |runtime_failure| {
        if (failure) |*primary|
            primary.noteChain(runtime_failure)
        else
            failure = runtime_failure;
    }
    if (failure) |chain| {
        c.setLastErrorChain("onion provider connection close", chain);
        const code = providerListenError(chain.cause);
        return c.transport_provider.failProviderChain(out_failure, code, chain, providerListenError);
    }
    return PANCAKE_OK;
}

fn providerDialError(err: net.netlayer.DialError) i32 {
    return switch (err) {
        error.InvalidAddress => PANCAKE_ERR_INVALID_ARGUMENT,
        else => PANCAKE_ERR_IO,
    };
}

fn providerListenError(err: anyerror) i32 {
    return switch (err) {
        error.InvalidAddress => PANCAKE_ERR_INVALID_ARGUMENT,
        error.OutOfMemory => PANCAKE_ERR_INTERNAL,
        else => PANCAKE_ERR_IO,
    };
}

/// Copy the calling thread's last onion-transport error message into `out_buf`,
/// the onion sibling of `pancake_last_error`. Copies at most `cap - 1` bytes and
/// always NUL-terminates when `cap > 0`; `out_buf == NULL` or `cap == 0` queries
/// the length. Returns the full message length, or 0 when none is set.
pub export fn pancake_onion_last_error(out_buf: ?[*]u8, cap: usize) usize {
    return c.lastErrorRead(out_buf, cap);
}

/// Clear the calling thread's onion-transport last error slot.
pub export fn pancake_onion_clear_last_error() void {
    c.lastErrorClear();
}

/// Create a netlayer handle from `config`, allocating through the library-owned
/// allocator. Release it with `pancake_onion_netlayer_release` after closing every
/// endpoint made from it.
pub export fn pancake_onion_netlayer_new(
    config: ?*const PancakeOnionConfig,
    out_netlayer: ?*?*PancakeOnionNetlayer,
) i32 {
    c.lastErrorClear();
    const slot = out_netlayer orelse return PANCAKE_ERR_NULL_POINTER;
    const cfg = config orelse return PANCAKE_ERR_NULL_POINTER;
    return netlayerNewIn(c.library_allocator, cfg, slot);
}

/// As `pancake_onion_netlayer_new`, allocating through `context` instead.
pub export fn pancake_onion_netlayer_new_in(
    context: ?*PancakeContext,
    config: ?*const PancakeOnionConfig,
    out_netlayer: ?*?*PancakeOnionNetlayer,
) i32 {
    c.lastErrorClear();
    const c_ctx = c.ctxFromOpaque(context) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_netlayer orelse return PANCAKE_ERR_NULL_POINTER;
    const cfg = config orelse return PANCAKE_ERR_NULL_POINTER;
    return netlayerNewIn(c_ctx.allocator(), cfg, slot);
}

fn netlayerNewIn(
    alloc: std.mem.Allocator,
    cfg: *const PancakeOnionConfig,
    slot: *?*PancakeOnionNetlayer,
) i32 {
    const total = sumLengths(&.{
        cfg.socks_len,
        cfg.control_endpoint_len,
        cfg.auth_secret_len,
        cfg.service_key_len,
        cfg.forward_len,
    }) orelse {
        setLastError("netlayer_new: copied configuration is too large", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };
    const socks = viewOf(cfg.socks, cfg.socks_len) catch {
        setLastError("netlayer_new: socks is null with a nonzero length", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };
    if (socks.len == 0) {
        setLastError("netlayer_new: socks endpoint is required", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    }
    const control_ep = viewOf(cfg.control_endpoint, cfg.control_endpoint_len) catch {
        setLastError("netlayer_new: control_endpoint is null with a nonzero length", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };
    const secret = viewOf(cfg.auth_secret, cfg.auth_secret_len) catch {
        setLastError("netlayer_new: auth_secret is null with a nonzero length", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };
    const key = viewOf(cfg.service_key, cfg.service_key_len) catch {
        setLastError("netlayer_new: service_key is null with a nonzero length", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };
    const forward = viewOf(cfg.forward, cfg.forward_len) catch {
        setLastError("netlayer_new: forward is null with a nonzero length", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };

    if (cfg.auth_kind > PANCAKE_ONION_AUTH_PASSWORD) {
        setLastError("netlayer_new: unknown auth_kind {d}", .{cfg.auth_kind});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    }

    const payload = alloc.create(OnionNetlayerPayload) catch |err|
        return c.failInternal("onion netlayer_new", err);
    // One block for every copied string. The resident borrows these for its whole
    // life, and a C caller's own buffers need not live that long.
    const text = alloc.alloc(u8, total) catch |err| {
        alloc.destroy(payload);
        return c.failInternal("onion netlayer_new configuration copy", err);
    };
    var cursor: usize = 0;
    const socks_copy = take(text, &cursor, socks);
    const control_copy = take(text, &cursor, control_ep);
    const secret_copy = take(text, &cursor, secret);
    const key_copy = take(text, &cursor, key);
    const forward_copy = take(text, &cursor, forward);

    payload.allocator = alloc;
    payload.text = text;
    payload.references = .init(1);
    payload.calls = .{};
    payload.failure_mutex = .{};
    payload.terminal_failure = null;
    payload.threaded = std.Io.Threaded.init(alloc, .{});
    payload.resident = .{
        // `Resident` captures this `std.Io`, which borrows `&payload.threaded`;
        // valid because the payload already has its stable address.
        .io = payload.threaded.io(),
        .config = .{
            .socks = socks_copy,
            .control_endpoint = control_copy,
            .auth = switch (cfg.auth_kind) {
                PANCAKE_ONION_AUTH_COOKIE => .{ .cookie = secret_copy },
                PANCAKE_ONION_AUTH_PASSWORD => .{ .password = secret_copy },
                else => .none,
            },
            .service_key = key_copy,
            .forward = forward_copy,
        },
    };
    payload.tasks.init(payload.resident.io) catch |err| {
        payload.threaded.deinit();
        alloc.free(text);
        alloc.destroy(payload);
        return c.failInternal("onion netlayer_new scheduler", err);
    };
    payload.initProvider();
    slot.* = @ptrCast(payload);
    return PANCAKE_OK;
}

fn viewOf(ptr: ?[*]const u8, len: usize) error{NullPointer}![]const u8 {
    const p = ptr orelse {
        if (len != 0) return error.NullPointer;
        return &.{};
    };
    return p[0..len];
}

fn sumLengths(parts: []const usize) ?usize {
    var total: usize = 0;
    for (parts) |part| total = std.math.add(usize, total, part) catch return null;
    return total;
}

fn take(block: []u8, cursor: *usize, bytes: []const u8) []const u8 {
    const start = cursor.*;
    @memcpy(block[start..][0..bytes.len], bytes);
    cursor.* = start + bytes.len;
    return block[start..][0..bytes.len];
}

fn onionNetlayerRelease(netlayer: ?*PancakeOnionNetlayer) i32 {
    const payload = netlayerFromOpaque(netlayer) orelse return PANCAKE_OK;
    if (payload.release()) |failure| {
        c.setLastErrorChain("onion netlayer release", failure);
        return providerListenError(failure.cause);
    }
    return PANCAKE_OK;
}

pub export fn pancake_onion_netlayer_release(
    netlayer: ?*PancakeOnionNetlayer,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    c.lastErrorClear();
    if (!c.optionalCallErrorOutputIsValid(out_error, error_cap, out_error_len)) {
        return PANCAKE_ERR_NULL_POINTER;
    }
    return c.captureCallError(
        onionNetlayerRelease(netlayer),
        out_error,
        error_cap,
        out_error_len,
    );
}

/// Borrow this onion runtime's one stream provider package. The returned table
/// is copied; its callback contexts borrow `netlayer`, and a driver registration
/// retains that runtime until every listener and connection has retired.
pub export fn pancake_onion_transport_provider(
    netlayer: ?*PancakeOnionNetlayer,
    out_provider: ?*c.PancakeTransportProvider,
) i32 {
    c.lastErrorClear();
    const payload = netlayerFromOpaque(netlayer) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_provider orelse return PANCAKE_ERR_NULL_POINTER;
    slot.* = payload.provider;
    return PANCAKE_OK;
}

/// Seal connect/listen admission and request cancellation of every call already
/// reaching Tor. Returns after the reserved cancellation task has been woken; the
/// operation callers observe their ordinary I/O failure and return. Release
/// joins that worker before freeing the netlayer.
///
/// Idempotent. Bindings call this before waiting for their parent-operation
/// leases, which is what turns a stalled daemon into bounded teardown rather
/// than a process-wide hang.
pub export fn pancake_onion_netlayer_shutdown(netlayer: ?*PancakeOnionNetlayer) void {
    const payload = netlayerFromOpaque(netlayer) orelse return;
    _ = payload.calls.beginShutdown(payload.resident.io);
    payload.tasks.shutdown();
}

const ConnectJob = struct {
    netlayer: *OnionNetlayerPayload,
    payload: *OnionConnPayload,
    service_id: []const u8,
    codec: u32,
    max_frame_bytes: usize,
    err: ?net.netlayer.DialError = null,
    done: net.OperationLatch = .{},

    fn run(job: *ConnectJob) std.Io.Cancelable!void {
        defer job.done.signal(job.netlayer.resident.io);
        job.payload.stream = net.onion.resident.dialFrameStream(
            job.netlayer.resident.io,
            job.netlayer.allocator,
            job.netlayer.resident.config.socks,
            job.service_id,
            codecFromC(job.codec).?,
            job.max_frame_bytes,
            job.payload.read_buf,
            job.payload.write_buf,
        ) catch |err| {
            job.err = err;
            return;
        };
    }
};

const ListenJob = struct {
    netlayer: *OnionNetlayerPayload,
    payload: *OnionListenerPayload,
    failure: ?net.netlayer.ListenFailure = null,
    done: net.OperationLatch = .{},

    fn run(job: *ListenJob) std.Io.Cancelable!void {
        defer job.done.signal(job.netlayer.resident.io);
        switch (net.onion.Listener.create(
            job.netlayer.allocator,
            job.netlayer.resident.io,
            job.netlayer.resident.config,
        )) {
            .ready => |listener| job.payload.listener = listener,
            .failed => |failure| job.failure = failure,
        }
    }
};

/// Dial the onion service `service_id` through the configured Tor and return an
/// owned connection handle framing on `codec`.
///
/// `service_id` is the bare version 3 designator, 56 base32 characters with no
/// `.onion` suffix. A designator that is not a well-formed v3 address is refused
/// before any socket opens. Blocking: a Tor circuit takes seconds.
fn onionConnect(
    netlayer: ?*PancakeOnionNetlayer,
    service_id: ?[*]const u8,
    service_id_len: usize,
    codec: u32,
    max_frame_bytes: usize,
    out_conn: ?*?*PancakeOnionConn,
) i32 {
    const nl = netlayerFromOpaque(netlayer) orelse return PANCAKE_ERR_NULL_POINTER;
    if (!nl.calls.acquire(nl.resident.io)) return PANCAKE_ERR_CLOSED;
    defer nl.calls.release(nl.resident.io);
    const slot = out_conn orelse return PANCAKE_ERR_NULL_POINTER;
    const id_ptr = service_id orelse return PANCAKE_ERR_NULL_POINTER;
    _ = c.framingOptionsFromC(codec, max_frame_bytes, "onion connect") catch
        return PANCAKE_ERR_INVALID_ARGUMENT;

    const payload = beginConn(nl.allocator, max_frame_bytes) orelse
        return c.failInternal("onion connect", error.OutOfMemory);
    var job: ConnectJob = .{
        .netlayer = nl,
        .payload = payload,
        .service_id = id_ptr[0..service_id_len],
        .codec = codec,
        .max_frame_bytes = max_frame_bytes,
    };
    nl.tasks.start(ConnectJob.run, .{&job}) catch {
        abortConn(payload);
        setLastError("connect: onion netlayer is closing or cannot schedule Tor I/O", .{});
        return PANCAKE_ERR_IO;
    };
    job.done.wait(nl.resident.io);
    if (job.err) |err| {
        abortConn(payload);
        return dialErrorToCode(err);
    }
    slot.* = @ptrCast(payload);
    return PANCAKE_OK;
}

pub export fn pancake_onion_connect(
    netlayer: ?*PancakeOnionNetlayer,
    service_id: ?[*]const u8,
    service_id_len: usize,
    codec: u32,
    max_frame_bytes: usize,
    out_conn: ?*?*PancakeOnionConn,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    c.lastErrorClear();
    if (!c.optionalCallErrorOutputIsValid(out_error, error_cap, out_error_len)) {
        return PANCAKE_ERR_NULL_POINTER;
    }
    return c.captureCallError(
        onionConnect(netlayer, service_id, service_id_len, codec, max_frame_bytes, out_conn),
        out_error,
        error_cap,
        out_error_len,
    );
}

/// Ask Tor for an onion service and bind its local end.
///
/// On success `out_service_id` receives the 56-character designator (no NUL) and
/// `out_service_id_len` its length, which is always
/// `PANCAKE_ONION_SERVICE_ID_LEN`. `out_service_key` receives the key that
/// restores this exact service, or nothing when the service was restored rather
/// than minted; a caller that wants a durable onion address stores those bytes and
/// passes them back as `PancakeOnionConfig.service_key`.
///
/// Every out-parameter is optional. Requires a configured control endpoint.
/// Blocking: the control conversation is several round trips to the daemon.
fn onionListen(
    netlayer: ?*PancakeOnionNetlayer,
    out_service_id: ?[*]u8,
    out_service_id_cap: usize,
    out_service_id_len: ?*usize,
    out_service_key: ?[*]u8,
    out_service_key_cap: usize,
    out_service_key_len: ?*usize,
    out_listener: ?*?*PancakeOnionListener,
) i32 {
    const nl = netlayerFromOpaque(netlayer) orelse return PANCAKE_ERR_NULL_POINTER;
    if (!nl.calls.acquire(nl.resident.io)) return PANCAKE_ERR_CLOSED;
    defer nl.calls.release(nl.resident.io);
    const slot = out_listener orelse return PANCAKE_ERR_NULL_POINTER;

    const payload = nl.allocator.create(OnionListenerPayload) catch |err|
        return c.failInternal("onion listen", err);
    payload.allocator = nl.allocator;
    payload.operations = .{};
    payload.io = nl.resident.io;
    var job: ListenJob = .{
        .netlayer = nl,
        .payload = payload,
    };
    nl.tasks.start(ListenJob.run, .{&job}) catch {
        nl.allocator.destroy(payload);
        setLastError("listen: onion netlayer is closing or cannot schedule Tor I/O", .{});
        return PANCAKE_ERR_IO;
    };
    job.done.wait(nl.resident.io);
    if (job.failure) |failure| {
        nl.allocator.destroy(payload);
        c.setLastErrorChain("onion listen", failure);
        return listenErrorToCode(failure.cause);
    }

    const id = payload.listener.designator();
    if (!copyOut(id, out_service_id, out_service_id_cap, out_service_id_len)) {
        const cleanup = payload.listener.deinit();
        nl.allocator.destroy(payload);
        if (cleanup) |failure| {
            setLastError("listen: service id buffer needs {d} bytes; cleanup: {s} ({d} secondary failures)", .{
                id.len,
                @errorName(failure.cause),
                @as(u32, failure.secondary_count) + 1,
            });
        } else setLastError("listen: service id buffer needs {d} bytes", .{id.len});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    }
    const key = payload.listener.serviceKey();
    if (!copyOut(key, out_service_key, out_service_key_cap, out_service_key_len)) {
        const cleanup = payload.listener.deinit();
        nl.allocator.destroy(payload);
        if (cleanup) |failure| {
            setLastError("listen: service key buffer needs {d} bytes; cleanup: {s} ({d} secondary failures)", .{
                key.len,
                @errorName(failure.cause),
                @as(u32, failure.secondary_count) + 1,
            });
        } else setLastError("listen: service key buffer needs {d} bytes", .{key.len});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    }

    slot.* = @ptrCast(payload);
    return PANCAKE_OK;
}

pub export fn pancake_onion_listen(
    netlayer: ?*PancakeOnionNetlayer,
    out_service_id: ?[*]u8,
    service_id_cap: usize,
    out_service_id_len: ?*usize,
    out_service_key: ?[*]u8,
    service_key_cap: usize,
    out_service_key_len: ?*usize,
    out_listener: ?*?*PancakeOnionListener,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    c.lastErrorClear();
    if (!c.optionalCallErrorOutputIsValid(out_error, error_cap, out_error_len)) {
        return PANCAKE_ERR_NULL_POINTER;
    }
    return c.captureCallError(
        onionListen(
            netlayer,
            out_service_id,
            service_id_cap,
            out_service_id_len,
            out_service_key,
            service_key_cap,
            out_service_key_len,
            out_listener,
        ),
        out_error,
        error_cap,
        out_error_len,
    );
}

/// Write `bytes` into an optional out-parameter pair. False when the buffer was
/// supplied but is too small, which is a caller error rather than a fault.
fn copyOut(bytes: []const u8, out: ?[*]u8, cap: usize, out_len: ?*usize) bool {
    if (out) |dest| {
        if (cap < bytes.len) return false;
        @memcpy(dest[0..bytes.len], bytes);
    }
    if (out_len) |slot| slot.* = bytes.len;
    return true;
}

/// Block until Tor forwards a circuit to this service, returning an owned
/// connection handle framing on `codec`.
///
/// The partner's claimed location is unverified on this side: Tor tells a hidden
/// service nothing about who dialed it. ADR-0108 records that, and the pinned
/// Goblins has the identical gap.
fn onionAccept(
    listener: ?*PancakeOnionListener,
    codec: u32,
    max_frame_bytes: usize,
    out_conn: ?*?*PancakeOnionConn,
) i32 {
    const lpayload = listenerFromOpaque(listener) orelse return PANCAKE_ERR_NULL_POINTER;
    if (!lpayload.operations.acquire(lpayload.io)) return PANCAKE_ERR_CLOSED;
    defer lpayload.operations.release(lpayload.io);
    const slot = out_conn orelse return PANCAKE_ERR_NULL_POINTER;
    const codec_id = c.framingOptionsFromC(codec, max_frame_bytes, "onion accept") catch
        return PANCAKE_ERR_INVALID_ARGUMENT;

    const payload = beginConn(lpayload.allocator, max_frame_bytes) orelse
        return c.failInternal("onion accept", error.OutOfMemory);
    payload.stream = lpayload.listener.acceptFrameStream(
        lpayload.allocator,
        codec_id,
        max_frame_bytes,
        payload.read_buf,
        payload.write_buf,
    ) catch |err| {
        abortConn(payload);
        return acceptErrorToCode(err);
    };
    slot.* = @ptrCast(payload);
    return PANCAKE_OK;
}

pub export fn pancake_onion_accept(
    listener: ?*PancakeOnionListener,
    codec: u32,
    max_frame_bytes: usize,
    out_conn: ?*?*PancakeOnionConn,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    c.lastErrorClear();
    if (!c.optionalCallErrorOutputIsValid(out_error, error_cap, out_error_len)) {
        return PANCAKE_ERR_NULL_POINTER;
    }
    return c.captureCallError(
        onionAccept(listener, codec, max_frame_bytes, out_conn),
        out_error,
        error_cap,
        out_error_len,
    );
}

/// Wait until `pancake_onion_accept` would make progress, up to `timeout_ms`.
/// Writes 1 into `out_ready` when the next accept should proceed and 0 on
/// timeout. The one poll guard that lets a blocking host exit its accept loop
/// without closing the listener from another thread.
///
/// The flag is a `u32` rather than a C `bool` because every other integer in this
/// family is fixed-width, and `_Bool` is the one type whose width a caller has to
/// look up.
fn onionListenerWait(
    listener: ?*PancakeOnionListener,
    timeout_ms: i32,
    out_ready: ?*u32,
) i32 {
    const lpayload = listenerFromOpaque(listener) orelse return PANCAKE_ERR_NULL_POINTER;
    if (!lpayload.operations.acquire(lpayload.io)) return PANCAKE_ERR_CLOSED;
    defer lpayload.operations.release(lpayload.io);
    const slot = out_ready orelse return PANCAKE_ERR_NULL_POINTER;
    const ready = lpayload.listener.waitAcceptable(timeout_ms) catch |err| {
        setLastError("listener_wait: {s}", .{@errorName(err)});
        return PANCAKE_ERR_IO;
    };
    slot.* = @intFromBool(ready);
    return PANCAKE_OK;
}

pub export fn pancake_onion_listener_wait(
    listener: ?*PancakeOnionListener,
    timeout_ms: i32,
    out_ready: ?*u32,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    c.lastErrorClear();
    if (!c.optionalCallErrorOutputIsValid(out_error, error_cap, out_error_len)) {
        return PANCAKE_ERR_NULL_POINTER;
    }
    return c.captureCallError(
        onionListenerWait(listener, timeout_ms, out_ready),
        out_error,
        error_cap,
        out_error_len,
    );
}

/// Hand back the descriptor this listener's circuits arrive on, so an embedder can
/// poll instead of blocking.
///
/// This is the readiness half of the surface, the same posture the iroh and WebRTC
/// archives take. Park on this descriptor with whatever your loop uses and call
/// `pancake_onion_accept` once it is readable. Readiness means an accept can make
/// progress; it is not a nonblocking guarantee, because another accept consumer or
/// a close can consume that state first. Serialize accept consumers when a loop
/// must not park. An onion service's forward target is an ordinary local socket,
/// which is why this can be a real descriptor rather than a synthesized readiness
/// fd.
///
/// The descriptor is owned by the listener. Do not close it, and do not use it
/// after `pancake_onion_listener_release`.
pub export fn pancake_onion_listener_readiness_fd(
    listener: ?*PancakeOnionListener,
    out_fd: ?*i32,
) i32 {
    c.lastErrorClear();
    const lpayload = listenerFromOpaque(listener) orelse return PANCAKE_ERR_NULL_POINTER;
    if (!lpayload.operations.acquire(lpayload.io)) return PANCAKE_ERR_CLOSED;
    defer lpayload.operations.release(lpayload.io);
    const slot = out_fd orelse return PANCAKE_ERR_NULL_POINTER;
    slot.* = @intCast(lpayload.listener.readinessFd());
    return PANCAKE_OK;
}

/// Hand back the descriptor this connection's bytes flow over, so an embedder can
/// poll instead of blocking.
///
/// Same contract as `pancake_onion_listener_readiness_fd`: poll it, and call
/// `pancake_onion_conn_read_frame` only when it is readable. A whole frame may
/// still need more than one readable turn, in which case the read parks for the
/// remainder — the descriptor makes the common case free, not every case.
///
/// The descriptor is owned by the connection. Do not close it, and do not use it
/// after `pancake_onion_conn_release`.
pub export fn pancake_onion_conn_readiness_fd(conn: ?*PancakeOnionConn, out_fd: ?*i32) i32 {
    c.lastErrorClear();
    const payload = connFromOpaque(conn) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_fd orelse return PANCAKE_ERR_NULL_POINTER;
    if (!payload.operations.acquire(payload.stream.io)) return PANCAKE_ERR_CLOSED;
    defer payload.operations.release(payload.stream.io);
    slot.* = @intCast(payload.stream.reader.stream.socket.handle);
    return PANCAKE_OK;
}

/// Block until one whole frame arrives, writing it as an *owned* managed frame
/// into `out_frame`. `_CLOSED` on graceful EOF, `_MALFORMED` / `_FRAME_TOO_LARGE`
/// for a bad frame.
///
/// Prefer polling `pancake_onion_conn_readiness_fd` first; this blocks when nothing
/// has arrived.
fn onionConnReadFrame(conn: ?*PancakeOnionConn, out_frame: ?*PancakeManagedFrame) i32 {
    const payload = connFromOpaque(conn) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_frame orelse return PANCAKE_ERR_NULL_POINTER;
    return conn_frame_ops.readFrame(payload, slot, onReadConnectionLost);
}

pub export fn pancake_onion_conn_read_frame(
    conn: ?*PancakeOnionConn,
    out_frame: ?*PancakeManagedFrame,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    c.lastErrorClear();
    if (!c.optionalCallErrorOutputIsValid(out_error, error_cap, out_error_len)) {
        return PANCAKE_ERR_NULL_POINTER;
    }
    return c.captureCallError(
        onionConnReadFrame(conn, out_frame),
        out_error,
        error_cap,
        out_error_len,
    );
}

/// Write one frame's *borrowed* bytes to the partner.
fn onionConnWriteFrame(conn: ?*PancakeOnionConn, frame_in: ?*const PancakeFrame) i32 {
    const payload = connFromOpaque(conn) orelse return PANCAKE_ERR_NULL_POINTER;
    const borrowed = frame_in orelse return PANCAKE_ERR_NULL_POINTER;
    return conn_frame_ops.writeFrame(payload, borrowed, onWriteErr);
}

pub export fn pancake_onion_conn_write_frame(
    conn: ?*PancakeOnionConn,
    frame_in: ?*const PancakeFrame,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    c.lastErrorClear();
    if (!c.optionalCallErrorOutputIsValid(out_error, error_cap, out_error_len)) {
        return PANCAKE_ERR_NULL_POINTER;
    }
    return c.captureCallError(
        onionConnWriteFrame(conn, frame_in),
        out_error,
        error_cap,
        out_error_len,
    );
}

/// Interrupt a blocked connection read or write without freeing `conn`.
///
/// This is the cancellation half for runtimes that dispatch a blocking C call
/// to another OS thread. Stop new calls, use shutdown to wake admitted work,
/// join the runtime's operation leases, and only then release the handle.
pub export fn pancake_onion_conn_shutdown(conn: ?*PancakeOnionConn) i32 {
    c.lastErrorClear();
    const payload = connFromOpaque(conn) orelse return PANCAKE_OK;
    conn_lifecycle.shutdown(payload) catch |err| return c.failIo("onion connection shutdown", err);
    return PANCAKE_OK;
}

fn onionConnRelease(conn: ?*PancakeOnionConn) i32 {
    const payload = connFromOpaque(conn) orelse return PANCAKE_OK;
    destroyConn(payload) catch |err| return c.failIo("onion connection release", err);
    return PANCAKE_OK;
}

pub export fn pancake_onion_conn_release(
    conn: ?*PancakeOnionConn,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    c.lastErrorClear();
    if (!c.optionalCallErrorOutputIsValid(out_error, error_cap, out_error_len)) {
        return PANCAKE_ERR_NULL_POINTER;
    }
    return c.captureCallError(onionConnRelease(conn), out_error, error_cap, out_error_len);
}

/// Interrupt a blocked accept without freeing `listener` or withdrawing its
/// service. Release joins every accept already admitted. Idempotent: its wake
/// channel is pre-opened with the listener and cannot fail at shutdown time.
pub export fn pancake_onion_listener_shutdown(listener: ?*PancakeOnionListener) void {
    const payload = listenerFromOpaque(listener) orelse return;
    if (payload.operations.beginShutdown(payload.io)) payload.listener.shutdown();
}

/// Withdraw the service and release the listener. This is the only release in the
/// family with an effect on shared state: the service stops being published, so a
/// partner dialing that address afterwards finds nothing.
fn onionListenerRelease(listener: ?*PancakeOnionListener) i32 {
    const payload = listenerFromOpaque(listener) orelse return PANCAKE_OK;
    pancake_onion_listener_shutdown(listener);
    payload.operations.wait(payload.io);
    const alloc = payload.allocator;
    const failure = payload.listener.deinit();
    alloc.destroy(payload);
    if (failure) |chain| {
        c.setLastErrorChain("onion listener release", chain);
        return listenErrorToCode(chain.cause);
    }
    return PANCAKE_OK;
}

pub export fn pancake_onion_listener_release(
    listener: ?*PancakeOnionListener,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    c.lastErrorClear();
    if (!c.optionalCallErrorOutputIsValid(out_error, error_cap, out_error_len)) {
        return PANCAKE_ERR_NULL_POINTER;
    }
    return c.captureCallError(
        onionListenerRelease(listener),
        out_error,
        error_cap,
        out_error_len,
    );
}

fn dialErrorToCode(err: net.netlayer.DialError) i32 {
    return switch (err) {
        error.InvalidAddress => blk: {
            setLastError("connect: not a well-formed version 3 onion service id, or an unusable socks endpoint", .{});
            break :blk PANCAKE_ERR_INVALID_ARGUMENT;
        },
        error.ConnectionRefused => blk: {
            setLastError("connect: nothing is listening at the configured tor socks endpoint", .{});
            break :blk PANCAKE_ERR_IO;
        },
        error.NetworkUnreachable => blk: {
            setLastError("connect: tor could not reach that onion service", .{});
            break :blk PANCAKE_ERR_IO;
        },
        error.TimedOut => blk: {
            setLastError("connect: timed out reaching tor", .{});
            break :blk PANCAKE_ERR_IO;
        },
        error.OutOfMemory => PANCAKE_ERR_INTERNAL,
        else => blk: {
            setLastError("connect: onion dial failed: {s}", .{@errorName(err)});
            break :blk PANCAKE_ERR_IO;
        },
    };
}

fn listenErrorToCode(err: anyerror) i32 {
    return switch (err) {
        error.InvalidAddress => blk: {
            setLastError("listen: no control endpoint configured, so this netlayer can dial but not host", .{});
            break :blk PANCAKE_ERR_INVALID_ARGUMENT;
        },
        error.InvalidOptions => PANCAKE_ERR_INVALID_ARGUMENT,
        error.BindFailed => blk: {
            setLastError("listen: tor refused the service, or the local forward endpoint could not be bound", .{});
            break :blk PANCAKE_ERR_IO;
        },
        error.OutOfMemory => PANCAKE_ERR_INTERNAL,
        else => blk: {
            setLastError("listen: onion listener failed: {s}", .{@errorName(err)});
            break :blk PANCAKE_ERR_IO;
        },
    };
}

fn acceptErrorToCode(err: net.netlayer.AcceptError) i32 {
    return switch (err) {
        error.ConnectionLost => blk: {
            setLastError("accept: onion listener closed", .{});
            break :blk PANCAKE_ERR_IO;
        },
        error.SocketConfigurationFailed => blk: {
            setLastError("accept: transport socket configuration failed", .{});
            break :blk PANCAKE_ERR_IO;
        },
        error.WakeNudgeFailed => blk: {
            setLastError("accept: onion listener wake failed", .{});
            break :blk PANCAKE_ERR_IO;
        },
        error.WakeDrainFailed => blk: {
            setLastError("accept: onion listener wake drain failed", .{});
            break :blk PANCAKE_ERR_IO;
        },
        error.OutOfMemory => PANCAKE_ERR_INTERNAL,
    };
}

fn onReadConnectionLost(_: *OnionConnPayload) void {
    setLastError("read_frame: onion stream failed", .{});
}

fn onWriteErr(_: *OnionConnPayload, err: anyerror) void {
    setLastError("write_frame: {s}", .{@errorName(err)});
}

fn netlayerFromOpaque(netlayer: ?*PancakeOnionNetlayer) ?*OnionNetlayerPayload {
    const ptr = netlayer orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn connFromOpaque(conn: ?*PancakeOnionConn) ?*OnionConnPayload {
    const ptr = conn orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn listenerFromOpaque(listener: ?*PancakeOnionListener) ?*OnionListenerPayload {
    const ptr = listener orelse return null;
    return @ptrCast(@alignCast(ptr));
}
