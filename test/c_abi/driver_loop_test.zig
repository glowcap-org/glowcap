//! `libpancake_driver` loopback (ADR-0112): two stepping loops, each driven
//! only through the `pancake_driver_*` family, carry a whole CapTP
//! conversation over real loopback TCP sockets — listen, nonblocking dial,
//! handshake, publish and fetch, an unobserved settle arriving as a
//! COMPLETION event, and a hangup arriving as SESSION_CLOSED.
//!
//! One thread drives one loop, from constructor to release — the family's
//! own affinity contract, which the core's ownership assert enforces in safe
//! builds. The server loop therefore lives wholly on a worker thread while
//! the client lives on the test thread, exactly two embedder processes in
//! one; an admitted dial's handshake advances in the dialer's steps while the
//! serving end must be stepping too. The readiness descriptor's kernel
//! semantics are pinned natively in `test/driver/host_runtime_step_test.zig`;
//! here it only has to exist.

const std = @import("std");

const c = @import("c_abi");
const cshared = @import("c_abi_shared");
const cd = @import("c_abi_host");
const cdrv = @import("c_abi_driver");
const crelay = @import("c_abi_net_transport_relay");
const ctcp = @import("c_abi_net_transport_tcp");
const c_args = @import("../support/c_abi_args.zig");
const ws_relay = @import("../support/ws_relay.zig");
const pancake = @import("pancake");

const frame_cap: usize = 4096;
const driver_options_1s: cdrv.PancakeDriverOptions = .{
    .abi_version = cdrv.PANCAKE_DRIVER_OPTIONS_ABI_VERSION,
    .struct_size = @sizeOf(cdrv.PancakeDriverOptions),
    .wire_buffer_bytes = 1024,
    .max_pending_opens = 256,
    .handshake_ms = 1_000,
    .settle_ms = 1_000,
};
const driver_options_10s: cdrv.PancakeDriverOptions = .{
    .abi_version = cdrv.PANCAKE_DRIVER_OPTIONS_ABI_VERSION,
    .struct_size = @sizeOf(cdrv.PancakeDriverOptions),
    .wire_buffer_bytes = 1024,
    .max_pending_opens = 256,
    .handshake_ms = 10_000,
    .settle_ms = 10_000,
};
const driver_options_cap1: cdrv.PancakeDriverOptions = .{
    .abi_version = cdrv.PANCAKE_DRIVER_OPTIONS_ABI_VERSION,
    .struct_size = @sizeOf(cdrv.PancakeDriverOptions),
    .wire_buffer_bytes = 1024,
    .max_pending_opens = 1,
    .handshake_ms = 1_000,
    .settle_ms = 1_000,
};

fn expectOk(rc: i32) !void {
    try std.testing.expectEqual(c.PANCAKE_OK, rc);
}

fn expectStep(rc: i32) !void {
    try std.testing.expect(rc == c.PANCAKE_OK or rc == c.PANCAKE_ERR_WOULD_BLOCK);
}

fn retainStaticProvider(_: ?*anyopaque) callconv(.c) i32 {
    return c.PANCAKE_OK;
}

fn releaseStaticProvider(_: ?*anyopaque) callconv(.c) void {}

fn multiplexedProfile(name: []const u8) cdrv.PancakeTransportProfile {
    return .{
        .abi_version = cdrv.PANCAKE_TRANSPORT_PROFILE_ABI_VERSION,
        .struct_size = @sizeOf(cdrv.PancakeTransportProfile),
        .transport_name = name.ptr,
        .transport_name_len = name.len,
        .designator_scheme = cdrv.PANCAKE_DESIGNATOR_SCHEME_ADDRESS,
        .sealed_channel = cdrv.PANCAKE_SEALED_CHANNEL_NONE,
    };
}

fn addMultiplexedProviderWithProfile(
    loop: ?*cdrv.PancakeDriverLoop,
    resident: *const cdrv.PancakeMultiplexedTransport,
    profile: *const cdrv.PancakeTransportProfile,
) i32 {
    const entry: cdrv.PancakeTransportProviderEntry = .{
        .profile = profile,
        .execution_model = cdrv.PANCAKE_TRANSPORT_EXEC_MULTIPLEXED,
        .implementation = resident,
    };
    const provider: cdrv.PancakeTransportProvider = .{
        .abi_version = cdrv.PANCAKE_TRANSPORT_PROVIDER_ABI_VERSION,
        .struct_size = @sizeOf(cdrv.PancakeTransportProvider),
        .entries = @ptrCast(&entry),
        .entry_count = 1,
        .lease_ctx = null,
        .retain = retainStaticProvider,
        .release = releaseStaticProvider,
    };
    return cdrv.pancake_driver_add_provider(loop, &provider);
}

fn addMultiplexedProvider(loop: ?*cdrv.PancakeDriverLoop, resident: *const cdrv.PancakeMultiplexedTransport, name: []const u8) i32 {
    const profile = multiplexedProfile(name);
    return addMultiplexedProviderWithProfile(loop, resident, &profile);
}

fn openAccepted(
    host: ?*cd.PancakeHost,
    transport: ?[*]const u8,
    transport_len: usize,
    out_session: ?*?*cd.PancakeHostSession,
) i32 {
    return cd.pancake_host_session_open_accepted(
        host,
        transport,
        transport_len,
        out_session,
    );
}

fn readListenerLocator(loop: ?*cdrv.PancakeDriverLoop, listener: u64) !pancake.ocapn.model.PeerLocator {
    var borrowed: cdrv.PancakeLocatorView = undefined;
    try expectOk(cdrv.pancake_driver_listener_locator(loop, listener, &borrowed));
    var handle: ?*c.PancakeLocator = null;
    try expectOk(c.pancake_locator_clone(&borrowed, &handle));
    defer c.pancake_locator_release(handle);

    const allocator = std.testing.allocator;
    const readField = struct {
        fn call(
            locator: ?*c.PancakeLocator,
            accessor: *const fn (?*c.PancakeLocator, ?*?[*]const u8, ?*usize) callconv(.c) i32,
        ) ![]u8 {
            var ptr: ?[*]const u8 = null;
            var len: usize = 0;
            try expectOk(accessor(locator, &ptr, &len));
            return allocator.dupe(u8, if (len == 0) &.{} else ptr.?[0..len]);
        }
    }.call;
    const transport = try readField(handle, c.pancake_locator_transport);
    errdefer allocator.free(transport);
    const designator = try readField(handle, c.pancake_locator_designator);
    errdefer allocator.free(designator);
    var hint_count: usize = 0;
    try expectOk(c.pancake_locator_hint_count(handle, &hint_count));
    const hints = try allocator.alloc(pancake.ocapn.model.HintEntry, hint_count);
    errdefer allocator.free(hints);
    var initialized: usize = 0;
    errdefer for (hints[0..initialized]) |entry| pancake.ocapn.model.freeHintEntry(allocator, entry);
    for (hints) |*entry| {
        var view: cdrv.PancakeLocatorHintView = undefined;
        try expectOk(c.pancake_locator_hint_at(handle, initialized, &view));
        const name = try allocator.dupe(u8, view.name.?[0..view.name_len]);
        errdefer allocator.free(name);
        const value: pancake.ocapn.model.HintValue = switch (view.kind) {
            cdrv.PANCAKE_HINT_STRING => .{ .string = try allocator.dupe(u8, if (view.bytes_len == 0) &.{} else view.bytes.?[0..view.bytes_len]) },
            cdrv.PANCAKE_HINT_BYTES => .{ .bytes = try allocator.dupe(u8, if (view.bytes_len == 0) &.{} else view.bytes.?[0..view.bytes_len]) },
            cdrv.PANCAKE_HINT_BOOLEAN => .{ .boolean = view.boolean_value == 1 },
            cdrv.PANCAKE_HINT_INTEGER => .{ .integer = view.integer_value },
            else => return error.InvalidHintKind,
        };
        entry.* = .{ .name = name, .value = value };
        initialized += 1;
    }
    var raw_wire_form: u32 = undefined;
    try expectOk(c.pancake_locator_hint_wire_form(handle, &raw_wire_form));
    const wire_form: pancake.ocapn.model.Hints.WireForm = switch (raw_wire_form) {
        cdrv.PANCAKE_HINTS_MAP => .map,
        cdrv.PANCAKE_HINTS_BOOLEAN_FALSE => .boolean_false,
        else => return error.InvalidHintWireForm,
    };
    return .{ .transport = transport, .designator = designator, .hints = .{ .entries = hints, .wire_form = wire_form } };
}

fn expectLoopReadable(loop: ?*cdrv.PancakeDriverLoop) !void {
    var fd: i32 = -1;
    try expectOk(cdrv.pancake_driver_readiness_fd(loop, &fd));
    var fds = [_]std.posix.pollfd{
        .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 },
    };
    try std.testing.expectEqual(@as(usize, 1), try std.posix.poll(&fds, 1_000));
}

fn directAddresses(locator: pancake.ocapn.model.PeerLocator) ?[]const u8 {
    for (locator.hints.entries) |entry| {
        if (!std.mem.eql(u8, entry.name, pancake.ocapn.model.transport.hint_direct_addresses)) continue;
        return switch (entry.value) {
            .string => |value| value,
            else => null,
        };
    }
    return null;
}

fn callWithLocator(
    transport: []const u8,
    designator: []const u8,
    direct: []const u8,
    ctx: anytype,
    comptime call: fn (@TypeOf(ctx), *const cdrv.PancakeLocatorView) i32,
) i32 {
    var locator: ?*c.PancakeLocator = null;
    const wire_form = if (direct.len == 0) cdrv.PANCAKE_HINTS_BOOLEAN_FALSE else cdrv.PANCAKE_HINTS_MAP;
    const created = c.pancake_locator_new(
        transport.ptr,
        transport.len,
        designator.ptr,
        designator.len,
        wire_form,
        &locator,
    );
    if (created != c.PANCAKE_OK) return created;
    defer c.pancake_locator_release(locator);
    if (direct.len != 0) {
        const added = c.pancake_locator_add_string(
            locator,
            pancake.ocapn.model.transport.hint_direct_addresses,
            pancake.ocapn.model.transport.hint_direct_addresses.len,
            direct.ptr,
            direct.len,
        );
        if (added != c.PANCAKE_OK) return added;
    }
    var view: ?*const c.PancakeLocatorView = null;
    const borrowed = c.pancake_locator_borrow_view(locator, &view);
    if (borrowed != c.PANCAKE_OK) return borrowed;
    return call(ctx, view.?);
}

fn dialParts(loop: ?*cdrv.PancakeDriverLoop, transport: []const u8, designator: []const u8, direct: []const u8, out_ticket: *u64) !i32 {
    const Context = struct { loop: ?*cdrv.PancakeDriverLoop, ticket: *u64 };
    return callWithLocator(transport, designator, direct, Context{ .loop = loop, .ticket = out_ticket }, struct {
        fn call(ctx: Context, locator: *const cdrv.PancakeLocatorView) i32 {
            return cdrv.pancake_driver_dial(ctx.loop, locator, ctx.ticket);
        }
    }.call);
}

fn dialLocator(
    loop: ?*cdrv.PancakeDriverLoop,
    locator: pancake.ocapn.model.PeerLocator,
    out_ticket: *u64,
) !i32 {
    var hints: [cshared.locator_adapter.inline_hint_capacity]cdrv.PancakeLocatorHintView = undefined;
    var projection = try cshared.locator_adapter.Projection.init(
        std.testing.allocator,
        locator,
        &hints,
    );
    defer projection.deinit(std.testing.allocator);
    return cdrv.pancake_driver_dial(loop, &projection.view, out_ticket);
}

fn advertiseParts(loop: ?*cdrv.PancakeDriverLoop, listener: u64, transport: []const u8, designator: []const u8, direct: []const u8) !i32 {
    const Context = struct { loop: ?*cdrv.PancakeDriverLoop, listener: u64 };
    return callWithLocator(transport, designator, direct, Context{ .loop = loop, .listener = listener }, struct {
        fn call(ctx: Context, locator: *const cdrv.PancakeLocatorView) i32 {
            return cdrv.pancake_driver_listener_advertise(ctx.loop, ctx.listener, locator);
        }
    }.call);
}

/// Durable identity in the first 32 bytes, deterministic session-key root in
/// the rest — the only seed length the host constructor accepts (ADR-0097).
fn hostSeed(durable_byte: u8) [64]u8 {
    var seed: [64]u8 = undefined;
    @memset(seed[0..32], durable_byte);
    @memset(seed[32..], durable_byte ^ 0xa5);
    return seed;
}

const TestLoop = struct {
    raw: ?*cdrv.PancakeDriverLoop,
    host: ?*cd.PancakeHost,

    fn deinit(self: TestLoop) void {
        _ = cdrv.pancake_driver_release(self.raw);
    }
};

fn installTcp(loop: ?*cdrv.PancakeDriverLoop) !void {
    var tcp: ?*ctcp.PancakeTcpNetlayer = null;
    try expectOk(ctcp.pancake_tcp_netlayer_new(&tcp));
    defer ctcp.pancake_tcp_netlayer_release(tcp);
    var provider: cdrv.PancakeTransportProvider = undefined;
    try expectOk(ctcp.pancake_tcp_transport_provider(tcp, &provider));
    try expectOk(cdrv.pancake_driver_add_provider(loop, &provider));
}

fn installRelay(
    loop: ?*cdrv.PancakeDriverLoop,
    relay_url: []const u8,
    register_url: []const u8,
) !void {
    const config: crelay.PancakeRelayConfig = .{
        .relay_url = relay_url.ptr,
        .relay_url_len = relay_url.len,
        .register_url = register_url.ptr,
        .register_url_len = register_url.len,
    };
    var runtime: ?*crelay.PancakeRelayRuntime = null;
    try expectOk(crelay.pancake_relay_runtime_new(&config, &runtime));
    defer crelay.pancake_relay_runtime_release(runtime);
    var provider: cdrv.PancakeTransportProvider = undefined;
    try expectOk(crelay.pancake_relay_transport_provider(runtime, &provider));
    try expectOk(cdrv.pancake_driver_add_provider(loop, &provider));
}

fn newLoop(seed_byte: u8) !TestLoop {
    const host = try newByteFedHost(seed_byte);
    errdefer _ = cd.pancake_host_release(host);
    var loop: ?*cdrv.PancakeDriverLoop = null;
    try expectOk(cdrv.pancake_driver_take_host(host, &driver_options_10s, &loop));
    errdefer _ = cdrv.pancake_driver_release(loop);
    try installTcp(loop);
    return .{ .raw = loop, .host = host };
}

fn newByteFedHost(seed_byte: u8) !?*cd.PancakeHost {
    var host: ?*cd.PancakeHost = null;
    const seed = hostSeed(seed_byte);
    try expectOk(cd.pancake_host_new(
        &seed,
        seed.len,
        frame_cap,
        1,
        c.PANCAKE_CODEC_SYRUP,
        c.PANCAKE_CAPTP_V1_0,
        c.PANCAKE_FEATURE_FULL,
        0,
        &host,
    ));
    return host;
}

const InvalidMultiplexedResident = struct {
    wake: pancake.net.wake_channel.WakeChannel,
    invalid_mask: bool = false,
    connect_with_readable: bool = false,
    listen_without_handle: bool = false,
    connect_io: bool = false,
    pending_request: ?u64 = null,
    connection_readable: bool = false,
    read_result: ?isize = null,
    write_result: ?isize = null,

    fn readinessFd(ctx: ?*anyopaque) callconv(.c) i32 {
        const self: *InvalidMultiplexedResident = @ptrCast(@alignCast(ctx.?));
        return self.wake.read;
    }

    fn drainReady(ctx: ?*anyopaque, out: ?[*]cdrv.PancakeMultiplexedReadyEvent, cap: usize) callconv(.c) usize {
        const self: *InvalidMultiplexedResident = @ptrCast(@alignCast(ctx.?));
        if (self.invalid_mask) {
            if (cap == 0) return 0;
            out.?[0] = .{ .subject = 0, .events = 32 };
            return 1;
        }
        if (self.connect_with_readable) {
            if (cap == 0) return 0;
            out.?[0] = .{
                .subject = 1,
                .events = cdrv.PANCAKE_MULTIPLEXED_EV_CONNECT | cdrv.PANCAKE_MULTIPLEXED_EV_READABLE,
            };
            return 1;
        }
        if (self.connect_io) {
            self.wake.drain();
            if (cap == 0) return 0;
            if (self.pending_request) |request| {
                out.?[0] = .{
                    .subject = request,
                    .events = cdrv.PANCAKE_MULTIPLEXED_EV_CONNECT,
                };
                return 1;
            }
            if (self.connection_readable) {
                self.connection_readable = false;
                out.?[0] = .{
                    .subject = 7,
                    .events = cdrv.PANCAKE_MULTIPLEXED_EV_READABLE,
                };
                return 1;
            }
            return 0;
        }
        return cap + 1;
    }

    fn startConnect(ctx: ?*anyopaque, request: u64, _: ?*const cdrv.PancakeLocatorView) callconv(.c) i32 {
        const self: *InvalidMultiplexedResident = @ptrCast(@alignCast(ctx.?));
        if (!self.connect_io or self.pending_request != null) return c.PANCAKE_ERR_INVALID_ARGUMENT;
        self.pending_request = request;
        self.wake.nudge();
        return c.PANCAKE_OK;
    }

    fn finishConnect(ctx: ?*anyopaque, request: u64, out_conn: ?*u64) callconv(.c) i32 {
        const self: *InvalidMultiplexedResident = @ptrCast(@alignCast(ctx.?));
        if (!self.connect_io or self.pending_request != request) return c.PANCAKE_ERR_INVALID_ARGUMENT;
        self.pending_request = null;
        self.connection_readable = true;
        self.wake.nudge();
        out_conn.?.* = 7;
        return c.PANCAKE_OK;
    }

    fn claimExternal(_: ?*anyopaque, _: u64, _: ?*u64) callconv(.c) i32 {
        return c.PANCAKE_ERR_INVALID_ARGUMENT;
    }

    fn subject(_: ?*anyopaque, _: u64) callconv(.c) void {}

    fn startListen(
        ctx: ?*anyopaque,
        _: u64,
        _: ?[*]const u8,
        _: usize,
        _: ?[*]const u8,
        _: usize,
        _: ?*?*anyopaque,
    ) callconv(.c) i32 {
        const self: *InvalidMultiplexedResident = @ptrCast(@alignCast(ctx.?));
        if (self.listen_without_handle) return c.PANCAKE_OK;
        return c.PANCAKE_ERR_INVALID_ARGUMENT;
    }

    fn listenerLocator(_: ?*anyopaque, _: ?*anyopaque, _: cdrv.PancakeLocatorSinkFn) callconv(.c) i32 {
        return c.PANCAKE_ERR_INVALID_ARGUMENT;
    }

    fn listenerAdvertise(
        _: ?*anyopaque,
        view: ?*const cdrv.PancakeLocatorView,
        sink_ctx: ?*anyopaque,
        sink: cdrv.PancakeLocatorSinkFn,
    ) callconv(.c) i32 {
        return sink(sink_ctx, view);
    }

    fn finishAccept(_: ?*anyopaque, _: ?*u64) callconv(.c) i32 {
        return c.PANCAKE_ERR_WOULD_BLOCK;
    }

    fn stopListen(_: ?*anyopaque) callconv(.c) void {}

    fn tryRead(ctx: ?*anyopaque, _: u64, _: ?[*]u8, _: usize) callconv(.c) isize {
        const self: *InvalidMultiplexedResident = @ptrCast(@alignCast(ctx.?));
        return self.read_result orelse cdrv.PANCAKE_MULTIPLEXED_WOULD_BLOCK;
    }

    fn tryWrite(ctx: ?*anyopaque, _: u64, _: ?[*]const u8, len: usize) callconv(.c) isize {
        const self: *InvalidMultiplexedResident = @ptrCast(@alignCast(ctx.?));
        if (self.write_result) |result| return result;
        return if (self.connect_io) @intCast(len) else cdrv.PANCAKE_MULTIPLEXED_WOULD_BLOCK;
    }

    fn remoteKey(_: ?*anyopaque, _: u64, _: ?[*]u8) callconv(.c) i32 {
        return 0;
    }

    fn table(self: *InvalidMultiplexedResident) cdrv.PancakeMultiplexedTransport {
        return .{
            .abi_version = cdrv.PANCAKE_MULTIPLEXED_TRANSPORT_ABI_VERSION,
            .struct_size = @sizeOf(cdrv.PancakeMultiplexedTransport),
            .ctx = self,
            .readiness_fd = readinessFd,
            .drain_ready = drainReady,
            .start_connect = startConnect,
            .finish_connect = finishConnect,
            .cancel_connect = subject,
            .start_listen = startListen,
            .listener_locator = listenerLocator,
            .listener_advertise = listenerAdvertise,
            .finish_accept = finishAccept,
            .stop_listen = stopListen,
            .try_read = tryRead,
            .try_write = tryWrite,
            .conn_close = subject,
            .conn_remote_key = remoteKey,
        };
    }
};

/// A dial-only multiplexed resident that admits without allocating, then reports one
/// failed connect through readiness. It isolates post-admission event
/// publication from transport and teardown allocation in the fail-stop test.
const AsyncFailureResident = struct {
    wake: pancake.net.wake_channel.WakeChannel,
    pending: ?u64 = null,

    fn self(ctx: ?*anyopaque) *AsyncFailureResident {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn readinessFd(ctx: ?*anyopaque) callconv(.c) i32 {
        return self(ctx).wake.read;
    }

    fn drainReady(ctx: ?*anyopaque, out: ?[*]cdrv.PancakeMultiplexedReadyEvent, cap: usize) callconv(.c) usize {
        const resident = self(ctx);
        resident.wake.drain();
        if (cap == 0) return 0;
        const request = resident.pending orelse return 0;
        out.?[0] = .{ .subject = request, .events = cdrv.PANCAKE_MULTIPLEXED_EV_CONNECT };
        return 1;
    }

    fn startConnect(ctx: ?*anyopaque, request: u64, _: ?*const cdrv.PancakeLocatorView) callconv(.c) i32 {
        const resident = self(ctx);
        if (resident.pending != null) return c.PANCAKE_ERR_INVALID_ARGUMENT;
        resident.pending = request;
        resident.wake.nudge();
        return c.PANCAKE_OK;
    }

    fn finishConnect(ctx: ?*anyopaque, request: u64, _: ?*u64) callconv(.c) i32 {
        const resident = self(ctx);
        if (resident.pending != request) return c.PANCAKE_ERR_INVALID_ARGUMENT;
        resident.pending = null;
        return c.PANCAKE_ERR_IO;
    }

    fn cancelConnect(ctx: ?*anyopaque, request: u64) callconv(.c) void {
        const resident = self(ctx);
        if (resident.pending == request) resident.pending = null;
    }

    fn tryRead(_: ?*anyopaque, _: u64, _: ?[*]u8, _: usize) callconv(.c) isize {
        return cdrv.PANCAKE_MULTIPLEXED_WOULD_BLOCK;
    }

    fn tryWrite(_: ?*anyopaque, _: u64, _: ?[*]const u8, _: usize) callconv(.c) isize {
        return cdrv.PANCAKE_MULTIPLEXED_WOULD_BLOCK;
    }

    fn connClose(_: ?*anyopaque, _: u64) callconv(.c) void {}

    fn remoteKey(_: ?*anyopaque, _: u64, _: ?[*]u8) callconv(.c) i32 {
        return 0;
    }

    fn table(resident: *AsyncFailureResident) cdrv.PancakeMultiplexedTransport {
        return .{
            .abi_version = cdrv.PANCAKE_MULTIPLEXED_TRANSPORT_ABI_VERSION,
            .struct_size = @sizeOf(cdrv.PancakeMultiplexedTransport),
            .ctx = resident,
            .readiness_fd = readinessFd,
            .drain_ready = drainReady,
            .start_connect = startConnect,
            .finish_connect = finishConnect,
            .cancel_connect = cancelConnect,
            .start_listen = null,
            .listener_locator = null,
            .listener_advertise = null,
            .finish_accept = null,
            .stop_listen = null,
            .try_read = tryRead,
            .try_write = tryWrite,
            .conn_close = connClose,
            .conn_remote_key = remoteKey,
        };
    }
};

const TypedResident = struct {
    wake: pancake.net.wake_channel.WakeChannel,
    opaque_hint: []const u8,
    listeners: [2]Listener = undefined,
    listener_count: usize = 0,
    dial_verified: bool = false,
    retains: usize = 0,
    releases: usize = 0,

    const Listener = struct {
        resident: *TypedResident,
        transport: []const u8,
        active: bool = true,
    };

    fn self(ctx: ?*anyopaque) *TypedResident {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn listener(ctx: ?*anyopaque) *Listener {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn retain(ctx: ?*anyopaque) callconv(.c) i32 {
        self(ctx).retains += 1;
        return c.PANCAKE_OK;
    }

    fn release(ctx: ?*anyopaque) callconv(.c) void {
        self(ctx).releases += 1;
    }

    fn readinessFd(ctx: ?*anyopaque) callconv(.c) i32 {
        return self(ctx).wake.read;
    }

    fn drainReady(_: ?*anyopaque, _: ?[*]cdrv.PancakeMultiplexedReadyEvent, _: usize) callconv(.c) usize {
        return 0;
    }

    fn startConnect(ctx: ?*anyopaque, _: u64, view: ?*const cdrv.PancakeLocatorView) callconv(.c) i32 {
        const resident = self(ctx);
        const locator_view = view orelse return c.PANCAKE_ERR_NULL_POINTER;
        var hint_storage: [4]pancake.ocapn.model.HintEntry = undefined;
        const locator = cshared.locator_adapter.fromView(locator_view, &hint_storage) catch
            return c.PANCAKE_ERR_INVALID_ARGUMENT;
        if (!std.mem.eql(u8, locator.transport, "typed-test") or
            !std.mem.eql(u8, locator.designator, "dial-peer") or
            locator.hints.entries.len != 4)
            return c.PANCAKE_ERR_INVALID_ARGUMENT;
        const expected_names = [_][]const u8{ "route", "token", "enabled", "limit" };
        for (locator.hints.entries, expected_names) |entry, name| {
            if (!std.mem.eql(u8, entry.name, name)) return c.PANCAKE_ERR_INVALID_ARGUMENT;
        }
        if (!std.mem.eql(u8, locator.hints.entries[0].value.string, "alternate")) return c.PANCAKE_ERR_INVALID_ARGUMENT;
        if (!std.mem.eql(u8, locator.hints.entries[1].value.bytes, &.{ 0, 0xff, 7 })) return c.PANCAKE_ERR_INVALID_ARGUMENT;
        if (!locator.hints.entries[2].value.boolean) return c.PANCAKE_ERR_INVALID_ARGUMENT;
        if (locator.hints.entries[3].value.integer != -42) return c.PANCAKE_ERR_INVALID_ARGUMENT;
        resident.dial_verified = true;
        return c.PANCAKE_ERR_INVALID_ARGUMENT;
    }

    fn finishConnect(_: ?*anyopaque, _: u64, _: ?*u64) callconv(.c) i32 {
        return c.PANCAKE_ERR_INVALID_ARGUMENT;
    }

    fn subject(_: ?*anyopaque, _: u64) callconv(.c) void {}

    fn startListen(
        ctx: ?*anyopaque,
        _: u64,
        transport: ?[*]const u8,
        transport_len: usize,
        designator: ?[*]const u8,
        len: usize,
        out_listener: ?*?*anyopaque,
    ) callconv(.c) i32 {
        const selected = (transport orelse return c.PANCAKE_ERR_NULL_POINTER)[0..transport_len];
        const canonical = if (std.mem.eql(u8, selected, "typed-test"))
            "typed-test"
        else if (std.mem.eql(u8, selected, "typed-test-alt"))
            "typed-test-alt"
        else
            return c.PANCAKE_ERR_INVALID_ARGUMENT;
        const requested = if (len == 0) "" else (designator orelse return c.PANCAKE_ERR_NULL_POINTER)[0..len];
        if (!std.mem.eql(u8, requested, "listener-peer")) return c.PANCAKE_ERR_INVALID_ARGUMENT;
        const resident = self(ctx);
        if (resident.listener_count == resident.listeners.len) return c.PANCAKE_ERR_INVALID_ARGUMENT;
        const slot = &resident.listeners[resident.listener_count];
        resident.listener_count += 1;
        slot.* = .{ .resident = resident, .transport = canonical };
        (out_listener orelse return c.PANCAKE_ERR_NULL_POINTER).* = slot;
        return c.PANCAKE_OK;
    }

    fn listenerLocator(
        ctx: ?*anyopaque,
        sink_ctx: ?*anyopaque,
        sink: cdrv.PancakeLocatorSinkFn,
    ) callconv(.c) i32 {
        const active = listener(ctx);
        if (!active.active) return c.PANCAKE_ERR_INVALID_ARGUMENT;
        const resident = active.resident;
        const hints = [_]pancake.ocapn.model.HintEntry{
            .{ .name = "route", .value = .{ .string = "primary" } },
            .{ .name = "token", .value = .{ .bytes = resident.opaque_hint } },
            .{ .name = "enabled", .value = .{ .boolean = true } },
            .{ .name = "limit", .value = .{ .integer = 73 } },
        };
        const locator: pancake.ocapn.model.PeerLocator = .{
            .transport = active.transport,
            .designator = "listener-peer",
            .hints = .{ .entries = &hints, .wire_form = .map },
        };
        var c_hints: [hints.len]cdrv.PancakeLocatorHintView = undefined;
        const view = cshared.locator_adapter.project(locator, &c_hints) catch
            return c.PANCAKE_ERR_INVALID_ARGUMENT;
        return sink(sink_ctx, &view);
    }

    fn listenerAdvertise(
        _: ?*anyopaque,
        view: ?*const cdrv.PancakeLocatorView,
        sink_ctx: ?*anyopaque,
        sink: cdrv.PancakeLocatorSinkFn,
    ) callconv(.c) i32 {
        return sink(sink_ctx, view);
    }

    fn finishAccept(_: ?*anyopaque, _: ?*u64) callconv(.c) i32 {
        return c.PANCAKE_ERR_WOULD_BLOCK;
    }

    fn stopListen(ctx: ?*anyopaque) callconv(.c) void {
        listener(ctx).active = false;
    }

    fn tryRead(_: ?*anyopaque, _: u64, _: ?[*]u8, _: usize) callconv(.c) isize {
        return cdrv.PANCAKE_MULTIPLEXED_WOULD_BLOCK;
    }

    fn tryWrite(_: ?*anyopaque, _: u64, _: ?[*]const u8, _: usize) callconv(.c) isize {
        return cdrv.PANCAKE_MULTIPLEXED_WOULD_BLOCK;
    }

    fn remoteKey(_: ?*anyopaque, _: u64, _: ?[*]u8) callconv(.c) i32 {
        return 0;
    }

    fn table(resident: *TypedResident) cdrv.PancakeMultiplexedTransport {
        return .{
            .abi_version = cdrv.PANCAKE_MULTIPLEXED_TRANSPORT_ABI_VERSION,
            .struct_size = @sizeOf(cdrv.PancakeMultiplexedTransport),
            .ctx = resident,
            .readiness_fd = readinessFd,
            .drain_ready = drainReady,
            .start_connect = startConnect,
            .finish_connect = finishConnect,
            .cancel_connect = subject,
            .start_listen = startListen,
            .listener_locator = listenerLocator,
            .listener_advertise = listenerAdvertise,
            .finish_accept = finishAccept,
            .stop_listen = stopListen,
            .try_read = tryRead,
            .try_write = tryWrite,
            .conn_close = subject,
            .conn_remote_key = remoteKey,
        };
    }
};

fn widgetBehavior(
    ctx: ?*anyopaque,
    turn: ?*cd.PancakeHostTurn,
    verb: [*]const u8,
    verb_len: usize,
    args: ?[*]const c.PancakeArgument,
    args_len: usize,
    out_reply: *c.PancakeArgument,
) callconv(.c) i32 {
    _ = .{ ctx, turn, args, args_len };
    if (!std.mem.eql(u8, verb[0..verb_len], "poke")) return c.PANCAKE_ERR_INVALID_ARGUMENT;
    out_reply.* = c_args.argStr("poked through the driver archive");
    return c.PANCAKE_OK;
}

/// What one loop's drained events amounted to; scalar facts only, because a
/// COMPLETION's views die at the next `pancake_driver_next_event`.
const Drained = struct {
    dialed_session: ?*cd.PancakeHostSession = null,
    dialed_ticket: u64 = 0,
    dial_failed: bool = false,
    accepted: bool = false,
    accepted_listener: u64 = 0,
    accepted_session: ?*cd.PancakeHostSession = null,
    closed: bool = false,
    settle_ticket: u64 = 0,
    fail_ticket: u64 = 0,
};

fn drainEvents(loop: ?*cdrv.PancakeDriverLoop, into: *Drained) !void {
    var event: cdrv.PancakeDriverEvent = undefined;
    while (true) {
        const rc = cdrv.pancake_driver_next_event(loop, &event);
        if (rc == c.PANCAKE_ERR_WOULD_BLOCK) return;
        try expectOk(rc);
        switch (event.kind) {
            cdrv.PANCAKE_DRIVER_EVENT_OPENED => {
                into.dialed_session = event.session;
                into.dialed_ticket = event.ticket;
            },
            cdrv.PANCAKE_DRIVER_EVENT_OPEN_FAILED => {
                into.dial_failed = true;
                if (event.message) |msg| std.debug.print("dial failed: {s}\n", .{msg[0..event.message_len]});
            },
            cdrv.PANCAKE_DRIVER_EVENT_ACCEPTED => {
                into.accepted = true;
                into.accepted_listener = event.ticket;
                into.accepted_session = event.session;
            },
            cdrv.PANCAKE_DRIVER_EVENT_SESSION_CLOSED => into.closed = true,
            cdrv.PANCAKE_DRIVER_EVENT_COMPLETION => switch (event.action.kind) {
                cd.PANCAKE_HOST_ACTION_SETTLE => into.settle_ticket = event.action.ticket,
                cd.PANCAKE_HOST_ACTION_FAIL => into.fail_ticket = event.action.ticket,
                else => return error.UnexpectedCompletionKind,
            },
            else => return error.UnexpectedEventKind,
        }
    }
}

test "loop refusals speak through the driver family's own error slot" {
    var loop_slot: ?*cdrv.PancakeDriverLoop = null;
    // A null Host is a null-pointer refusal.
    try std.testing.expectEqual(
        c.PANCAKE_ERR_NULL_POINTER,
        cdrv.pancake_driver_take_host(null, &driver_options_1s, &loop_slot),
    );
    // A zero option is refused with a message in this family's own slot.
    const host = try newByteFedHost(0x33);
    defer _ = cd.pancake_host_release(host);
    try std.testing.expectEqual(
        c.PANCAKE_ERR_NULL_POINTER,
        cdrv.pancake_driver_take_host(host, null, &loop_slot),
    );
    try std.testing.expectEqual(
        c.PANCAKE_ERR_NULL_POINTER,
        cdrv.pancake_driver_take_host(host, &driver_options_1s, null),
    );
    var invalid_options = driver_options_1s;
    invalid_options.abi_version += 1;
    cdrv.pancake_driver_clear_last_error();
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cdrv.pancake_driver_take_host(host, &invalid_options, &loop_slot),
    );
    invalid_options = driver_options_1s;
    invalid_options.struct_size = @offsetOf(cdrv.PancakeDriverOptions, "settle_ms");
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cdrv.pancake_driver_take_host(host, &invalid_options, &loop_slot),
    );
    invalid_options = driver_options_1s;
    invalid_options.wire_buffer_bytes = 0;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cdrv.pancake_driver_take_host(host, &invalid_options, &loop_slot),
    );
    invalid_options = driver_options_1s;
    invalid_options.handshake_ms = cdrv.PANCAKE_DRIVER_MAX_WAIT_MS + 1;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cdrv.pancake_driver_take_host(host, &invalid_options, &loop_slot),
    );
    var message: [256]u8 = undefined;
    try std.testing.expect(cdrv.pancake_driver_last_error(&message, message.len) > 0);
    cdrv.pancake_driver_clear_last_error();
    try std.testing.expectEqual(@as(usize, 0), cdrv.pancake_driver_last_error(&message, message.len));

    const owned_loop = try newLoop(0x34);
    defer owned_loop.deinit();
    const loop = owned_loop.raw;
    // A resident table with unset function pointers is refused before any
    // registration happens.
    var table = std.mem.zeroes(cdrv.PancakeMultiplexedTransport);
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        addMultiplexedProvider(loop, &table, "invalid-count"),
    );
    table.abi_version = cdrv.PANCAKE_MULTIPLEXED_TRANSPORT_ABI_VERSION;
    table.struct_size = @offsetOf(cdrv.PancakeMultiplexedTransport, "ctx");
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        addMultiplexedProvider(loop, &table, "invalid-count"),
    );
    var profile = multiplexedProfile("invalid-count");
    profile.abi_version = 0;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        addMultiplexedProviderWithProfile(loop, &table, &profile),
    );
    // Wake is callable before the readiness set is armed (a no-op then), and
    // the thread handover verb round-trips: after a detach, the next verb on
    // this same thread re-claims.
    try expectOk(cdrv.pancake_driver_wake(loop));
    try expectOk(cdrv.pancake_driver_detach_thread(loop));
    try expectStep(cdrv.pancake_driver_step(loop, 0));
}

test "a quiescent byte-fed Host transfers exclusively to the driver" {
    const host = try newByteFedHost(0x31);
    try expectOk(cd.pancake_host_publish(host, "widget", 6, widgetBehavior, null, null));

    var loop: ?*cdrv.PancakeDriverLoop = null;
    try expectOk(cdrv.pancake_driver_take_host(host, &driver_options_1s, &loop));
    try installTcp(loop);
    defer _ = cdrv.pancake_driver_release(loop);

    // One runtime owns transport execution and terminal release. Neither a
    // second loop nor the old Host release path can acquire that authority.
    var second: ?*cdrv.PancakeDriverLoop = null;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cdrv.pancake_driver_take_host(host, &driver_options_1s, &second),
    );
    try std.testing.expect(second == null);
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, cd.pancake_host_release(host));

    // Application state created before transfer remains on the same Host, and
    // transport lifecycle is immediately usable through the generic driver.
    var listener: u64 = 0;
    try expectOk(cdrv.pancake_driver_listen(loop, "tcp", 3, "127.0.0.1:0", 11, &listener));
    const locator = try readListenerLocator(loop, listener);
    defer pancake.ocapn.model.freePeerLocator(std.testing.allocator, locator);
    try std.testing.expectEqualStrings("tcp", locator.transport);
}

test "an unborrowed Host dial transfers with the Host" {
    const host = try newByteFedHost(0x35);
    const sturdyref = "ocapn://127.0.0.1%3A7999.tcp/s/d2lkZ2V0";
    var vow: u64 = 0;
    try expectOk(cd.pancake_host_enliven(host, sturdyref, sturdyref.len, &vow));
    try std.testing.expect(vow != 0);

    var loop: ?*cdrv.PancakeDriverLoop = null;
    try expectOk(cdrv.pancake_driver_take_host(host, &driver_options_1s, &loop));
    defer _ = cdrv.pancake_driver_release(loop);

    // The driver owns the original queued action. The former byte-fed drain
    // cannot race it after the transaction commits.
    var action: cd.PancakeHostAction = undefined;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cd.pancake_host_next_action(host, &action),
    );
}

test "borrowing a Host action prevents runtime transfer" {
    const host = try newByteFedHost(0x36);
    defer _ = cd.pancake_host_release(host);
    const sturdyref = "ocapn://127.0.0.1%3A7999.tcp/s/d2lkZ2V0";
    var vow: u64 = 0;
    try expectOk(cd.pancake_host_enliven(host, sturdyref, sturdyref.len, &vow));

    var action: cd.PancakeHostAction = undefined;
    try expectOk(cd.pancake_host_next_action(host, &action));
    try std.testing.expectEqual(cd.PANCAKE_HOST_ACTION_DIAL, action.kind);

    var loop: ?*cdrv.PancakeDriverLoop = null;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cdrv.pancake_driver_take_host(host, &driver_options_1s, &loop),
    );
    try std.testing.expect(loop == null);
}

test "failed Host adoption rolls runtime ownership back" {
    const CountingHost = @import("../support/c_abi_counting_alloc.zig").CountingHost;
    var counting = CountingHost{};
    const spec = counting.spec();
    var ctx: ?*c.PancakeContext = null;
    try expectOk(c.pancake_context_new_with_allocator(&spec, &ctx));

    const seed = hostSeed(0x32);
    var host: ?*cd.PancakeHost = null;
    try expectOk(cd.pancake_host_new_in(
        ctx,
        &seed,
        seed.len,
        frame_cap,
        1,
        c.PANCAKE_CODEC_SYRUP,
        c.PANCAKE_CAPTP_V1_0,
        c.PANCAKE_FEATURE_FULL,
        0,
        &host,
    ));

    counting.fail_allocations = true;
    var loop: ?*cdrv.PancakeDriverLoop = null;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INTERNAL,
        cdrv.pancake_driver_take_host(host, &driver_options_1s, &loop),
    );
    try std.testing.expect(loop == null);
    counting.fail_allocations = false;

    // Construction failed after the claim. The original owner can still use
    // and release the Host, and every allocation returns through its context.
    try expectOk(cd.pancake_host_set_session_limits(host, 0, 19, 0));
    try expectOk(cd.pancake_host_release(host));
    c.pancake_context_release(ctx);
    try std.testing.expect(counting.balanced());
}

test "a Host with byte-fed session state cannot transfer runtimes" {
    const host = try newByteFedHost(0x30);
    defer _ = cd.pancake_host_release(host);
    try expectOk(cd.pancake_host_ensure_advertised_locator(host, "tcp", 3));
    var session: ?*cd.PancakeHostSession = null;
    try expectOk(openAccepted(host, "tcp", 3, &session));
    defer _ = cd.pancake_host_session_release(session);

    var loop: ?*cdrv.PancakeDriverLoop = null;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cdrv.pancake_driver_take_host(host, &driver_options_1s, &loop),
    );
    try std.testing.expect(loop == null);
}

test "a resident cannot return a count beyond the borrowed C buffer" {
    var resident = InvalidMultiplexedResident{ .wake = try pancake.net.wake_channel.WakeChannel.open() };
    defer resident.wake.deinit();
    const owned_loop = try newLoop(0x36);
    defer owned_loop.deinit();
    const loop = owned_loop.raw;
    var table = resident.table();
    try expectOk(addMultiplexedProvider(loop, &table, "invalid-count"));
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        addMultiplexedProvider(loop, &table, "invalid-count"),
    );
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        addMultiplexedProvider(loop, &table, "tcp"),
    );

    resident.wake.nudge();
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, cdrv.pancake_driver_step(loop, 0));
    // The violation poisons the adapter: stepping it again cannot silently
    // resume calls through a table that already broke memory ownership.
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, cdrv.pancake_driver_step(loop, 0));
}

test "a dial-only resident registers without fake listener callbacks" {
    const owned_loop = try newLoop(0x47);
    defer owned_loop.deinit();
    const loop = owned_loop.raw;
    var resident = InvalidMultiplexedResident{ .wake = try pancake.net.wake_channel.WakeChannel.open() };
    defer resident.wake.deinit();
    var table = resident.table();
    table.start_listen = null;
    table.listener_locator = null;
    table.listener_advertise = null;
    table.finish_accept = null;
    table.stop_listen = null;
    try expectOk(addMultiplexedProvider(loop, &table, "invalid-count"));

    var listener: u64 = 0;
    const name = "invalid-count";
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cdrv.pancake_driver_listen(loop, name.ptr, name.len, "endpoint".ptr, "endpoint".len, &listener),
    );
}

test "resident operation groups must be complete or absent" {
    const owned_loop = try newLoop(0x48);
    defer owned_loop.deinit();
    const loop = owned_loop.raw;
    var resident = InvalidMultiplexedResident{ .wake = try pancake.net.wake_channel.WakeChannel.open() };
    defer resident.wake.deinit();
    var table = resident.table();
    table.finish_accept = null;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        addMultiplexedProvider(loop, &table, "invalid-count"),
    );
}

test "an external-claim-only resident routes adoption through the generic driver" {
    const owned_loop = try newLoop(0x49);
    defer owned_loop.deinit();
    var resident = InvalidMultiplexedResident{ .wake = try pancake.net.wake_channel.WakeChannel.open() };
    defer resident.wake.deinit();
    var table = resident.table();
    table.start_connect = null;
    table.finish_connect = null;
    table.cancel_connect = null;
    table.start_listen = null;
    table.listener_locator = null;
    table.listener_advertise = null;
    table.finish_accept = null;
    table.stop_listen = null;
    table.claim_external = InvalidMultiplexedResident.claimExternal;

    const loop = owned_loop.raw;
    try expectOk(addMultiplexedProvider(loop, &table, "external-only"));
    var present: u8 = 0;
    try expectOk(cdrv.pancake_driver_has_transport(loop, "external-only", 13, &present));
    try std.testing.expectEqual(@as(u32, 1), present);

    var ticket: u64 = 0;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cdrv.pancake_driver_adopt_external(
            loop,
            "external-only",
            13,
            7,
            cdrv.PANCAKE_DRIVER_ADOPT_DIALED,
            &ticket,
        ),
    );
    try std.testing.expectEqual(@as(u64, 0), ticket);
}

fn expectMultiplexedIoContractFailure(
    seed: u8,
    read_result: ?isize,
    write_result: ?isize,
) !void {
    const owned_loop = try newLoop(seed);
    defer owned_loop.deinit();
    var resident = InvalidMultiplexedResident{
        .wake = try pancake.net.wake_channel.WakeChannel.open(),
        .connect_io = true,
        .read_result = read_result,
        .write_result = write_result,
    };
    defer resident.wake.deinit();
    var table = resident.table();
    try expectOk(addMultiplexedProvider(owned_loop.raw, &table, "invalid-io"));

    var locator: ?*c.PancakeLocator = null;
    try expectOk(c.pancake_locator_new("invalid-io", "invalid-io".len, "endpoint", "endpoint".len, c.PANCAKE_HINTS_MAP, &locator));
    defer c.pancake_locator_release(locator);
    var locator_view: ?*const c.PancakeLocatorView = null;
    try expectOk(c.pancake_locator_borrow_view(locator, &locator_view));
    var ticket: u64 = 0;
    try expectOk(cdrv.pancake_driver_dial(owned_loop.raw, locator_view, &ticket));
    try std.testing.expectEqual(@as(u64, 1), ticket);
    var failed = false;
    for (0..2) |_| {
        const code = cdrv.pancake_driver_step(owned_loop.raw, 0);
        if (code == c.PANCAKE_ERR_INVALID_ARGUMENT) {
            failed = true;
            break;
        }
        try expectStep(code);
    }
    try std.testing.expect(failed);
}

test "multiplexed providers cannot return undocumented or oversized I/O results" {
    try expectMultiplexedIoContractFailure(0x50, -3, null);
    try expectMultiplexedIoContractFailure(0x51, std.math.maxInt(isize), null);
    try expectMultiplexedIoContractFailure(0x52, null, -3);
    try expectMultiplexedIoContractFailure(0x53, null, std.math.maxInt(isize));
}

test "the provider ABI preserves typed locators and holds one package lease" {
    const opaque_bytes = try std.testing.allocator.alloc(u8, 128 * 1024);
    defer std.testing.allocator.free(opaque_bytes);
    for (opaque_bytes, 0..) |*byte, i| byte.* = @truncate(i);

    var resident: TypedResident = .{
        .wake = try pancake.net.wake_channel.WakeChannel.open(),
        .opaque_hint = opaque_bytes,
    };
    defer resident.wake.deinit();

    const host = try newByteFedHost(0x4a);
    errdefer _ = cd.pancake_host_release(host);
    var loop: ?*cdrv.PancakeDriverLoop = null;
    try expectOk(cdrv.pancake_driver_take_host(host, &driver_options_1s, &loop));
    var loop_live = true;
    defer if (loop_live) {
        _ = cdrv.pancake_driver_release(loop);
    };

    var table = resident.table();
    const profiles = [_]cdrv.PancakeTransportProfile{
        multiplexedProfile("typed-test"),
        multiplexedProfile("typed-test-alt"),
    };
    const entries = [_]cdrv.PancakeTransportProviderEntry{
        .{
            .profile = &profiles[0],
            .execution_model = cdrv.PANCAKE_TRANSPORT_EXEC_MULTIPLEXED,
            .implementation = &table,
        },
        .{
            .profile = &profiles[1],
            .execution_model = cdrv.PANCAKE_TRANSPORT_EXEC_MULTIPLEXED,
            .implementation = &table,
        },
    };
    const provider: cdrv.PancakeTransportProvider = .{
        .abi_version = cdrv.PANCAKE_TRANSPORT_PROVIDER_ABI_VERSION,
        .struct_size = @sizeOf(cdrv.PancakeTransportProvider),
        .entries = &entries,
        .entry_count = entries.len,
        .lease_ctx = &resident,
        .retain = TypedResident.retain,
        .release = TypedResident.release,
    };
    try expectOk(cdrv.pancake_driver_add_provider(loop, &provider));
    try std.testing.expectEqual(@as(usize, 1), resident.retains);
    try std.testing.expectEqual(@as(usize, 0), resident.releases);

    var present: u8 = 0;
    try expectOk(cdrv.pancake_driver_has_transport(loop, "typed-test", "typed-test".len, &present));
    try std.testing.expectEqual(@as(u8, 1), present);
    try expectOk(cdrv.pancake_driver_has_transport(loop, "typed-test-alt", "typed-test-alt".len, &present));
    try std.testing.expectEqual(@as(u8, 1), present);
    try expectOk(cdrv.pancake_driver_has_transport(loop, "absent", "absent".len, &present));
    try std.testing.expectEqual(@as(u8, 0), present);

    var listener: u64 = 0;
    try expectOk(cdrv.pancake_driver_listen(
        loop,
        "typed-test",
        "typed-test".len,
        "listener-peer",
        "listener-peer".len,
        &listener,
    ));
    const published = try readListenerLocator(loop, listener);
    defer pancake.ocapn.model.freePeerLocator(std.testing.allocator, published);
    try std.testing.expectEqualStrings("typed-test", published.transport);
    try std.testing.expectEqualStrings("listener-peer", published.designator);
    try std.testing.expectEqual(@as(usize, 4), published.hints.entries.len);
    try std.testing.expectEqualStrings("primary", published.hints.entries[0].value.string);
    try std.testing.expectEqualSlices(u8, opaque_bytes, published.hints.entries[1].value.bytes);
    try std.testing.expect(published.hints.entries[2].value.boolean);
    try std.testing.expectEqual(@as(i64, 73), published.hints.entries[3].value.integer);

    var second_listener: u64 = 0;
    try expectOk(cdrv.pancake_driver_listen(
        loop,
        "typed-test-alt",
        "typed-test-alt".len,
        "listener-peer",
        "listener-peer".len,
        &second_listener,
    ));
    const second_published = try readListenerLocator(loop, second_listener);
    defer pancake.ocapn.model.freePeerLocator(std.testing.allocator, second_published);
    try std.testing.expectEqualStrings("typed-test-alt", second_published.transport);

    var dial_locator: ?*c.PancakeLocator = null;
    try expectOk(c.pancake_locator_new("typed-test", 10, "dial-peer", 9, c.PANCAKE_HINTS_MAP, &dial_locator));
    defer c.pancake_locator_release(dial_locator);
    try expectOk(c.pancake_locator_add_string(dial_locator, "route", 5, "alternate", 9));
    try expectOk(c.pancake_locator_add_bytes(dial_locator, "token", 5, &.{ 0, 0xff, 7 }, 3));
    try expectOk(c.pancake_locator_add_boolean(dial_locator, "enabled", 7, 1));
    try expectOk(c.pancake_locator_add_integer(dial_locator, "limit", 5, -42));
    var dial_view: ?*const c.PancakeLocatorView = null;
    try expectOk(c.pancake_locator_borrow_view(dial_locator, &dial_view));
    var ticket: u64 = 0;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cdrv.pancake_driver_dial(loop, dial_view, &ticket),
    );
    try std.testing.expectEqual(@as(u64, 0), ticket);
    try std.testing.expect(resident.dial_verified);

    try expectOk(cdrv.pancake_driver_release(loop));
    loop_live = false;
    try std.testing.expectEqual(@as(usize, 1), resident.releases);
}

test "a dial resident cannot smuggle unsupported readiness events" {
    var resident = InvalidMultiplexedResident{
        .wake = try pancake.net.wake_channel.WakeChannel.open(),
        .invalid_mask = true,
    };
    defer resident.wake.deinit();
    const owned_loop = try newLoop(0x37);
    defer owned_loop.deinit();
    const loop = owned_loop.raw;
    var table = resident.table();
    try expectOk(addMultiplexedProvider(loop, &table, "invalid-count"));
    resident.wake.nudge();
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, cdrv.pancake_driver_step(loop, 0));
}

test "a resident cannot combine connect readiness with connection events" {
    var resident = InvalidMultiplexedResident{
        .wake = try pancake.net.wake_channel.WakeChannel.open(),
        .connect_with_readable = true,
    };
    defer resident.wake.deinit();
    const owned_loop = try newLoop(0x4b);
    defer owned_loop.deinit();
    const loop = owned_loop.raw;
    var table = resident.table();
    try expectOk(addMultiplexedProvider(loop, &table, "combined-connect"));
    resident.wake.nudge();
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, cdrv.pancake_driver_step(loop, 0));
}

test "a successful multiplexed listen must return its listener handle" {
    var resident = InvalidMultiplexedResident{
        .wake = try pancake.net.wake_channel.WakeChannel.open(),
        .listen_without_handle = true,
    };
    defer resident.wake.deinit();
    const owned_loop = try newLoop(0x4c);
    defer owned_loop.deinit();
    const loop = owned_loop.raw;
    var table = resident.table();
    try expectOk(addMultiplexedProvider(loop, &table, "missing-listener"));
    var listener: u64 = 0;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cdrv.pancake_driver_listen(loop, "missing-listener", "missing-listener".len, "", 0, &listener),
    );
}

test "the TCP archive installs its complete profile package atomically" {
    const owned_loop = try newLoop(0x39);
    defer owned_loop.deinit();
    const loop = owned_loop.raw;

    var duplicate_tcp: ?*ctcp.PancakeTcpNetlayer = null;
    try expectOk(ctcp.pancake_tcp_netlayer_new(&duplicate_tcp));
    defer ctcp.pancake_tcp_netlayer_release(duplicate_tcp);
    var duplicate: cdrv.PancakeTransportProvider = undefined;
    try expectOk(ctcp.pancake_tcp_transport_provider(duplicate_tcp, &duplicate));
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cdrv.pancake_driver_add_provider(loop, &duplicate),
    );

    var plain_listener: u64 = 0;
    try expectOk(cdrv.pancake_driver_listen(loop, "tcp", 3, "127.0.0.1:0", 11, &plain_listener));
    var keyed_listener: u64 = 0;
    try expectOk(cdrv.pancake_driver_listen(loop, "keyed-tcp", 9, "127.0.0.1:0", 11, &keyed_listener));
    try std.testing.expect(keyed_listener != plain_listener);

    const keyed_locator = try readListenerLocator(loop, keyed_listener);
    defer pancake.ocapn.model.freePeerLocator(std.testing.allocator, keyed_locator);
    try std.testing.expectEqualStrings("keyed-tcp", keyed_locator.transport);
    try std.testing.expect(directAddresses(keyed_locator) != null);

    const advertised = "203.0.113.1:7447";
    try expectOk(try advertiseParts(loop, plain_listener, "tcp", advertised, ""));
    const advertised_locator = try readListenerLocator(loop, plain_listener);
    defer pancake.ocapn.model.freePeerLocator(std.testing.allocator, advertised_locator);
    try std.testing.expectEqualStrings("tcp", advertised_locator.transport);
    try std.testing.expectEqualStrings(advertised, advertised_locator.designator);
    try std.testing.expect(directAddresses(advertised_locator) == null);
    try expectOk(try advertiseParts(loop, plain_listener, "tcp", advertised, "127.0.0.1:7447"));
    const plain_with_hint = try readListenerLocator(loop, plain_listener);
    defer pancake.ocapn.model.freePeerLocator(std.testing.allocator, plain_with_hint);
    try std.testing.expectEqualStrings("127.0.0.1:7447", directAddresses(plain_with_hint).?);
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        try advertiseParts(loop, plain_listener, "tcp", "not-an-address", ""),
    );

    const wrong_key = [_]u8{'0'} ** pancake.foundation.crypto.PeerKey.designator_len;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        try advertiseParts(loop, keyed_listener, "keyed-tcp", &wrong_key, "203.0.113.2:7448"),
    );
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        try advertiseParts(loop, keyed_listener, "keyed-tcp", keyed_locator.designator, ""),
    );
    const keyed_after_refusal = try readListenerLocator(loop, keyed_listener);
    defer pancake.ocapn.model.freePeerLocator(std.testing.allocator, keyed_after_refusal);
    try std.testing.expectEqualStrings(keyed_locator.designator, keyed_after_refusal.designator);
    try std.testing.expectEqualStrings(directAddresses(keyed_locator).?, directAddresses(keyed_after_refusal).?);

    const keyed_public_address = "203.0.113.2:7448";
    try expectOk(try advertiseParts(loop, keyed_listener, "keyed-tcp", keyed_locator.designator, keyed_public_address));
    const keyed_advertised = try readListenerLocator(loop, keyed_listener);
    defer pancake.ocapn.model.freePeerLocator(std.testing.allocator, keyed_advertised);
    try std.testing.expectEqualStrings(keyed_locator.designator, keyed_advertised.designator);
    try std.testing.expectEqualStrings(keyed_public_address, directAddresses(keyed_advertised).?);

    var duplicate_listener: u64 = 0;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cdrv.pancake_driver_listen(loop, "tcp", 3, "127.0.0.1:0", 11, &duplicate_listener),
    );

    try expectOk(cdrv.pancake_driver_listener_select(loop, plain_listener));
    try expectOk(cdrv.pancake_driver_listener_close(loop, plain_listener));
    var closed_locator: cdrv.PancakeLocatorView = undefined;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_NOT_FOUND,
        cdrv.pancake_driver_listener_locator(loop, plain_listener, &closed_locator),
    );
    try std.testing.expectEqual(
        c.PANCAKE_ERR_NOT_FOUND,
        cdrv.pancake_driver_listener_select(loop, plain_listener),
    );
    try std.testing.expectEqual(
        c.PANCAKE_ERR_NOT_FOUND,
        cdrv.pancake_driver_listener_close(loop, plain_listener),
    );

    var replacement_listener: u64 = 0;
    try expectOk(cdrv.pancake_driver_listen(loop, "tcp", 3, "127.0.0.1:0", 11, &replacement_listener));
    try std.testing.expect(replacement_listener != plain_listener);
    try expectOk(cdrv.pancake_driver_listener_select(loop, keyed_listener));
}

test "the relay archive owns clear and sealed rendezvous profiles as one package" {
    const relay_url = "ws://127.0.0.1:1/relay";
    const register_url = "ws://127.0.0.1:1/register";
    const config: crelay.PancakeRelayConfig = .{
        .relay_url = relay_url.ptr,
        .relay_url_len = relay_url.len,
        .register_url = register_url.ptr,
        .register_url_len = register_url.len,
    };
    var runtime: ?*crelay.PancakeRelayRuntime = null;
    try expectOk(crelay.pancake_relay_runtime_new(&config, &runtime));
    defer crelay.pancake_relay_runtime_release(runtime);

    var package: cdrv.PancakeTransportProvider = undefined;
    try expectOk(crelay.pancake_relay_transport_provider(runtime, &package));
    try std.testing.expectEqual(@as(usize, 2), package.entry_count);
    const entries = package.entries.?[0..package.entry_count];
    try std.testing.expectEqual(cdrv.PANCAKE_TRANSPORT_EXEC_MULTIPLEXED, entries[0].execution_model);
    try std.testing.expectEqual(cdrv.PANCAKE_TRANSPORT_EXEC_MULTIPLEXED, entries[1].execution_model);
    try std.testing.expectEqualStrings(
        "keyed-relay",
        entries[0].profile.?.transport_name.?[0..entries[0].profile.?.transport_name_len],
    );
    try std.testing.expectEqualStrings(
        "noise-relay",
        entries[1].profile.?.transport_name.?[0..entries[1].profile.?.transport_name_len],
    );
    try std.testing.expectEqual(cdrv.PANCAKE_SEALED_CHANNEL_NONE, entries[0].profile.?.sealed_channel);
    try std.testing.expectEqual(cdrv.PANCAKE_SEALED_CHANNEL_NOISE_XK, entries[1].profile.?.sealed_channel);

    const owned_loop = try newLoop(0x3f);
    defer owned_loop.deinit();
    try expectOk(cdrv.pancake_driver_add_provider(owned_loop.raw, &package));
}

test "listener close cancels a connection still in the accepted handshake" {
    const owned_server = try newLoop(0x3a);
    defer owned_server.deinit();
    const server = owned_server.raw;
    var listener: u64 = 0;
    try expectOk(cdrv.pancake_driver_listen(server, "tcp", 3, "127.0.0.1:0", 11, &listener));
    try expectOk(cdrv.pancake_driver_listener_select(server, listener));
    const locator = try readListenerLocator(server, listener);
    defer pancake.ocapn.model.freePeerLocator(std.testing.allocator, locator);

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const address = try pancake.net.tcp.parseDesignator(locator.designator);
    var silent = try std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream });
    defer silent.close(io);

    // Accept the socket and stage its CapTP handshake, but send no hello.
    try expectLoopReadable(server);
    try expectStep(cdrv.pancake_driver_step(server, 0));
    try expectOk(cdrv.pancake_driver_listener_close(server, listener));

    var seen = Drained{};
    try drainEvents(server, &seen);
    try std.testing.expect(!seen.accepted);
    // Later steps cannot resurrect the canceled accept under the retired id.
    try expectStep(cdrv.pancake_driver_step(server, 0));
    try drainEvents(server, &seen);
    try std.testing.expect(!seen.accepted);
}

test "an unselected listener refuses accept visibly until routing policy is selected" {
    const owned_server = try newLoop(0x3d);
    defer owned_server.deinit();
    const server = owned_server.raw;
    var listener: u64 = 0;
    try expectOk(cdrv.pancake_driver_listen(server, "tcp", 3, "127.0.0.1:0", 11, &listener));
    const locator = try readListenerLocator(server, listener);
    defer pancake.ocapn.model.freePeerLocator(std.testing.allocator, locator);

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const address = try pancake.net.tcp.parseDesignator(locator.designator);
    var silent = try std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream });
    defer silent.close(io);

    try expectLoopReadable(server);
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cdrv.pancake_driver_step(server, 0),
    );
    var message: [128]u8 = undefined;
    const message_len = cdrv.pancake_driver_last_error(&message, message.len);
    try std.testing.expect(std.mem.indexOf(u8, message[0..message_len], "MissingAdvertisedLocator") != null);

    try expectOk(cdrv.pancake_driver_listener_select(server, listener));
    try expectStep(cdrv.pancake_driver_step(server, 0));
    try expectOk(cdrv.pancake_driver_listener_close(server, listener));
}

test "listener close preserves an ACCEPTED event committed by an earlier step" {
    const owned_server = try newLoop(0x3b);
    defer owned_server.deinit();
    const server = owned_server.raw;
    var listener: u64 = 0;
    try expectOk(cdrv.pancake_driver_listen(server, "tcp", 3, "127.0.0.1:0", 11, &listener));
    try expectOk(cdrv.pancake_driver_listener_select(server, listener));
    const locator = try readListenerLocator(server, listener);
    defer pancake.ocapn.model.freePeerLocator(std.testing.allocator, locator);

    const owned_client = try newLoop(0x3c);
    defer owned_client.deinit();
    const client = owned_client.raw;
    var ticket: u64 = 0;
    try expectOk(try dialParts(client, "tcp", locator.designator, "", &ticket));

    var client_seen = Drained{};
    var rounds: usize = 0;
    while (client_seen.dialed_session == null and rounds < 2_000) : (rounds += 1) {
        try expectStep(cdrv.pancake_driver_step(client, 5));
        try drainEvents(client, &client_seen);
        // Deliberately do not drain the server: ACCEPTED must remain native-
        // owned across listener close once the handshake commits it.
        try expectStep(cdrv.pancake_driver_step(server, 5));
    }
    try std.testing.expect(client_seen.dialed_session != null);

    try expectOk(cdrv.pancake_driver_listener_close(server, listener));
    var server_seen = Drained{};
    try drainEvents(server, &server_seen);
    try std.testing.expect(server_seen.accepted_session != null);
    try std.testing.expectEqual(listener, server_seen.accepted_listener);

    try expectOk(cdrv.pancake_driver_session_release(client, client_seen.dialed_session));
    try expectOk(cdrv.pancake_driver_session_release(server, server_seen.accepted_session));
}

/// The server embedder's whole life, shared with the test thread through
/// atomics and one write-once designator buffer.
const ServerShared = struct {
    designator_buf: [128]u8 = undefined,
    designator_len: usize = 0,
    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    accepted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn serverMain(shared: *ServerShared) void {
    serverBody(shared) catch shared.failed.store(true, .release);
}

fn serverBody(shared: *ServerShared) !void {
    const owned_loop = try newLoop(0x11);
    defer owned_loop.deinit();
    const loop = owned_loop.raw;

    var listener_id: u64 = 0;
    try expectOk(cdrv.pancake_driver_listen(loop, "tcp", 3, "127.0.0.1:0", 11, &listener_id));
    try expectOk(cdrv.pancake_driver_listener_select(loop, listener_id));
    // A duplicate transport is refused because the Host has one advertised
    // locator per transport.
    var duplicate_listener: u64 = 0;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cdrv.pancake_driver_listen(loop, "tcp", 3, "127.0.0.1:0", 11, &duplicate_listener),
    );
    var readiness: i32 = -1;
    try expectOk(cdrv.pancake_driver_readiness_fd(loop, &readiness));
    try std.testing.expect(readiness >= 0);

    try expectOk(cd.pancake_host_publish(owned_loop.host, "widget", 6, widgetBehavior, null, null));

    const locator = try readListenerLocator(loop, listener_id);
    defer pancake.ocapn.model.freePeerLocator(std.testing.allocator, locator);
    shared.designator_len = locator.designator.len;
    @memcpy(shared.designator_buf[0..shared.designator_len], locator.designator);
    shared.ready.store(true, .release);

    var seen = Drained{};
    while (!shared.stop.load(.acquire)) {
        try expectStep(cdrv.pancake_driver_step(loop, 20));
        try drainEvents(loop, &seen);
        if (seen.accepted) shared.accepted.store(true, .release);
        if (seen.closed) shared.closed.store(true, .release);
    }

    // Drained queues report WOULD_BLOCK, so an embedder's drain loop ends.
    var event: cdrv.PancakeDriverEvent = undefined;
    try std.testing.expectEqual(c.PANCAKE_ERR_WOULD_BLOCK, cdrv.pancake_driver_next_event(loop, &event));
}

test "two stepping loops carry listen, dial, fetch, settle, and hangup over loopback TCP (ADR-0112)" {
    var shared = ServerShared{};
    const server_thread = try std.Thread.spawn(.{}, serverMain, .{&shared});
    var joined = false;
    defer if (!joined) {
        shared.stop.store(true, .release);
        server_thread.join();
    };

    var spins: usize = 0;
    while (!shared.ready.load(.acquire) and !shared.failed.load(.acquire) and spins < 1_000_000) : (spins += 1) {
        std.Thread.yield() catch {};
    }
    try std.testing.expect(shared.ready.load(.acquire));
    const designator = shared.designator_buf[0..shared.designator_len];

    const owned_client = try newLoop(0x22);
    defer owned_client.deinit();
    const client = owned_client.raw;

    var ticket: u64 = 0;
    try expectOk(try dialParts(client, "tcp", designator, "", &ticket));

    var client_seen = Drained{};
    var fetch_vow: u64 = 0;
    var rounds: usize = 0;
    while (client_seen.settle_ticket == 0 and rounds < 2000) : (rounds += 1) {
        try expectStep(cdrv.pancake_driver_step(client, 5));
        try drainEvents(client, &client_seen);
        if (client_seen.dialed_session != null and fetch_vow == 0) {
            try std.testing.expectEqual(ticket, client_seen.dialed_ticket);
            try expectOk(cd.pancake_host_session_fetch(client_seen.dialed_session, "widget", 6, &fetch_vow));
        }
        try std.testing.expect(!client_seen.dial_failed);
        try std.testing.expectEqual(@as(u64, 0), client_seen.fail_ticket);
    }

    // The dial opened, and the fetch's unobserved settle arrived as a
    // COMPLETION event carrying the fetch's own vow id.
    try std.testing.expect(client_seen.dialed_session != null);
    try std.testing.expect(fetch_vow != 0);
    try std.testing.expectEqual(fetch_vow, client_seen.settle_ticket);

    // Hang up from the client; the server's stepping thread observes the EOF
    // and events the closure without any blocking verb running.
    try expectOk(cdrv.pancake_driver_session_release(client, client_seen.dialed_session));
    var waited: usize = 0;
    while (!shared.closed.load(.acquire) and !shared.failed.load(.acquire) and waited < 2000) : (waited += 1) {
        try expectStep(cdrv.pancake_driver_step(client, 5));
    }

    shared.stop.store(true, .release);
    server_thread.join();
    joined = true;
    try std.testing.expect(!shared.failed.load(.acquire));
    try std.testing.expect(shared.accepted.load(.acquire));
    try std.testing.expect(shared.closed.load(.acquire));

    // The client's queue is drained too, so the borrow contract's "next call
    // frees the last event" leaves nothing behind at release.
    var event: cdrv.PancakeDriverEvent = undefined;
    try std.testing.expectEqual(c.PANCAKE_ERR_WOULD_BLOCK, cdrv.pancake_driver_next_event(client, &event));
}

test "two loops stepped by one thread dial each other: the nonblocking handshake advances across steps (ADR-0112)" {
    const owned_server = try newLoop(0x44);
    defer owned_server.deinit();
    const server = owned_server.raw;
    var listener_id: u64 = 0;
    try expectOk(cdrv.pancake_driver_listen(server, "tcp", 3, "127.0.0.1:0", 11, &listener_id));
    try expectOk(cdrv.pancake_driver_listener_select(server, listener_id));
    try expectOk(cd.pancake_host_publish(owned_server.host, "widget", 6, widgetBehavior, null, null));
    const locator = try readListenerLocator(server, listener_id);
    defer pancake.ocapn.model.freePeerLocator(std.testing.allocator, locator);
    const designator = locator.designator;

    // A blocking dial could never complete here: the exporter's loop steps on
    // this same thread, so the handshake must advance across alternating
    // steps or time out.
    const owned_client = try newLoop(0x45);
    defer owned_client.deinit();
    const client = owned_client.raw;
    var ticket: u64 = 0;
    try expectOk(try dialParts(client, "tcp", designator, "", &ticket));

    var client_seen = Drained{};
    var server_seen = Drained{};
    var fetch_vow: u64 = 0;
    var rounds: usize = 0;
    while (client_seen.settle_ticket == 0 and rounds < 2_000) : (rounds += 1) {
        try expectStep(cdrv.pancake_driver_step(client, 5));
        try drainEvents(client, &client_seen);
        try expectStep(cdrv.pancake_driver_step(server, 5));
        try drainEvents(server, &server_seen);
        if (client_seen.dialed_session != null and
            server_seen.accepted_session != null and
            fetch_vow == 0)
        {
            // Opaque session handles are scoped to the loop that minted them.
            // The peer ids happen to match in this two-loop setup, so checking
            // ownership after a wire lookup would close the server's session.
            try std.testing.expectEqual(
                c.PANCAKE_ERR_INVALID_ARGUMENT,
                cdrv.pancake_driver_session_release(server, client_seen.dialed_session),
            );
            try std.testing.expectEqual(ticket, client_seen.dialed_ticket);
            try expectOk(cd.pancake_host_session_fetch(client_seen.dialed_session, "widget", 6, &fetch_vow));
        }
        try std.testing.expect(!client_seen.dial_failed);
        try std.testing.expectEqual(@as(u64, 0), client_seen.fail_ticket);
    }
    try std.testing.expect(client_seen.dialed_session != null);
    try std.testing.expect(server_seen.accepted);
    try std.testing.expect(fetch_vow != 0);
    try std.testing.expectEqual(fetch_vow, client_seen.settle_ticket);
    try expectOk(cdrv.pancake_driver_session_release(client, client_seen.dialed_session));

    // EOF commits one SESSION_CLOSED event. While it is pending, another step
    // reports backpressure without advancing more work. Releasing the session
    // invalidates the event in O(1); the drain skips it without touching the
    // freed shell.
    try expectLoopReadable(server);
    try expectOk(cdrv.pancake_driver_step(server, 0));
    try expectOk(cdrv.pancake_driver_step(server, 0));
    try expectOk(cdrv.pancake_driver_session_release(server, server_seen.accepted_session));
    var stale_event: cdrv.PancakeDriverEvent = undefined;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_WOULD_BLOCK,
        cdrv.pancake_driver_next_event(server, &stale_event),
    );
}

test "keyed-tcp is available at loop construction and retains unauthenticated provenance" {
    const owned_server = try newLoop(0x48);
    defer owned_server.deinit();
    const server = owned_server.raw;

    var listener_id: u64 = 0;
    try expectOk(cdrv.pancake_driver_listen(server, "keyed-tcp", 9, "127.0.0.1:0", 11, &listener_id));
    try expectOk(cdrv.pancake_driver_listener_select(server, listener_id));
    const locator = try readListenerLocator(server, listener_id);
    defer pancake.ocapn.model.freePeerLocator(std.testing.allocator, locator);
    try std.testing.expectEqual(@as(usize, 64), locator.designator.len);
    const direct = directAddresses(locator) orelse return error.MissingDirectAddresses;
    try std.testing.expect(direct.len != 0);

    const owned_client = try newLoop(0x49);
    defer owned_client.deinit();
    const client = owned_client.raw;
    var ticket: u64 = 0;
    try expectOk(try dialParts(client, "keyed-tcp", locator.designator, direct, &ticket));
    try expectStep(cdrv.pancake_driver_step(client, 0));
    try expectLoopReadable(server);

    var client_seen = Drained{};
    var server_seen = Drained{};
    var rounds: usize = 0;
    while (client_seen.dialed_session == null and rounds < 2_000) : (rounds += 1) {
        try expectStep(cdrv.pancake_driver_step(client, 5));
        try drainEvents(client, &client_seen);
        try expectStep(cdrv.pancake_driver_step(server, 5));
        try drainEvents(server, &server_seen);
        try std.testing.expect(!client_seen.dial_failed);
    }
    try std.testing.expect(client_seen.dialed_session != null);
    try std.testing.expect(server_seen.accepted_session != null);
    var client_identity = std.mem.zeroes(cd.PancakePartnerIdentity);
    try expectOk(cd.pancake_host_session_partner_identity(client_seen.dialed_session, &client_identity));
    try std.testing.expectEqual(cd.PANCAKE_DURABLE_PROVENANCE_UNAUTHENTICATED, client_identity.provenance);
    var server_identity = std.mem.zeroes(cd.PancakePartnerIdentity);
    try expectOk(cd.pancake_host_session_partner_identity(server_seen.accepted_session, &server_identity));
    try std.testing.expectEqual(cd.PANCAKE_DURABLE_PROVENANCE_UNAUTHENTICATED, server_identity.provenance);
    try expectOk(cdrv.pancake_driver_session_release(client, client_seen.dialed_session));
    try expectOk(cdrv.pancake_driver_session_release(server, server_seen.accepted_session));
}

test "noise-tcp is available at loop construction with a dialable locator and authenticated sessions" {
    const owned_server = try newLoop(0x46);
    defer owned_server.deinit();
    const server = owned_server.raw;

    var listener_id: u64 = 0;
    try expectOk(cdrv.pancake_driver_listen(server, "noise-tcp", 9, "127.0.0.1:0", 11, &listener_id));
    try expectOk(cdrv.pancake_driver_listener_select(server, listener_id));
    try expectOk(cd.pancake_host_publish(owned_server.host, "widget", 6, widgetBehavior, null, null));

    const locator = try readListenerLocator(server, listener_id);
    defer pancake.ocapn.model.freePeerLocator(std.testing.allocator, locator);
    try std.testing.expectEqual(@as(usize, 64), locator.designator.len);
    const direct = directAddresses(locator) orelse return error.MissingDirectAddresses;
    try std.testing.expect(direct.len != 0);

    const owned_client = try newLoop(0x47);
    defer owned_client.deinit();
    const client = owned_client.raw;
    var ticket: u64 = 0;
    try expectOk(try dialParts(client, "noise-tcp", locator.designator, direct, &ticket));
    try expectStep(cdrv.pancake_driver_step(client, 0));
    try expectLoopReadable(server);

    var client_seen = Drained{};
    var server_seen = Drained{};
    var fetch_vow: u64 = 0;
    var rounds: usize = 0;
    while (client_seen.settle_ticket == 0 and rounds < 2_000) : (rounds += 1) {
        try expectStep(cdrv.pancake_driver_step(client, 5));
        try drainEvents(client, &client_seen);
        try expectStep(cdrv.pancake_driver_step(server, 5));
        try drainEvents(server, &server_seen);
        if (client_seen.dialed_session != null and
            server_seen.accepted_session != null and
            fetch_vow == 0)
        {
            var client_identity = std.mem.zeroes(cd.PancakePartnerIdentity);
            try expectOk(cd.pancake_host_session_partner_identity(client_seen.dialed_session, &client_identity));
            try std.testing.expectEqual(
                cd.PANCAKE_DURABLE_PROVENANCE_AUTHENTICATED_TRANSPORT,
                client_identity.provenance,
            );
            var server_identity = std.mem.zeroes(cd.PancakePartnerIdentity);
            try expectOk(cd.pancake_host_session_partner_identity(server_seen.accepted_session, &server_identity));
            try std.testing.expectEqual(
                cd.PANCAKE_DURABLE_PROVENANCE_AUTHENTICATED_TRANSPORT,
                server_identity.provenance,
            );
            try std.testing.expectEqual(ticket, client_seen.dialed_ticket);
            try expectOk(cd.pancake_host_session_fetch(client_seen.dialed_session, "widget", 6, &fetch_vow));
        }
        try std.testing.expect(!client_seen.dial_failed);
        try std.testing.expectEqual(@as(u64, 0), client_seen.fail_ticket);
    }
    try std.testing.expect(client_seen.dialed_session != null);
    try std.testing.expect(server_seen.accepted_session != null);
    try std.testing.expect(fetch_vow != 0);
    try std.testing.expectEqual(fetch_vow, client_seen.settle_ticket);
    try expectOk(cdrv.pancake_driver_session_release(client, client_seen.dialed_session));
    try expectOk(cdrv.pancake_driver_session_release(server, server_seen.accepted_session));
}

test "the relay provider registers and dials an authenticated noise-relay session through the C driver" {
    if (!(@import("builtin").os.tag == .linux or @import("builtin").os.tag.isDarwin()))
        return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const relay_addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var relay_server = try std.Io.net.IpAddress.listen(&relay_addr, io, .{ .reuse_address = true });
    defer relay_server.deinit(io);
    const port = relay_server.socket.address.getPort();
    var relay_url_buf: [64]u8 = undefined;
    const relay_url = try std.fmt.bufPrint(&relay_url_buf, "ws://127.0.0.1:{d}/relay", .{port});
    var register_url_buf: [64]u8 = undefined;
    const register_url = try std.fmt.bufPrint(&register_url_buf, "ws://127.0.0.1:{d}/register", .{port});
    var relay = try io.concurrent(ws_relay.bridgeOneRendezvous, .{ io, &relay_server, allocator });
    defer _ = relay.cancel(io) catch {};

    {
        const owned_server = try newLoop(0x5a);
        defer owned_server.deinit();
        try installRelay(owned_server.raw, relay_url, register_url);
        var listener_id: u64 = 0;
        try expectOk(cdrv.pancake_driver_listen(
            owned_server.raw,
            "noise-relay",
            "noise-relay".len,
            "",
            0,
            &listener_id,
        ));
        try expectOk(cdrv.pancake_driver_listener_select(owned_server.raw, listener_id));
        try expectOk(cd.pancake_host_publish(owned_server.host, "widget", 6, widgetBehavior, null, null));
        const locator = try readListenerLocator(owned_server.raw, listener_id);
        defer pancake.ocapn.model.freePeerLocator(allocator, locator);
        try std.testing.expectEqualStrings("noise-relay", locator.transport);
        try std.testing.expectEqual(@as(usize, pancake.foundation.crypto.PeerKey.designator_len), locator.designator.len);

        const owned_client = try newLoop(0x5b);
        defer owned_client.deinit();
        // The provider default is deliberately unreachable. The complete
        // listener locator must carry the actual rendezvous route into the
        // multiplexed provider; reconstructing only transport + designator would
        // fail this dial.
        const unavailable_default = "ws://127.0.0.1:1/relay";
        try installRelay(owned_client.raw, unavailable_default, "");
        var ticket: u64 = 0;
        try expectOk(try dialLocator(owned_client.raw, locator, &ticket));

        var client_seen = Drained{};
        var server_seen = Drained{};
        var fetch_vow: u64 = 0;
        var rounds: usize = 0;
        while (client_seen.settle_ticket == 0 and rounds < 2_000) : (rounds += 1) {
            try expectStep(cdrv.pancake_driver_step(owned_client.raw, 5));
            try drainEvents(owned_client.raw, &client_seen);
            try expectStep(cdrv.pancake_driver_step(owned_server.raw, 5));
            try drainEvents(owned_server.raw, &server_seen);
            if (client_seen.dialed_session != null and
                server_seen.accepted_session != null and
                fetch_vow == 0)
            {
                var client_identity = std.mem.zeroes(cd.PancakePartnerIdentity);
                try expectOk(cd.pancake_host_session_partner_identity(client_seen.dialed_session, &client_identity));
                try std.testing.expectEqual(
                    cd.PANCAKE_DURABLE_PROVENANCE_AUTHENTICATED_TRANSPORT,
                    client_identity.provenance,
                );
                var server_identity = std.mem.zeroes(cd.PancakePartnerIdentity);
                try expectOk(cd.pancake_host_session_partner_identity(server_seen.accepted_session, &server_identity));
                try std.testing.expectEqual(
                    cd.PANCAKE_DURABLE_PROVENANCE_AUTHENTICATED_TRANSPORT,
                    server_identity.provenance,
                );
                try expectOk(cd.pancake_host_session_fetch(client_seen.dialed_session, "widget", 6, &fetch_vow));
            }
            try std.testing.expect(!client_seen.dial_failed);
            try std.testing.expectEqual(@as(u64, 0), client_seen.fail_ticket);
        }
        try std.testing.expect(client_seen.dialed_session != null);
        try std.testing.expect(server_seen.accepted_session != null);
        try std.testing.expect(fetch_vow != 0);
        try std.testing.expectEqual(fetch_vow, client_seen.settle_ticket);
        try expectOk(cdrv.pancake_driver_session_release(owned_client.raw, client_seen.dialed_session));
        try expectOk(cdrv.pancake_driver_session_release(owned_server.raw, server_seen.accepted_session));
    }
    try relay.await(io);
}

fn stepAFewTimes(loop: ?*cdrv.PancakeDriverLoop, failed: *std.atomic.Value(bool)) void {
    for (0..3) |_| {
        const rc = cdrv.pancake_driver_step(loop, 0);
        if (rc != c.PANCAKE_OK and rc != c.PANCAKE_ERR_WOULD_BLOCK) {
            failed.store(true, .release);
            return;
        }
    }
    // Hand the claim back, so the test thread's release may take it.
    if (cdrv.pancake_driver_detach_thread(loop) != c.PANCAKE_OK) failed.store(true, .release);
}

test "detach_thread hands a set-up loop between threads at quiescent boundaries (ADR-0112)" {
    const owned_loop = try newLoop(0x33);
    defer owned_loop.deinit();
    const loop = owned_loop.raw;
    // `publish` claims the host for this thread; the detach below is the
    // quiescent handover that lets the worker's first step re-claim it (in a
    // safe build, stepping without it aborts on the affinity assert).
    try expectOk(cd.pancake_host_publish(owned_loop.host, "widget", 6, widgetBehavior, null, null));
    try expectOk(cdrv.pancake_driver_detach_thread(loop));

    var failed = std.atomic.Value(bool).init(false);
    const worker = try std.Thread.spawn(.{}, stepAFewTimes, .{ loop, &failed });
    worker.join();
    try std.testing.expect(!failed.load(.acquire));
}

test "a loop built over a counting context releases every byte it took" {
    var counting = @import("../support/c_abi_counting_alloc.zig").CountingHost{};
    const spec = counting.spec();
    var ctx: ?*c.PancakeContext = null;
    try expectOk(c.pancake_context_new_with_allocator(&spec, &ctx));

    const seed = hostSeed(0x35);
    var host: ?*cd.PancakeHost = null;
    try expectOk(cd.pancake_host_new_in(
        ctx,
        &seed,
        seed.len,
        frame_cap,
        1,
        c.PANCAKE_CODEC_SYRUP,
        c.PANCAKE_CAPTP_V1_0,
        c.PANCAKE_FEATURE_FULL,
        0,
        &host,
    ));
    errdefer _ = cd.pancake_host_release(host);
    var loop: ?*cdrv.PancakeDriverLoop = null;
    try expectOk(cdrv.pancake_driver_take_host(host, &driver_options_1s, &loop));
    try installTcp(loop);
    // An in-flight dial and a live listener both belong to loop release.
    var ticket: u64 = 0;
    try expectOk(try dialParts(loop, "tcp", "127.0.0.1:1", "127.0.0.1:1", &ticket));
    var listener_id: u64 = 0;
    try expectOk(cdrv.pancake_driver_listen(loop, "tcp", 3, "127.0.0.1:0", 11, &listener_id));
    try expectOk(cdrv.pancake_driver_release(loop));

    c.pancake_context_release(ctx);
    try std.testing.expect(counting.balanced());
}

test "pending-open admission is bounded and failure publishes from reserved capacity" {
    var counting = @import("../support/c_abi_counting_alloc.zig").CountingHost{};
    const spec = counting.spec();
    var ctx: ?*c.PancakeContext = null;
    try expectOk(c.pancake_context_new_with_allocator(&spec, &ctx));

    const seed = hostSeed(0x38);
    var host: ?*cd.PancakeHost = null;
    try expectOk(cd.pancake_host_new_in(
        ctx,
        &seed,
        seed.len,
        frame_cap,
        1,
        c.PANCAKE_CODEC_SYRUP,
        c.PANCAKE_CAPTP_V1_0,
        c.PANCAKE_FEATURE_FULL,
        0,
        &host,
    ));
    errdefer _ = cd.pancake_host_release(host);
    var loop: ?*cdrv.PancakeDriverLoop = null;
    try expectOk(cdrv.pancake_driver_take_host(host, &driver_options_cap1, &loop));

    var resident = AsyncFailureResident{ .wake = try pancake.net.wake_channel.WakeChannel.open() };
    defer resident.wake.deinit();
    var table = resident.table();
    try expectOk(addMultiplexedProvider(loop, &table, "async-fail"));
    try expectStep(cdrv.pancake_driver_step(loop, 0)); // Warm poll scratch.
    var ticket: u64 = 0;
    try expectOk(try dialParts(loop, "async-fail", "target", "", &ticket));
    var refused_ticket: u64 = 99;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_WOULD_BLOCK,
        try dialParts(loop, "async-fail", "other", "", &refused_ticket),
    );
    try std.testing.expectEqual(@as(u64, 99), refused_ticket);
    counting.fail_allocations = true;
    const step_rc = cdrv.pancake_driver_step(loop, 10);
    counting.fail_allocations = false;
    try expectOk(step_rc);

    var event: cdrv.PancakeDriverEvent = undefined;
    try expectOk(cdrv.pancake_driver_next_event(loop, &event));
    try std.testing.expectEqual(cdrv.PANCAKE_DRIVER_EVENT_OPEN_FAILED, event.kind);
    try std.testing.expectEqual(ticket, event.ticket);
    try std.testing.expectEqualStrings("ConnectionLost", event.message.?[0..event.message_len]);
    try std.testing.expectEqual(
        c.PANCAKE_ERR_WOULD_BLOCK,
        cdrv.pancake_driver_next_event(loop, &event),
    );
    var retry_ticket: u64 = 0;
    try expectOk(try dialParts(loop, "async-fail", "retry", "", &retry_ticket));
    try expectOk(cdrv.pancake_driver_release(loop));
    c.pancake_context_release(ctx);
    try std.testing.expect(counting.balanced());
}
