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

fn noStreamConnectionFailure(_: ?*anyopaque, _: ?*anyopaque, out: ?*cdrv.PancakeProviderFailure) callconv(.c) void {
    if (out) |slot| slot.* = std.mem.zeroes(cdrv.PancakeProviderFailure);
}

fn noMultiplexedConnectionFailure(_: ?*anyopaque, _: u64, out: ?*cdrv.PancakeProviderFailure) callconv(.c) void {
    if (out) |slot| slot.* = std.mem.zeroes(cdrv.PancakeProviderFailure);
}

fn injectedStreamConnectionFailure(_: ?*anyopaque, _: ?*anyopaque, out: ?*cdrv.PancakeProviderFailure) callconv(.c) void {
    const slot = out orelse return;
    const primary = "InjectedStreamReadFailure";
    const secondary = "InjectedStreamCleanupFailure";
    slot.* = std.mem.zeroes(cdrv.PancakeProviderFailure);
    slot.result = c.PANCAKE_ERR_IO;
    slot.primary_name = primary.ptr;
    slot.primary_name_len = primary.len;
    slot.secondary_result = c.PANCAKE_ERR_INTERNAL;
    slot.secondary_name = secondary.ptr;
    slot.secondary_name_len = secondary.len;
    slot.secondary_count = 2;
}

fn injectedMultiplexedConnectionFailure(_: ?*anyopaque, _: u64, out: ?*cdrv.PancakeProviderFailure) callconv(.c) void {
    const slot = out orelse return;
    const primary = "InjectedMultiplexedReadFailure";
    const secondary = "InjectedMultiplexedCleanupFailure";
    slot.* = std.mem.zeroes(cdrv.PancakeProviderFailure);
    slot.result = c.PANCAKE_ERR_IO;
    slot.primary_name = primary.ptr;
    slot.primary_name_len = primary.len;
    slot.secondary_result = c.PANCAKE_ERR_INTERNAL;
    slot.secondary_name = secondary.ptr;
    slot.secondary_name_len = secondary.len;
    slot.secondary_count = 2;
}
const pancake = @import("pancake");

const frame_cap: usize = 4096;
const default_tcp_config: ctcp.PancakeTcpConfig = .{ .stream = .{
    .keepalive_idle_sec = 0,
    .keepalive_interval_sec = 0,
    .keepalive_count = 0,
} };
const driver_options_1s: cdrv.PancakeDriverOptions = .{
    .abi_version = cdrv.PANCAKE_DRIVER_OPTIONS_ABI_VERSION,
    .struct_size = @sizeOf(cdrv.PancakeDriverOptions),
    .wire_buffer_bytes = 1024,
    .max_pending_opens = 256,
    .handshake_ms = 1_000,
    .listener_setup_ms = 1_000,
    .settle_ms = 1_000,
};

test "driver C events preserve the first consequence and total count" {
    var failure = pancake.driver.OperationFailure.fromError(error.ConnectionLost);
    failure.note(error.CloseTimedOut);
    failure.note(error.OutOfMemory);
    var event = std.mem.zeroes(cdrv.PancakeDriverEvent);
    cdrv.FailureProjection.init(failure).project(&event);
    try std.testing.expectEqual(c.PANCAKE_ERR_IO, event.primary_result);
    try std.testing.expectEqual(c.PANCAKE_ERR_TIMEOUT, event.secondary_result);
    try std.testing.expectEqual(@as(u32, 2), event.secondary_count);
    try std.testing.expectEqualStrings("ConnectionLost", event.primary_name.?[0..event.primary_name_len]);
    try std.testing.expectEqualStrings("CloseTimedOut", event.secondary_name.?[0..event.secondary_name_len]);
}
const driver_options_10s: cdrv.PancakeDriverOptions = .{
    .abi_version = cdrv.PANCAKE_DRIVER_OPTIONS_ABI_VERSION,
    .struct_size = @sizeOf(cdrv.PancakeDriverOptions),
    .wire_buffer_bytes = 1024,
    .max_pending_opens = 256,
    .handshake_ms = 10_000,
    .listener_setup_ms = 10_000,
    .settle_ms = 10_000,
};
const driver_options_cap1: cdrv.PancakeDriverOptions = .{
    .abi_version = cdrv.PANCAKE_DRIVER_OPTIONS_ABI_VERSION,
    .struct_size = @sizeOf(cdrv.PancakeDriverOptions),
    .wire_buffer_bytes = 1024,
    .max_pending_opens = 1,
    .handshake_ms = 1_000,
    .listener_setup_ms = 1_000,
    .settle_ms = 1_000,
};
const close_cancel: cdrv.PancakeCloseOptions = .{
    .abi_version = cdrv.PANCAKE_CLOSE_OPTIONS_ABI_VERSION,
    .struct_size = @sizeOf(cdrv.PancakeCloseOptions),
    .pending = cd.PANCAKE_PENDING_CANCEL,
    .grace_mode = cdrv.PANCAKE_CLOSE_GRACE_UNSPECIFIED,
    .grace_ms = 0,
};

fn providerFailure(out: ?*cdrv.PancakeProviderFailure, code: i32, primary: []const u8) i32 {
    const report = out orelse return code;
    report.* = cshared.transport_provider.emptyProviderFailure();
    report.result = code;
    report.primary_name = primary.ptr;
    report.primary_name_len = primary.len;
    return code;
}

fn drained(out_count: ?*usize, count: usize) i32 {
    out_count.?.* = count;
    return c.PANCAKE_OK;
}

fn expectOk(rc: i32) !void {
    try std.testing.expectEqual(c.PANCAKE_OK, rc);
}

fn expectStep(rc: i32) !void {
    try std.testing.expect(rc == c.PANCAKE_OK or rc == c.PANCAKE_ERR_WOULD_BLOCK);
}

fn retainStaticProvider(_: ?*anyopaque, _: ?*cdrv.PancakeProviderFailure) callconv(.c) i32 {
    return c.PANCAKE_OK;
}

fn releaseStaticProvider(_: ?*anyopaque, _: ?*cdrv.PancakeProviderFailure) callconv(.c) i32 {
    return c.PANCAKE_OK;
}

fn sameStaticProvider(ctx: ?*anyopaque, other_ctx: ?*anyopaque) callconv(.c) u8 {
    return @intFromBool(ctx == other_ctx);
}

fn providerProfile(name: []const u8) cdrv.PancakeTransportProfile {
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
        .lease_ctx = @constCast(resident),
        .same_configuration = sameStaticProvider,
        .retain = retainStaticProvider,
        .release = releaseStaticProvider,
    };
    return cdrv.pancake_driver_add_provider(loop, &provider);
}

fn addMultiplexedProvider(loop: ?*cdrv.PancakeDriverLoop, resident: *const cdrv.PancakeMultiplexedTransport, name: []const u8) i32 {
    const profile = providerProfile(name);
    return addMultiplexedProviderWithProfile(loop, resident, &profile);
}

fn addStreamProvider(
    loop: ?*cdrv.PancakeDriverLoop,
    stream: *const cdrv.PancakeStreamTransport,
    name: []const u8,
) i32 {
    const profile = providerProfile(name);
    const entry: cdrv.PancakeTransportProviderEntry = .{
        .profile = &profile,
        .execution_model = cdrv.PANCAKE_TRANSPORT_EXEC_STREAM,
        .implementation = stream,
    };
    const provider: cdrv.PancakeTransportProvider = .{
        .abi_version = cdrv.PANCAKE_TRANSPORT_PROVIDER_ABI_VERSION,
        .struct_size = @sizeOf(cdrv.PancakeTransportProvider),
        .entries = @ptrCast(&entry),
        .entry_count = 1,
        .lease_ctx = @constCast(stream),
        .same_configuration = sameStaticProvider,
        .retain = retainStaticProvider,
        .release = releaseStaticProvider,
    };
    return cdrv.pancake_driver_add_provider(loop, &provider);
}

fn openAccepted(
    host: ?*cd.PancakeHost,
    transport: ?[*]const u8,
    transport_len: usize,
    out_session: ?*?*cd.PancakeHostSession,
) i32 {
    // Address scheme with no accepted address: the candidate is the
    // unreachable-client placeholder, and every test that cares about the
    // signed locator selects one explicitly first, which the ensure keeps.
    return cd.pancake_host_session_open_accepted(
        host,
        transport,
        transport_len,
        cd.PANCAKE_DESIGNATOR_SCHEME_ADDRESS,
        null,
        0,
        null,
        0,
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

fn dialParts(loop: ?*cdrv.PancakeDriverLoop, transport: []const u8, designator: []const u8, direct: []const u8, out_operation_id: *u64) !i32 {
    const Context = struct { loop: ?*cdrv.PancakeDriverLoop, operation_id: *u64 };
    return callWithLocator(transport, designator, direct, Context{ .loop = loop, .operation_id = out_operation_id }, struct {
        fn call(ctx: Context, locator: *const cdrv.PancakeLocatorView) i32 {
            return cdrv.pancake_driver_dial(ctx.loop, locator, null, ctx.operation_id);
        }
    }.call);
}

fn dialLocator(
    loop: ?*cdrv.PancakeDriverLoop,
    locator: pancake.ocapn.model.PeerLocator,
    out_operation_id: *u64,
) !i32 {
    var hints: [cshared.locator_adapter.inline_hint_capacity]cdrv.PancakeLocatorHintView = undefined;
    var projection = try cshared.locator_adapter.Projection.init(
        std.testing.allocator,
        locator,
        &hints,
    );
    defer projection.deinit(std.testing.allocator);
    return cdrv.pancake_driver_dial(loop, &projection.view, null, out_operation_id);
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
    try expectOk(ctcp.pancake_tcp_netlayer_new(&default_tcp_config, &tcp));
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
    defer expectOk(crelay.pancake_relay_runtime_release(runtime)) catch unreachable;
    var provider: cdrv.PancakeTransportProvider = undefined;
    try expectOk(crelay.pancake_relay_transport_provider(runtime, &provider));
    try expectOk(cdrv.pancake_driver_add_provider(loop, &provider));
}

fn newEmptyLoop(seed_byte: u8) !TestLoop {
    const host = try newByteFedHost(seed_byte);
    errdefer _ = cd.pancake_host_release(host);
    var loop: ?*cdrv.PancakeDriverLoop = null;
    try expectOk(cdrv.pancake_driver_take_host(host, &driver_options_10s, &loop));
    errdefer _ = cdrv.pancake_driver_release(loop);
    return .{ .raw = loop, .host = host };
}

fn newLoop(seed_byte: u8) !TestLoop {
    const owned = try newEmptyLoop(seed_byte);
    errdefer owned.deinit();
    const loop = owned.raw;
    try installTcp(loop);
    return owned;
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
    drain_failure: bool = false,
    drain_success_report: bool = false,
    drain_empty_failure: bool = false,
    connect_with_readable: bool = false,
    listen_without_handle: bool = false,
    listen_output_on_failure: bool = false,
    pending_listen: bool = false,
    pending_listen_with_stream_fields: bool = false,
    connect_io: bool = false,
    finish_connect_success_report: bool = false,
    conn_close_failure: bool = false,
    conn_close_calls: usize = 0,
    pending_request: ?u64 = null,
    connection_readable: bool = false,
    read_result: ?isize = null,
    write_result: ?isize = null,
    cancel_listen_calls: usize = 0,
    stop_listen_calls: usize = 0,

    fn readinessFd(ctx: ?*anyopaque) callconv(.c) i32 {
        const self: *InvalidMultiplexedResident = @ptrCast(@alignCast(ctx.?));
        return self.wake.read;
    }

    fn drainReady(ctx: ?*anyopaque, out: ?[*]cdrv.PancakeMultiplexedReadyEvent, cap: usize, out_count: ?*usize, out_failure: ?*cdrv.PancakeProviderFailure) callconv(.c) i32 {
        const self: *InvalidMultiplexedResident = @ptrCast(@alignCast(ctx.?));
        self.wake.drain() catch unreachable;
        if (self.drain_success_report) {
            const name = "ContradictoryDrainFailure";
            out_failure.?.* = cshared.transport_provider.emptyProviderFailure();
            out_failure.?.result = c.PANCAKE_ERR_IO;
            out_failure.?.primary_name = name.ptr;
            out_failure.?.primary_name_len = name.len;
            return drained(out_count, 0);
        }
        if (self.drain_empty_failure) return c.PANCAKE_ERR_IO;
        if (self.drain_failure) {
            const primary = "InjectedReadinessFailure";
            const secondary = "InjectedDrainCleanupFailure";
            const report = out_failure.?;
            report.* = cshared.transport_provider.emptyProviderFailure();
            report.result = c.PANCAKE_ERR_IO;
            report.primary_name = primary.ptr;
            report.primary_name_len = primary.len;
            report.secondary_name = secondary.ptr;
            report.secondary_name_len = secondary.len;
            report.secondary_result = c.PANCAKE_ERR_IO;
            report.secondary_count = 2;
            return c.PANCAKE_ERR_IO;
        }
        if (self.invalid_mask) {
            if (cap == 0) return drained(out_count, 0);
            out.?[0] = .{ .subject = 0, .events = @as(u32, 1) << 31 };
            return drained(out_count, 1);
        }
        if (self.connect_with_readable) {
            if (cap == 0) return drained(out_count, 0);
            out.?[0] = .{
                .subject = 1,
                .events = cdrv.PANCAKE_MULTIPLEXED_EV_CONNECT | cdrv.PANCAKE_MULTIPLEXED_EV_READABLE,
            };
            return drained(out_count, 1);
        }
        if (self.connect_io) {
            if (cap == 0) return drained(out_count, 0);
            if (self.pending_request) |request| {
                out.?[0] = .{
                    .subject = request,
                    .events = cdrv.PANCAKE_MULTIPLEXED_EV_CONNECT,
                };
                return drained(out_count, 1);
            }
            if (self.connection_readable) {
                self.connection_readable = false;
                out.?[0] = .{
                    .subject = 7,
                    .events = cdrv.PANCAKE_MULTIPLEXED_EV_READABLE,
                };
                return drained(out_count, 1);
            }
            return drained(out_count, 0);
        }
        if (self.listen_without_handle) {
            return drained(out_count, 0);
        }
        return drained(out_count, cap + 1);
    }

    fn startConnect(ctx: ?*anyopaque, request: u64, _: ?*const cdrv.PancakeLocatorView, _: ?*const cshared.PancakeTransportOperationOptions, out_failure: ?*cdrv.PancakeProviderFailure) callconv(.c) i32 {
        const self: *InvalidMultiplexedResident = @ptrCast(@alignCast(ctx.?));
        if (!self.connect_io or self.pending_request != null)
            return providerFailure(out_failure, c.PANCAKE_ERR_INVALID_ARGUMENT, "InvalidTestDial");
        self.pending_request = request;
        _ = self.wake.nudge() catch unreachable;
        return c.PANCAKE_OK;
    }

    fn finishConnect(ctx: ?*anyopaque, request: u64, out_conn: ?*u64, out_failure: ?*cdrv.PancakeProviderFailure) callconv(.c) i32 {
        const self: *InvalidMultiplexedResident = @ptrCast(@alignCast(ctx.?));
        if (!self.connect_io or self.pending_request != request)
            return providerFailure(out_failure, c.PANCAKE_ERR_INVALID_ARGUMENT, "InvalidTestDialClaim");
        self.pending_request = null;
        self.connection_readable = true;
        _ = self.wake.nudge() catch unreachable;
        out_conn.?.* = 7;
        if (self.finish_connect_success_report) {
            const name = "ContradictoryConnectFailure";
            out_failure.?.* = cshared.transport_provider.emptyProviderFailure();
            out_failure.?.result = c.PANCAKE_ERR_IO;
            out_failure.?.primary_name = name.ptr;
            out_failure.?.primary_name_len = name.len;
        }
        return c.PANCAKE_OK;
    }

    fn claimExternal(_: ?*anyopaque, _: u64, _: ?*u64, out_failure: ?*cdrv.PancakeProviderFailure) callconv(.c) i32 {
        const code = providerFailure(out_failure, c.PANCAKE_ERR_INVALID_ARGUMENT, "InvalidExternalSubject");
        const failure = out_failure orelse return code;
        const cleanup = "ExternalClaimCleanupFailed";
        failure.secondary_result = c.PANCAKE_ERR_IO;
        failure.secondary_name = cleanup.ptr;
        failure.secondary_name_len = cleanup.len;
        failure.secondary_count = 2;
        return code;
    }

    fn subject(ctx: ?*anyopaque, _: u64, out_failure: ?*cdrv.PancakeProviderFailure) callconv(.c) i32 {
        const self: *InvalidMultiplexedResident = @ptrCast(@alignCast(ctx.?));
        self.conn_close_calls += 1;
        if (self.conn_close_failure)
            return providerFailure(out_failure, c.PANCAKE_ERR_IO, "ConnectRollbackCloseFailed");
        return c.PANCAKE_OK;
    }

    fn listen(
        ctx: ?*anyopaque,
        _: u64,
        _: ?[*]const u8,
        _: usize,
        _: ?[*]const u8,
        _: usize,
        _: ?*const cshared.PancakeTransportOperationOptions,
        out_result: ?*cdrv.PancakeListenResult,
    ) callconv(.c) i32 {
        const self: *InvalidMultiplexedResident = @ptrCast(@alignCast(ctx.?));
        if (self.listen_output_on_failure) {
            (out_result orelse return c.PANCAKE_ERR_NULL_POINTER).* = .{
                .state = cdrv.PANCAKE_LISTEN_READY,
                .listener = self,
                .attempt = null,
                .readiness_fd = -1,
            };
            return c.PANCAKE_ERR_INVALID_ARGUMENT;
        }
        if (self.listen_without_handle) {
            (out_result orelse return c.PANCAKE_ERR_NULL_POINTER).* = .{
                .state = cdrv.PANCAKE_LISTEN_READY,
                .listener = null,
                .attempt = null,
                .readiness_fd = -1,
            };
            return c.PANCAKE_OK;
        }
        if (self.pending_listen_with_stream_fields) {
            (out_result orelse return c.PANCAKE_ERR_NULL_POINTER).* = .{
                .state = cdrv.PANCAKE_LISTEN_PENDING,
                .listener = self,
                .attempt = null,
                .readiness_fd = -1,
            };
            return c.PANCAKE_OK;
        }
        if (self.pending_listen) {
            (out_result orelse return c.PANCAKE_ERR_NULL_POINTER).* = .{
                .state = cdrv.PANCAKE_LISTEN_PENDING,
                .listener = null,
                .attempt = null,
                .readiness_fd = -1,
            };
            return c.PANCAKE_OK;
        }
        return c.PANCAKE_ERR_INVALID_ARGUMENT;
    }

    fn finishListen(_: ?*anyopaque, _: u64, _: ?*?*anyopaque) callconv(.c) i32 {
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

    fn finishAccept(_: ?*anyopaque, _: ?*u64, _: ?*cdrv.PancakeProviderFailure) callconv(.c) i32 {
        return c.PANCAKE_ERR_WOULD_BLOCK;
    }

    fn cancelListen(ctx: ?*anyopaque, _: u64, _: ?*cdrv.PancakeProviderFailure) callconv(.c) i32 {
        const self: *InvalidMultiplexedResident = @ptrCast(@alignCast(ctx.?));
        self.cancel_listen_calls += 1;
        return c.PANCAKE_OK;
    }

    fn stopListen(ctx: ?*anyopaque, _: ?*cdrv.PancakeProviderFailure) callconv(.c) i32 {
        const self: *InvalidMultiplexedResident = @ptrCast(@alignCast(ctx.?));
        self.stop_listen_calls += 1;
        return c.PANCAKE_OK;
    }

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
            .listen = listen,
            .finish_listen = finishListen,
            .cancel_listen = cancelListen,
            .listener_locator = listenerLocator,
            .listener_advertise = listenerAdvertise,
            .finish_accept = finishAccept,
            .stop_listen = stopListen,
            .try_read = tryRead,
            .try_write = tryWrite,
            .conn_close = subject,
            .conn_take_failure = noMultiplexedConnectionFailure,
            .conn_remote_key = remoteKey,
        };
    }
};

/// An immediate-only stream provider that violates READY ownership by also
/// publishing a pending attempt. The driver can close the valid listener but
/// has no fabricated cancellation callback to invoke for the invalid field.
const MalformedImmediateStream = struct {
    listener_close_calls: usize = 0,

    fn listen(
        ctx: ?*anyopaque,
        _: ?[*]const u8,
        _: usize,
        _: ?[*]const u8,
        _: usize,
        _: ?*const cshared.PancakeTransportOperationOptions,
        out_result: ?*cdrv.PancakeListenResult,
        _: ?*cdrv.PancakeProviderFailure,
    ) callconv(.c) i32 {
        (out_result orelse return c.PANCAKE_ERR_NULL_POINTER).* = .{
            .state = cdrv.PANCAKE_LISTEN_READY,
            .listener = ctx,
            .attempt = ctx,
            .readiness_fd = -1,
        };
        return c.PANCAKE_OK;
    }

    fn waitAcceptable(_: ?*anyopaque, _: ?*anyopaque, _: i32, _: ?*cdrv.PancakeProviderFailure) callconv(.c) i32 {
        return c.PANCAKE_ERR_WOULD_BLOCK;
    }

    fn readinessFd(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) i32 {
        return -1;
    }

    fn localLocator(_: ?*anyopaque, _: ?*anyopaque, _: cdrv.PancakeLocatorSinkFn) callconv(.c) i32 {
        return c.PANCAKE_ERR_INVALID_ARGUMENT;
    }

    fn canonicalizeLocator(
        _: ?*anyopaque,
        view: ?*const cdrv.PancakeLocatorView,
        sink_ctx: ?*anyopaque,
        sink: cdrv.PancakeLocatorSinkFn,
    ) callconv(.c) i32 {
        return sink(sink_ctx, view);
    }

    fn accept(_: ?*anyopaque, _: ?*anyopaque, _: ?*?*anyopaque, _: ?*i32, _: ?*cdrv.PancakeProviderFailure) callconv(.c) i32 {
        return c.PANCAKE_ERR_WOULD_BLOCK;
    }

    fn closeListener(
        ctx: ?*anyopaque,
        _: ?*anyopaque,
        _: ?*cdrv.PancakeProviderFailure,
    ) callconv(.c) i32 {
        const self: *MalformedImmediateStream = @ptrCast(@alignCast(ctx.?));
        self.listener_close_calls += 1;
        return c.PANCAKE_OK;
    }

    fn read(_: ?*anyopaque, _: ?*anyopaque, _: ?[*]u8, _: usize) callconv(.c) isize {
        return -1;
    }

    fn writeAll(_: ?*anyopaque, _: ?*anyopaque, _: ?[*]const u8, _: usize) callconv(.c) i32 {
        return c.PANCAKE_ERR_IO;
    }

    fn closeConnection(_: ?*anyopaque, _: ?*anyopaque, _: ?*cdrv.PancakeProviderFailure) callconv(.c) i32 {
        return c.PANCAKE_OK;
    }

    fn table(self: *MalformedImmediateStream) cdrv.PancakeStreamTransport {
        return .{
            .abi_version = cdrv.PANCAKE_STREAM_TRANSPORT_ABI_VERSION,
            .struct_size = @sizeOf(cdrv.PancakeStreamTransport),
            .ctx = self,
            .start_connect = null,
            .finish_connect = null,
            .cancel_connect = null,
            .listen = listen,
            .finish_listen = null,
            .cancel_listen = null,
            .listener_wait_acceptable = waitAcceptable,
            .listener_readiness_fd = readinessFd,
            .listener_locator = localLocator,
            .listener_advertise = canonicalizeLocator,
            .listener_restoration_state = null,
            .accept = accept,
            .listener_close = closeListener,
            .read = read,
            .write_all = writeAll,
            .conn_close = closeConnection,
            .conn_take_failure = noStreamConnectionFailure,
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

    fn drainReady(ctx: ?*anyopaque, out: ?[*]cdrv.PancakeMultiplexedReadyEvent, cap: usize, out_count: ?*usize, _: ?*cdrv.PancakeProviderFailure) callconv(.c) i32 {
        const resident = self(ctx);
        resident.wake.drain() catch unreachable;
        if (cap == 0) return drained(out_count, 0);
        const request = resident.pending orelse return drained(out_count, 0);
        out.?[0] = .{ .subject = request, .events = cdrv.PANCAKE_MULTIPLEXED_EV_CONNECT };
        return drained(out_count, 1);
    }

    fn startConnect(ctx: ?*anyopaque, request: u64, _: ?*const cdrv.PancakeLocatorView, _: ?*const cshared.PancakeTransportOperationOptions, out_failure: ?*cdrv.PancakeProviderFailure) callconv(.c) i32 {
        const resident = self(ctx);
        if (resident.pending != null)
            return providerFailure(out_failure, c.PANCAKE_ERR_INVALID_ARGUMENT, "DialAlreadyPending");
        resident.pending = request;
        _ = resident.wake.nudge() catch unreachable;
        return c.PANCAKE_OK;
    }

    fn finishConnect(ctx: ?*anyopaque, request: u64, _: ?*u64, out_failure: ?*cdrv.PancakeProviderFailure) callconv(.c) i32 {
        const resident = self(ctx);
        if (resident.pending != request)
            return providerFailure(out_failure, c.PANCAKE_ERR_INVALID_ARGUMENT, "UnknownDialRequest");
        resident.pending = null;
        const code = providerFailure(out_failure, c.PANCAKE_ERR_IO, "ForcedAsyncDialFailure");
        const report = out_failure orelse return code;
        const secondary = "ForcedDialCleanupFailure";
        report.secondary_result = c.PANCAKE_ERR_INTERNAL;
        report.secondary_name = secondary.ptr;
        report.secondary_name_len = secondary.len;
        report.secondary_count = 2;
        return code;
    }

    fn cancelConnect(ctx: ?*anyopaque, request: u64, _: ?*cdrv.PancakeProviderFailure) callconv(.c) i32 {
        const resident = self(ctx);
        if (resident.pending == request) resident.pending = null;
        return c.PANCAKE_OK;
    }

    fn tryRead(_: ?*anyopaque, _: u64, _: ?[*]u8, _: usize) callconv(.c) isize {
        return cdrv.PANCAKE_MULTIPLEXED_WOULD_BLOCK;
    }

    fn tryWrite(_: ?*anyopaque, _: u64, _: ?[*]const u8, _: usize) callconv(.c) isize {
        return cdrv.PANCAKE_MULTIPLEXED_WOULD_BLOCK;
    }

    fn connClose(_: ?*anyopaque, _: u64, _: ?*cdrv.PancakeProviderFailure) callconv(.c) i32 {
        return c.PANCAKE_OK;
    }

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
            .listen = null,
            .finish_listen = null,
            .cancel_listen = null,
            .listener_locator = null,
            .listener_advertise = null,
            .finish_accept = null,
            .stop_listen = null,
            .try_read = tryRead,
            .try_write = tryWrite,
            .conn_close = connClose,
            .conn_take_failure = noMultiplexedConnectionFailure,
            .conn_remote_key = remoteKey,
        };
    }
};

const TypedResident = struct {
    wake: pancake.net.wake_channel.WakeChannel,
    opaque_hint: []const u8,
    restoration_state: []const u8 = "typed-restoration-state",
    invalid_restoration_result: bool = false,
    listeners: [2]Listener = undefined,
    listener_count: usize = 0,
    dial_verified: bool = false,
    retains: usize = 0,
    releases: usize = 0,
    retain_reports_failure: bool = false,
    release_code: i32 = c.PANCAKE_OK,
    failed_accept_route: ?u64 = null,
    provider_entry: cdrv.PancakeTransportProviderEntry = undefined,

    const Listener = struct {
        resident: *TypedResident,
        transport: []const u8,
        route: u64,
        active: bool = true,
    };

    fn self(ctx: ?*anyopaque) *TypedResident {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn listener(ctx: ?*anyopaque) *Listener {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn retain(ctx: ?*anyopaque, out_failure: ?*cdrv.PancakeProviderFailure) callconv(.c) i32 {
        const resident = self(ctx);
        resident.retains += 1;
        if (resident.retain_reports_failure) {
            const name = "ContradictoryRetainFailure";
            const report = out_failure.?;
            report.* = cshared.transport_provider.emptyProviderFailure();
            report.result = c.PANCAKE_ERR_IO;
            report.primary_name = name.ptr;
            report.primary_name_len = name.len;
        }
        return c.PANCAKE_OK;
    }

    fn release(ctx: ?*anyopaque, out_failure: ?*cdrv.PancakeProviderFailure) callconv(.c) i32 {
        const resident = self(ctx);
        resident.releases += 1;
        if (resident.release_code != c.PANCAKE_OK) {
            const name = "TestPackageReleaseFailed";
            const report = out_failure orelse return resident.release_code;
            report.* = cshared.transport_provider.emptyProviderFailure();
            report.result = resident.release_code;
            report.primary_name = name.ptr;
            report.primary_name_len = name.len;
        }
        return resident.release_code;
    }

    fn readinessFd(ctx: ?*anyopaque) callconv(.c) i32 {
        return self(ctx).wake.read;
    }

    fn drainReady(ctx: ?*anyopaque, out: ?[*]cdrv.PancakeMultiplexedReadyEvent, cap: usize, out_count: ?*usize, _: ?*cdrv.PancakeProviderFailure) callconv(.c) i32 {
        const resident = self(ctx);
        const route = resident.failed_accept_route orelse return drained(out_count, 0);
        if (cap == 0) return drained(out_count, 0);
        resident.failed_accept_route = null;
        out.?[0] = .{ .subject = route, .events = cdrv.PANCAKE_MULTIPLEXED_EV_ACCEPT };
        return drained(out_count, 1);
    }

    fn startConnect(ctx: ?*anyopaque, _: u64, view: ?*const cdrv.PancakeLocatorView, _: ?*const cshared.PancakeTransportOperationOptions, out_failure: ?*cdrv.PancakeProviderFailure) callconv(.c) i32 {
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
        return providerFailure(out_failure, c.PANCAKE_ERR_INVALID_ARGUMENT, "TypedDialRefused");
    }

    fn finishConnect(_: ?*anyopaque, _: u64, _: ?*u64, out_failure: ?*cdrv.PancakeProviderFailure) callconv(.c) i32 {
        return providerFailure(out_failure, c.PANCAKE_ERR_INVALID_ARGUMENT, "TypedDialClaimRefused");
    }

    fn subject(_: ?*anyopaque, _: u64, _: ?*cdrv.PancakeProviderFailure) callconv(.c) i32 {
        return c.PANCAKE_OK;
    }

    fn listen(
        ctx: ?*anyopaque,
        route: u64,
        transport: ?[*]const u8,
        transport_len: usize,
        designator: ?[*]const u8,
        len: usize,
        _: ?*const cshared.PancakeTransportOperationOptions,
        out_result: ?*cdrv.PancakeListenResult,
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
        slot.* = .{ .resident = resident, .transport = canonical, .route = route };
        (out_result orelse return c.PANCAKE_ERR_NULL_POINTER).* = .{
            .state = cdrv.PANCAKE_LISTEN_READY,
            .listener = slot,
            .attempt = null,
            .readiness_fd = -1,
        };
        return c.PANCAKE_OK;
    }

    fn finishListen(_: ?*anyopaque, _: u64, _: ?*?*anyopaque) callconv(.c) i32 {
        return c.PANCAKE_ERR_INVALID_ARGUMENT;
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

    fn listenerRestorationState(
        ctx: ?*anyopaque,
        out: ?[*]u8,
        cap: usize,
        out_len: ?*usize,
    ) callconv(.c) i32 {
        const resident = listener(ctx).resident;
        const len_slot = out_len orelse return c.PANCAKE_ERR_NULL_POINTER;
        if (resident.invalid_restoration_result) {
            len_slot.* = cap + 1;
            return c.PANCAKE_OK;
        }
        len_slot.* = resident.restoration_state.len;
        if (cap < resident.restoration_state.len) return c.PANCAKE_ERR_BUFFER_TOO_SMALL;
        if (resident.restoration_state.len != 0)
            @memcpy((out orelse return c.PANCAKE_ERR_NULL_POINTER)[0..resident.restoration_state.len], resident.restoration_state);
        return c.PANCAKE_OK;
    }

    fn finishAccept(ctx: ?*anyopaque, _: ?*u64, out_failure: ?*cdrv.PancakeProviderFailure) callconv(.c) i32 {
        const active = listener(ctx);
        if (active.active) {
            const slot = out_failure orelse return c.PANCAKE_ERR_NULL_POINTER;
            slot.* = .{
                .result = c.PANCAKE_ERR_IO,
                .primary_name = "ForcedAcceptFailure".ptr,
                .primary_name_len = "ForcedAcceptFailure".len,
                .secondary_result = c.PANCAKE_ERR_INTERNAL,
                .secondary_name = "ForcedAcceptCleanupFailure".ptr,
                .secondary_name_len = "ForcedAcceptCleanupFailure".len,
                .secondary_count = 2,
            };
            return c.PANCAKE_ERR_IO;
        }
        cshared.transport_provider.setProviderFailure(out_failure, c.PANCAKE_ERR_CLOSED, error.Closed);
        return c.PANCAKE_ERR_CLOSED;
    }

    fn stopListen(ctx: ?*anyopaque, _: ?*cdrv.PancakeProviderFailure) callconv(.c) i32 {
        listener(ctx).active = false;
        return c.PANCAKE_OK;
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
            .listen = listen,
            .finish_listen = finishListen,
            .cancel_listen = subject,
            .listener_locator = listenerLocator,
            .listener_advertise = listenerAdvertise,
            .listener_restoration_state = listenerRestorationState,
            .finish_accept = finishAccept,
            .stop_listen = stopListen,
            .try_read = tryRead,
            .try_write = tryWrite,
            .conn_close = subject,
            .conn_take_failure = noMultiplexedConnectionFailure,
            .conn_remote_key = remoteKey,
        };
    }
};

fn typedProvider(
    resident: *TypedResident,
    table: *const cdrv.PancakeMultiplexedTransport,
    profile: *const cdrv.PancakeTransportProfile,
) cdrv.PancakeTransportProvider {
    resident.provider_entry = .{
        .profile = profile,
        .execution_model = cdrv.PANCAKE_TRANSPORT_EXEC_MULTIPLEXED,
        .implementation = table,
    };
    return .{
        .abi_version = cdrv.PANCAKE_TRANSPORT_PROVIDER_ABI_VERSION,
        .struct_size = @sizeOf(cdrv.PancakeTransportProvider),
        .entries = @ptrCast(&resident.provider_entry),
        .entry_count = 1,
        .lease_ctx = resident,
        .same_configuration = sameStaticProvider,
        .retain = TypedResident.retain,
        .release = TypedResident.release,
    };
}

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

const ReentrantSessionRelease = struct {
    loop: ?*cdrv.PancakeDriverLoop,
    listener: u64,
    session: ?*cd.PancakeHostSession = null,
    result: i32 = c.PANCAKE_OK,
    readiness_result: i32 = c.PANCAKE_OK,
    restoration_result: i32 = c.PANCAKE_OK,
    ran: bool = false,
};

const CallbackRetirement = struct {
    loop: ?*cdrv.PancakeDriverLoop,
    result: i32 = c.PANCAKE_ERR_INTERNAL,
    ran: bool = false,
};

fn callbackRetirementBehavior(
    raw_ctx: ?*anyopaque,
    turn: ?*cd.PancakeHostTurn,
    verb: [*]const u8,
    verb_len: usize,
    args: ?[*]const c.PancakeArgument,
    args_len: usize,
    out_reply: *c.PancakeArgument,
) callconv(.c) i32 {
    _ = .{ turn, args, args_len };
    if (!std.mem.eql(u8, verb[0..verb_len], "retire")) return c.PANCAKE_ERR_INVALID_ARGUMENT;
    const ctx: *CallbackRetirement = @ptrCast(@alignCast(raw_ctx.?));
    ctx.ran = true;
    ctx.result = cdrv.pancake_driver_retire(ctx.loop);
    out_reply.* = c_args.argStr("retired");
    return c.PANCAKE_OK;
}

fn reentrantSessionReleaseBehavior(
    raw_ctx: ?*anyopaque,
    turn: ?*cd.PancakeHostTurn,
    verb: [*]const u8,
    verb_len: usize,
    args: ?[*]const c.PancakeArgument,
    args_len: usize,
    out_reply: *c.PancakeArgument,
) callconv(.c) i32 {
    _ = .{ turn, args, args_len };
    if (!std.mem.eql(u8, verb[0..verb_len], "probe")) return c.PANCAKE_ERR_INVALID_ARGUMENT;
    const ctx: *ReentrantSessionRelease = @ptrCast(@alignCast(raw_ctx.?));
    ctx.ran = true;
    var readiness_fd: i32 = -1;
    ctx.readiness_result = cdrv.pancake_driver_readiness_fd(ctx.loop, &readiness_fd);
    var restoration_len: usize = 0;
    ctx.restoration_result = cdrv.pancake_driver_listener_restoration_state(
        ctx.loop,
        ctx.listener,
        null,
        0,
        &restoration_len,
    );
    ctx.result = cdrv.pancake_driver_session_release(ctx.loop, ctx.session);
    out_reply.* = c_args.argStr("still open");
    return c.PANCAKE_OK;
}

/// What one loop's drained events amounted to; scalar facts only, because a
/// COMPLETION's views die at the next `pancake_driver_next_event`.
const Drained = struct {
    dialed_session: ?*cd.PancakeHostSession = null,
    dialed_operation_id: u64 = 0,
    dial_failed: bool = false,
    accepted: bool = false,
    accepted_listener: u64 = 0,
    accepted_session: ?*cd.PancakeHostSession = null,
    listener_ready: bool = false,
    ready_listener: u64 = 0,
    listener_failed: bool = false,
    failed_listener: u64 = 0,
    closed: bool = false,
    closed_count: usize = 0,
    closed_result: i32 = c.PANCAKE_OK,
    closed_message: [64]u8 = undefined,
    closed_message_len: usize = 0,
    closed_secondary_result: i32 = c.PANCAKE_OK,
    closed_secondary_count: u32 = 0,
    closed_secondary_message: [64]u8 = undefined,
    closed_secondary_message_len: usize = 0,
    settle_ticket: u64 = 0,
    settled_reference: c.PancakeReference = .{ .id = 0 },
    fail_ticket: u64 = 0,
};

/// Announce both embedders' post-open setup is done, so held inbound flows.
/// Loop scenarios call this once their OPENED and ACCEPTED events landed.
fn serveBoth(
    client: ?*cdrv.PancakeDriverLoop,
    client_session: ?*cd.PancakeHostSession,
    server: ?*cdrv.PancakeDriverLoop,
    server_session: ?*cd.PancakeHostSession,
) !void {
    try expectOk(cdrv.pancake_driver_session_serve(client, client_session));
    try expectOk(cdrv.pancake_driver_session_serve(server, server_session));
}

fn drainEvents(loop: ?*cdrv.PancakeDriverLoop, into: *Drained) !void {
    var event: cdrv.PancakeDriverEvent = undefined;
    while (true) {
        const rc = cdrv.pancake_driver_next_event(loop, &event);
        if (rc == c.PANCAKE_ERR_WOULD_BLOCK) return;
        try expectOk(rc);
        switch (event.kind) {
            cdrv.PANCAKE_DRIVER_EVENT_OPENED => {
                into.dialed_session = event.session;
                into.dialed_operation_id = event.operation_id;
            },
            cdrv.PANCAKE_DRIVER_EVENT_OPEN_FAILED => {
                into.dial_failed = true;
                if (event.primary_name) |name| std.debug.print("dial failed: {s}\n", .{name[0..event.primary_name_len]});
            },
            cdrv.PANCAKE_DRIVER_EVENT_ACCEPTED => {
                into.accepted = true;
                into.accepted_listener = event.listener_id;
                into.accepted_session = event.session;
            },
            cdrv.PANCAKE_DRIVER_EVENT_LISTENER_READY => {
                into.listener_ready = true;
                into.ready_listener = event.listener_id;
            },
            cdrv.PANCAKE_DRIVER_EVENT_LISTENER_FAILED => {
                into.listener_failed = true;
                into.failed_listener = event.listener_id;
                if (event.primary_name) |name| std.debug.print("listener failed: {s}\n", .{name[0..event.primary_name_len]});
            },
            cdrv.PANCAKE_DRIVER_EVENT_SESSION_CLOSED => {
                into.closed = true;
                into.closed_count += 1;
                into.closed_result = event.primary_result;
                into.closed_message_len = @min(event.primary_name_len, into.closed_message.len);
                if (into.closed_message_len != 0)
                    @memcpy(into.closed_message[0..into.closed_message_len], event.primary_name.?[0..into.closed_message_len]);
                into.closed_secondary_result = event.secondary_result;
                into.closed_secondary_count = event.secondary_count;
                into.closed_secondary_message_len = @min(event.secondary_name_len, into.closed_secondary_message.len);
                if (into.closed_secondary_message_len != 0)
                    @memcpy(
                        into.closed_secondary_message[0..into.closed_secondary_message_len],
                        event.secondary_name.?[0..into.closed_secondary_message_len],
                    );
            },
            cdrv.PANCAKE_DRIVER_EVENT_COMPLETION => switch (event.action.kind) {
                cd.PANCAKE_HOST_ACTION_SETTLE => {
                    into.settle_ticket = event.action.ticket;
                    if (event.action.value.kind == c.PANCAKE_ARG_REFERENCE)
                        into.settled_reference = event.action.value.reference;
                },
                cd.PANCAKE_HOST_ACTION_FAIL => into.fail_ticket = event.action.ticket,
                else => return error.UnexpectedCompletionKind,
            },
            else => return error.UnexpectedEventKind,
        }
    }
}

fn awaitListenerReady(loop: ?*cdrv.PancakeDriverLoop, listener: u64) !void {
    var seen = Drained{};
    for (0..2_000) |_| {
        try drainEvents(loop, &seen);
        if (seen.listener_failed) {
            try std.testing.expectEqual(listener, seen.failed_listener);
            return error.ListenerSetupFailed;
        }
        if (seen.listener_ready) {
            try std.testing.expectEqual(listener, seen.ready_listener);
            return;
        }
        try expectStep(cdrv.pancake_driver_step(loop, 5));
    }
    return error.ListenerSetupTimedOut;
}

fn listenReady(
    loop: ?*cdrv.PancakeDriverLoop,
    transport: []const u8,
    designator: []const u8,
) !u64 {
    var listener: u64 = 0;
    try expectOk(cdrv.pancake_driver_listen(
        loop,
        transport.ptr,
        transport.len,
        designator.ptr,
        designator.len,
        null,
        &listener,
    ));
    try awaitListenerReady(loop, listener);
    return listener;
}

test "loop refusals speak through the driver family's own error slot" {
    var loop_slot: ?*cdrv.PancakeDriverLoop = null;
    // A null Host is a null-pointer refusal.
    try std.testing.expectEqual(
        c.PANCAKE_ERR_NULL_POINTER,
        cdrv.pancake_driver_take_host(null, &driver_options_1s, &loop_slot),
    );
    // Malformed limits are refused with a message in this family's own slot.
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

    // Zero is the explicit unbounded sentinel for each wait budget. It is not
    // accepted for retained memory or admission limits.
    const unbounded_host = try newByteFedHost(0x35);
    var unbounded_options = driver_options_1s;
    unbounded_options.handshake_ms = 0;
    unbounded_options.listener_setup_ms = 0;
    unbounded_options.settle_ms = 0;
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        cdrv.pancake_driver_take_host(unbounded_host, &unbounded_options, &loop_slot),
    );
    try std.testing.expect(loop_slot != null);
    try std.testing.expectEqual(c.PANCAKE_OK, cdrv.pancake_driver_release(loop_slot));
    loop_slot = null;
    var message: [256]u8 = undefined;
    try std.testing.expect(cdrv.pancake_driver_last_error(&message, message.len) > 0);
    cdrv.pancake_driver_clear_last_error();
    try std.testing.expectEqual(@as(usize, 0), cdrv.pancake_driver_last_error(&message, message.len));

    const owned_loop = try newLoop(0x34);
    defer owned_loop.deinit();
    const loop = owned_loop.raw;
    const malformed_operation_options: cshared.PancakeTransportOperationOptions = .{
        .data = null,
        .size = 1,
    };
    var refused_listener: u64 = 73;
    cdrv.pancake_driver_clear_last_error();
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cdrv.pancake_driver_listen(
            loop,
            "tcp",
            3,
            "127.0.0.1:0",
            11,
            &malformed_operation_options,
            &refused_listener,
        ),
    );
    try std.testing.expectEqual(@as(u64, 73), refused_listener);
    var operation_message: [256]u8 = undefined;
    const operation_message_len = @min(
        cdrv.pancake_driver_last_error(&operation_message, operation_message.len),
        operation_message.len,
    );
    try std.testing.expect(std.mem.indexOf(u8, operation_message[0..operation_message_len], "transport operation options") != null);
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
    var profile = providerProfile("invalid-count");
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

test "driver close is one nonblocking monotonic barrier" {
    const owned = try newEmptyLoop(0x37);
    defer owned.deinit();
    const loop = owned.raw;

    var state: u32 = undefined;
    try expectOk(cdrv.pancake_driver_lifecycle_state(loop, &state));
    try std.testing.expectEqual(cd.PANCAKE_LIFECYCLE_ACTIVE, state);

    var invalid = close_cancel;
    invalid.pending = 99;
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, cdrv.pancake_driver_close(loop, &invalid));
    try expectOk(cdrv.pancake_driver_lifecycle_state(loop, &state));
    try std.testing.expectEqual(cd.PANCAKE_LIFECYCLE_ACTIVE, state);

    try expectOk(cdrv.pancake_driver_close(loop, &close_cancel));
    try expectOk(cdrv.pancake_driver_lifecycle_state(loop, &state));
    try std.testing.expectEqual(cd.PANCAKE_LIFECYCLE_TERMINATING, state);
    try expectStep(cdrv.pancake_driver_step(loop, 0));
    try expectOk(cdrv.pancake_driver_lifecycle_state(loop, &state));
    try std.testing.expectEqual(cd.PANCAKE_LIFECYCLE_CLOSED, state);

    // Finish cannot weaken a completed cancel barrier, and new runtime work
    // is refused while status/event drains and release remain available.
    const finish_unbounded: cdrv.PancakeCloseOptions = .{
        .abi_version = cdrv.PANCAKE_CLOSE_OPTIONS_ABI_VERSION,
        .struct_size = @sizeOf(cdrv.PancakeCloseOptions),
        .pending = cd.PANCAKE_PENDING_FINISH,
        .grace_mode = cdrv.PANCAKE_CLOSE_GRACE_UNBOUNDED,
        .grace_ms = 0,
    };
    try expectOk(cdrv.pancake_driver_close(loop, &finish_unbounded));

    var tcp: ?*ctcp.PancakeTcpNetlayer = null;
    try expectOk(ctcp.pancake_tcp_netlayer_new(&default_tcp_config, &tcp));
    defer ctcp.pancake_tcp_netlayer_release(tcp);
    var provider: cdrv.PancakeTransportProvider = undefined;
    try expectOk(ctcp.pancake_tcp_transport_provider(tcp, &provider));
    try std.testing.expectEqual(c.PANCAKE_ERR_CLOSED, cdrv.pancake_driver_add_provider(loop, &provider));
}

test "driver step wait budget reports the nearest pending-work deadline" {
    const owned = try newEmptyLoop(0x38);
    defer owned.deinit();
    const loop = owned.raw;

    var wait_ms: i32 = undefined;
    // An idle loop pends no deadline: readiness alone advances it.
    try expectOk(cdrv.pancake_driver_step_wait_ms(loop, &wait_ms));
    try std.testing.expectEqual(@as(i32, -1), wait_ms);

    // A committed finite grace bounds the wait until the next step applies
    // it. The exact remainder depends on the loop's own clock, so the pin is
    // the range, not a value.
    const finish_5s: cdrv.PancakeCloseOptions = .{
        .abi_version = cdrv.PANCAKE_CLOSE_OPTIONS_ABI_VERSION,
        .struct_size = @sizeOf(cdrv.PancakeCloseOptions),
        .pending = cd.PANCAKE_PENDING_FINISH,
        .grace_mode = cdrv.PANCAKE_CLOSE_GRACE_FINITE,
        .grace_ms = 5000,
    };
    try expectOk(cdrv.pancake_driver_close(loop, &finish_5s));
    try expectOk(cdrv.pancake_driver_step_wait_ms(loop, &wait_ms));
    try std.testing.expect(wait_ms >= 0 and wait_ms <= 5000);

    // An idle finish reaches CLOSED at its next step; terminal state pends
    // no deadline and the close driver parks on activity alone.
    try expectStep(cdrv.pancake_driver_step(loop, 0));
    var state: u32 = undefined;
    try expectOk(cdrv.pancake_driver_lifecycle_state(loop, &state));
    try std.testing.expectEqual(cd.PANCAKE_LIFECYCLE_CLOSED, state);
    try expectOk(cdrv.pancake_driver_step_wait_ms(loop, &wait_ms));
    try std.testing.expectEqual(@as(i32, -1), wait_ms);
}

test "driver close initiation succeeds under allocator pressure" {
    var counting = @import("../support/c_abi_counting_alloc.zig").CountingHost{};
    const spec = counting.spec();
    var context: ?*c.PancakeContext = null;
    try expectOk(c.pancake_context_new_with_allocator(&spec, &context));

    const seed = hostSeed(0x5f);
    var host: ?*cd.PancakeHost = null;
    try expectOk(cd.pancake_host_new_in(
        context,
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
    var loop: ?*cdrv.PancakeDriverLoop = null;
    try expectOk(cdrv.pancake_driver_take_host(host, &driver_options_1s, &loop));

    counting.fail_allocations = true;
    try expectOk(cdrv.pancake_driver_close(loop, &close_cancel));
    var state: u32 = undefined;
    try expectOk(cdrv.pancake_driver_lifecycle_state(loop, &state));
    try std.testing.expectEqual(cd.PANCAKE_LIFECYCLE_TERMINATING, state);
    counting.fail_allocations = false;

    try expectStep(cdrv.pancake_driver_step(loop, 0));
    try expectOk(cdrv.pancake_driver_lifecycle_state(loop, &state));
    try std.testing.expectEqual(cd.PANCAKE_LIFECYCLE_CLOSED, state);
    try expectOk(cdrv.pancake_driver_release(loop));
    c.pancake_context_release(context);
    try std.testing.expect(counting.balanced());
}

test "driver close waits for committed C event delivery after native teardown" {
    const owned = try newLoop(0x3a);
    defer owned.deinit();
    const loop = owned.raw;

    var listener: u64 = 0;
    try expectOk(cdrv.pancake_driver_listen(
        loop,
        "tcp",
        3,
        "127.0.0.1:0",
        11,
        null,
        &listener,
    ));
    var locator: cdrv.PancakeLocatorView = undefined;
    for (0..2_000) |_| {
        const code = cdrv.pancake_driver_listener_locator(loop, listener, &locator);
        if (code == c.PANCAKE_OK) break;
        try std.testing.expectEqual(c.PANCAKE_ERR_WOULD_BLOCK, code);
        try expectStep(cdrv.pancake_driver_step(loop, 5));
    } else return error.ListenerSetupTimedOut;

    try expectOk(cdrv.pancake_driver_close(loop, &close_cancel));
    var state: u32 = undefined;
    try expectOk(cdrv.pancake_driver_lifecycle_state(loop, &state));
    try std.testing.expectEqual(cd.PANCAKE_LIFECYCLE_TERMINATING, state);

    var event: cdrv.PancakeDriverEvent = undefined;
    try expectOk(cdrv.pancake_driver_next_event(loop, &event));
    try std.testing.expectEqual(cdrv.PANCAKE_DRIVER_EVENT_LISTENER_READY, event.kind);
    try std.testing.expectEqual(listener, event.listener_id);
    try std.testing.expectEqual(c.PANCAKE_ERR_WOULD_BLOCK, cdrv.pancake_driver_next_event(loop, &event));

    try expectStep(cdrv.pancake_driver_step(loop, 0));
    try expectOk(cdrv.pancake_driver_lifecycle_state(loop, &state));
    try std.testing.expectEqual(cd.PANCAKE_LIFECYCLE_CLOSED, state);
}

test "driver finish timeout closes transport work before reporting timeout" {
    const server_owned = try newLoop(0x38);
    defer server_owned.deinit();
    const server = server_owned.raw;
    const listener = try listenReady(server, "tcp", "127.0.0.1:0");
    const locator = try readListenerLocator(server, listener);
    defer pancake.ocapn.model.freePeerLocator(std.testing.allocator, locator);

    const client_owned = try newLoop(0x39);
    defer client_owned.deinit();
    const client = client_owned.raw;
    var operation_id: u64 = 0;
    try expectOk(try dialLocator(client, locator, &operation_id));

    const finish: cdrv.PancakeCloseOptions = .{
        .abi_version = cdrv.PANCAKE_CLOSE_OPTIONS_ABI_VERSION,
        .struct_size = @sizeOf(cdrv.PancakeCloseOptions),
        .pending = cd.PANCAKE_PENDING_FINISH,
        .grace_mode = cdrv.PANCAKE_CLOSE_GRACE_FINITE,
        .grace_ms = 25,
    };
    try expectOk(cdrv.pancake_driver_close(client, &finish));

    var state: u32 = cd.PANCAKE_LIFECYCLE_FINISHING;
    var timed_out = false;
    var rounds: usize = 0;
    while (state != cd.PANCAKE_LIFECYCLE_CLOSED and rounds < 20) : (rounds += 1) {
        try expectStep(cdrv.pancake_driver_step(client, -1));
        while (true) {
            var event: cdrv.PancakeDriverEvent = undefined;
            const event_rc = cdrv.pancake_driver_next_event(client, &event);
            if (event_rc == c.PANCAKE_ERR_WOULD_BLOCK) break;
            try expectOk(event_rc);
        }
        const state_rc = cdrv.pancake_driver_lifecycle_state(client, &state);
        timed_out = state_rc == c.PANCAKE_ERR_TIMEOUT;
        try std.testing.expect(state_rc == c.PANCAKE_OK or timed_out);
    }
    try std.testing.expectEqual(cd.PANCAKE_LIFECYCLE_CLOSED, state);
    try std.testing.expect(timed_out);
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
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cd.pancake_host_set_session_limits(host, 0, 17, 0),
    );

    // Application state created before transfer remains on the same Host, and
    // transport lifecycle is immediately usable through the generic driver.
    const listener = try listenReady(loop, "tcp", "127.0.0.1:0");
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

    // Let the loop allocation succeed, then fail its runtime scaffolding. The
    // rollback destructor must not cancel the borrowed core before returning
    // the C drive token.
    counting.allocations_before_failure = 1;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INTERNAL,
        cdrv.pancake_driver_take_host(host, &driver_options_1s, &loop),
    );
    try std.testing.expect(loop == null);
    counting.allocations_before_failure = null;

    var state: u32 = undefined;
    try expectOk(cd.pancake_host_lifecycle_state(host, &state));
    try std.testing.expectEqual(cd.PANCAKE_LIFECYCLE_ACTIVE, state);
    try expectOk(cd.pancake_host_publish(host, "after-rollback", 14, widgetBehavior, null, null));
    try expectOk(cd.pancake_host_release(host));
    c.pancake_context_release(ctx);
    try std.testing.expect(counting.balanced());
}

test "a closing byte-fed Host cannot transfer to a new driver" {
    const host = try newByteFedHost(0x3b);
    try expectOk(cd.pancake_host_close(host, &close_cancel, 0));

    var loop: ?*cdrv.PancakeDriverLoop = null;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_CLOSED,
        cdrv.pancake_driver_take_host(host, &driver_options_1s, &loop),
    );
    try std.testing.expect(loop == null);

    // Failed native adoption returns the C drive token to the byte-fed owner.
    try expectOk(cd.pancake_host_release(host));
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
    try expectOk(addMultiplexedProvider(loop, &table, "invalid-count"));
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        addMultiplexedProvider(loop, &table, "tcp"),
    );

    _ = try resident.wake.nudge();
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, cdrv.pancake_driver_step(loop, 0));
    // The violation poisons the adapter: stepping it again cannot silently
    // resume calls through a table that already broke memory ownership.
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, cdrv.pancake_driver_step(loop, 0));
}

test "listener close remains available after terminal provider failure" {
    const owned_loop = try newLoop(0x5e);
    defer owned_loop.deinit();
    const loop = owned_loop.raw;

    var listener: u64 = 0;
    try expectOk(cdrv.pancake_driver_listen(
        loop,
        pancake.ocapn.model.transport.tcp.ptr,
        pancake.ocapn.model.transport.tcp.len,
        "127.0.0.1:0",
        "127.0.0.1:0".len,
        null,
        &listener,
    ));
    try awaitListenerReady(loop, listener);
    var readiness_fd: i32 = -1;
    try expectOk(cdrv.pancake_driver_readiness_fd(loop, &readiness_fd));

    var resident = InvalidMultiplexedResident{ .wake = try pancake.net.wake_channel.WakeChannel.open() };
    defer resident.wake.deinit();
    var table = resident.table();
    try expectOk(addMultiplexedProvider(loop, &table, "terminal-failure"));
    _ = try resident.wake.nudge();
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, cdrv.pancake_driver_step(loop, 0));
    try expectOk(cdrv.pancake_driver_listener_close(loop, listener));

    // Provider work stays fail-stop, but that failure cannot strand the
    // owner's explicit terminal barrier.
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, cdrv.pancake_driver_step(loop, 0));
    try expectOk(cdrv.pancake_driver_close(loop, &close_cancel));
    var state: u32 = undefined;
    try expectOk(cdrv.pancake_driver_lifecycle_state(loop, &state));
    while (state != cd.PANCAKE_LIFECYCLE_CLOSED) {
        try expectStep(cdrv.pancake_driver_step(loop, 0));
        try expectOk(cdrv.pancake_driver_lifecycle_state(loop, &state));
    }

    // Close initiation posts one wake. Terminal stepping must consume it
    // explicitly rather than relying on that stale level to busy-spin the
    // lifecycle forward.
    var fds = [_]std.posix.pollfd{.{ .fd = readiness_fd, .events = std.posix.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(usize, 0), try std.posix.poll(&fds, 0));
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, cdrv.pancake_driver_step(loop, 0));
}

test "provider registration requires complete profile and configuration equivalence" {
    var first = InvalidMultiplexedResident{ .wake = try pancake.net.wake_channel.WakeChannel.open() };
    defer first.wake.deinit();
    var other = InvalidMultiplexedResident{ .wake = try pancake.net.wake_channel.WakeChannel.open() };
    defer other.wake.deinit();
    const owned_loop = try newLoop(0x54);
    defer owned_loop.deinit();
    const loop = owned_loop.raw;

    var first_table = first.table();
    var profile = providerProfile("equivalence-test");
    try expectOk(addMultiplexedProviderWithProfile(loop, &first_table, &profile));
    try expectOk(addMultiplexedProviderWithProfile(loop, &first_table, &profile));

    var other_table = other.table();
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        addMultiplexedProviderWithProfile(loop, &other_table, &profile),
    );

    profile.designator_scheme = cdrv.PANCAKE_DESIGNATOR_SCHEME_KEY;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        addMultiplexedProviderWithProfile(loop, &first_table, &profile),
    );
}

test "a dial-only resident registers without fake listener callbacks" {
    const owned_loop = try newLoop(0x47);
    defer owned_loop.deinit();
    const loop = owned_loop.raw;
    var resident = InvalidMultiplexedResident{ .wake = try pancake.net.wake_channel.WakeChannel.open() };
    defer resident.wake.deinit();
    var table = resident.table();
    table.listen = null;
    table.finish_listen = null;
    table.cancel_listen = null;
    table.listener_locator = null;
    table.listener_advertise = null;
    table.finish_accept = null;
    table.stop_listen = null;
    try expectOk(addMultiplexedProvider(loop, &table, "invalid-count"));

    var listener: u64 = 0;
    const name = "invalid-count";
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cdrv.pancake_driver_listen(loop, name.ptr, name.len, "endpoint".ptr, "endpoint".len, null, &listener),
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

test "an immediate multiplexed listener registers without completion callbacks" {
    const owned_loop = try newLoop(0x5b);
    defer owned_loop.deinit();
    var resident = InvalidMultiplexedResident{
        .wake = try pancake.net.wake_channel.WakeChannel.open(),
        .listen_without_handle = true,
    };
    defer resident.wake.deinit();
    var table = resident.table();
    table.finish_listen = null;
    table.cancel_listen = null;
    try expectOk(addMultiplexedProvider(owned_loop.raw, &table, "immediate-listener"));
}

test "an immediate-only multiplexed provider cannot publish pending setup" {
    const owned_loop = try newLoop(0x5c);
    defer owned_loop.deinit();
    var resident = InvalidMultiplexedResident{
        .wake = try pancake.net.wake_channel.WakeChannel.open(),
        .pending_listen = true,
    };
    defer resident.wake.deinit();
    var table = resident.table();
    table.finish_listen = null;
    table.cancel_listen = null;
    try expectOk(addMultiplexedProvider(owned_loop.raw, &table, "invalid-pending"));

    var listener: u64 = 0;
    try expectOk(cdrv.pancake_driver_listen(
        owned_loop.raw,
        "invalid-pending",
        "invalid-pending".len,
        "",
        0,
        null,
        &listener,
    ));
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cdrv.pancake_driver_step(owned_loop.raw, 0),
    );
}

test "each stream profile requires its own implementation table" {
    const owned_loop = try newEmptyLoop(0x5d);
    defer owned_loop.deinit();
    var tcp: ?*ctcp.PancakeTcpNetlayer = null;
    try expectOk(ctcp.pancake_tcp_netlayer_new(&default_tcp_config, &tcp));
    defer ctcp.pancake_tcp_netlayer_release(tcp);
    var provider: cdrv.PancakeTransportProvider = undefined;
    try expectOk(ctcp.pancake_tcp_transport_provider(tcp, &provider));
    var entries = [2]cdrv.PancakeTransportProviderEntry{
        provider.entries.?[0],
        provider.entries.?[1],
    };
    entries[1].implementation = entries[0].implementation;
    provider.entries = &entries;
    provider.entry_count = entries.len;

    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cdrv.pancake_driver_add_provider(owned_loop.raw, &provider),
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
    table.listen = null;
    table.finish_listen = null;
    table.cancel_listen = null;
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
    try expectOk(cdrv.pancake_driver_adopt_external(
        loop,
        "external-only",
        13,
        7,
        cdrv.PANCAKE_DRIVER_ADOPT_DIALED,
        &ticket,
    ));
    try std.testing.expect(ticket != 0);
    var event: cdrv.PancakeDriverEvent = undefined;
    try expectOk(cdrv.pancake_driver_next_event(loop, &event));
    try std.testing.expectEqual(cdrv.PANCAKE_DRIVER_EVENT_OPEN_FAILED, event.kind);
    try std.testing.expectEqual(ticket, event.operation_id);
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, event.primary_result);
    try std.testing.expectEqualStrings("InvalidExternalSubject", event.primary_name.?[0..event.primary_name_len]);
    try std.testing.expectEqual(c.PANCAKE_ERR_IO, event.secondary_result);
    try std.testing.expectEqual(@as(u32, 2), event.secondary_count);
    try std.testing.expectEqualStrings("ExternalClaimCleanupFailed", event.secondary_name.?[0..event.secondary_name_len]);
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
    var operation_id: u64 = 0;
    try expectOk(cdrv.pancake_driver_dial(owned_loop.raw, locator_view, null, &operation_id));
    try std.testing.expectEqual(@as(u64, 1), operation_id);
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

test "contradictory multiplexed connect success retains rollback close failure" {
    const owned_loop = try newLoop(0x6f);
    defer owned_loop.deinit();
    var resident = InvalidMultiplexedResident{
        .wake = try pancake.net.wake_channel.WakeChannel.open(),
        .connect_io = true,
        .finish_connect_success_report = true,
        .conn_close_failure = true,
    };
    defer resident.wake.deinit();
    var table = resident.table();
    try expectOk(addMultiplexedProvider(owned_loop.raw, &table, "contradictory-connect"));

    var locator: ?*c.PancakeLocator = null;
    try expectOk(c.pancake_locator_new(
        "contradictory-connect",
        "contradictory-connect".len,
        "endpoint",
        "endpoint".len,
        c.PANCAKE_HINTS_MAP,
        &locator,
    ));
    defer c.pancake_locator_release(locator);
    var view: ?*const c.PancakeLocatorView = null;
    try expectOk(c.pancake_locator_borrow_view(locator, &view));
    var operation_id: u64 = 0;
    try expectOk(cdrv.pancake_driver_dial(owned_loop.raw, view, null, &operation_id));

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
    try std.testing.expectEqual(@as(usize, 1), resident.conn_close_calls);
    var message: [512]u8 = undefined;
    const message_len = @min(cdrv.pancake_driver_last_error(&message, message.len), message.len);
    try std.testing.expect(std.mem.indexOf(u8, message[0..message_len], "ProviderContract") != null);
    try std.testing.expect(std.mem.indexOf(u8, message[0..message_len], "ConnectRollbackCloseFailed") != null);
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
        providerProfile("typed-test"),
        providerProfile("typed-test-alt"),
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
        .same_configuration = sameStaticProvider,
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

    const listener = try listenReady(loop, "typed-test", "listener-peer");
    const published = try readListenerLocator(loop, listener);
    defer pancake.ocapn.model.freePeerLocator(std.testing.allocator, published);
    try std.testing.expectEqualStrings("typed-test", published.transport);
    try std.testing.expectEqualStrings("listener-peer", published.designator);
    try std.testing.expectEqual(@as(usize, 4), published.hints.entries.len);
    try std.testing.expectEqualStrings("primary", published.hints.entries[0].value.string);
    try std.testing.expectEqualSlices(u8, opaque_bytes, published.hints.entries[1].value.bytes);
    try std.testing.expect(published.hints.entries[2].value.boolean);
    try std.testing.expectEqual(@as(i64, 73), published.hints.entries[3].value.integer);

    var restoration_len: usize = 0;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_BUFFER_TOO_SMALL,
        cdrv.pancake_driver_listener_restoration_state(loop, listener, null, 0, &restoration_len),
    );
    try std.testing.expectEqual(resident.restoration_state.len, restoration_len);
    var short: [4]u8 = @splat(0xa5);
    try std.testing.expectEqual(
        c.PANCAKE_ERR_BUFFER_TOO_SMALL,
        cdrv.pancake_driver_listener_restoration_state(loop, listener, &short, short.len, &restoration_len),
    );
    try std.testing.expectEqualSlices(u8, &([_]u8{0xa5} ** short.len), &short);
    var restoration: ["typed-restoration-state".len]u8 = undefined;
    try expectOk(cdrv.pancake_driver_listener_restoration_state(
        loop,
        listener,
        &restoration,
        restoration.len,
        &restoration_len,
    ));
    try std.testing.expectEqualStrings(resident.restoration_state, restoration[0..restoration_len]);

    const second_listener = try listenReady(loop, "typed-test-alt", "listener-peer");
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
    var operation_id: u64 = 0;
    try expectOk(cdrv.pancake_driver_dial(loop, dial_view, null, &operation_id));
    try std.testing.expect(operation_id != 0);
    try std.testing.expect(resident.dial_verified);
    var dial_event: cdrv.PancakeDriverEvent = undefined;
    try expectOk(cdrv.pancake_driver_next_event(loop, &dial_event));
    try std.testing.expectEqual(cdrv.PANCAKE_DRIVER_EVENT_OPEN_FAILED, dial_event.kind);
    try std.testing.expectEqual(operation_id, dial_event.operation_id);
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, dial_event.primary_result);
    try std.testing.expectEqualStrings("TypedDialRefused", dial_event.primary_name.?[0..dial_event.primary_name_len]);

    resident.invalid_restoration_result = true;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cdrv.pancake_driver_listener_restoration_state(loop, listener, null, 0, &restoration_len),
    );
    try std.testing.expectEqual(@as(usize, 0), restoration_len);

    // The earlier contract failure remains the exact teardown cause, but the
    // consuming release cannot return INVALID_ARGUMENT: that code exclusively
    // means admission refused and the handle is still live.
    try std.testing.expectEqual(c.PANCAKE_ERR_INTERNAL, cdrv.pancake_driver_release(loop));
    loop_live = false;
    try std.testing.expectEqual(@as(usize, 1), resident.releases);
}

test "an active listener failure retires its stable id through a reserved event" {
    var resident: TypedResident = .{
        .wake = try pancake.net.wake_channel.WakeChannel.open(),
        .opaque_hint = &.{},
    };
    defer resident.wake.deinit();
    const owned_loop = try newEmptyLoop(0x6a);
    defer owned_loop.deinit();
    var table = resident.table();
    const profile = providerProfile("typed-test");
    var provider = typedProvider(&resident, &table, &profile);
    try expectOk(cdrv.pancake_driver_add_provider(owned_loop.raw, &provider));

    const listener_id = try listenReady(owned_loop.raw, "typed-test", "listener-peer");
    resident.failed_accept_route = resident.listeners[0].route;
    _ = try resident.wake.nudge();
    try expectOk(cdrv.pancake_driver_step(owned_loop.raw, 1_000));

    var event: cdrv.PancakeDriverEvent = undefined;
    try expectOk(cdrv.pancake_driver_next_event(owned_loop.raw, &event));
    try std.testing.expectEqual(cdrv.PANCAKE_DRIVER_EVENT_LISTENER_FAILED, event.kind);
    try std.testing.expectEqual(listener_id, event.listener_id);
    try std.testing.expectEqual(c.PANCAKE_ERR_IO, event.primary_result);
    try std.testing.expectEqualStrings("ForcedAcceptFailure", event.primary_name.?[0..event.primary_name_len]);
    try std.testing.expectEqual(c.PANCAKE_ERR_INTERNAL, event.secondary_result);
    try std.testing.expectEqualStrings("ForcedAcceptCleanupFailure", event.secondary_name.?[0..event.secondary_name_len]);
    try std.testing.expectEqual(@as(u32, 2), event.secondary_count);
    var locator: cdrv.PancakeLocatorView = undefined;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_NOT_FOUND,
        cdrv.pancake_driver_listener_locator(owned_loop.raw, listener_id, &locator),
    );
    try std.testing.expect(!resident.listeners[0].active);
}

test "provider registration keeps rollback release failure secondary" {
    var first: TypedResident = .{
        .wake = try pancake.net.wake_channel.WakeChannel.open(),
        .opaque_hint = &.{},
    };
    defer first.wake.deinit();
    var conflicting: TypedResident = .{
        .wake = try pancake.net.wake_channel.WakeChannel.open(),
        .opaque_hint = &.{},
        .release_code = c.PANCAKE_ERR_IO,
    };
    defer conflicting.wake.deinit();

    const owned_loop = try newEmptyLoop(0x63);
    var loop_live = true;
    defer if (loop_live) {
        _ = cdrv.pancake_driver_release(owned_loop.raw);
    };
    var first_table = first.table();
    var conflicting_table = conflicting.table();
    const profile = providerProfile("release-conflict");
    const first_provider = typedProvider(&first, &first_table, &profile);
    const conflicting_provider = typedProvider(&conflicting, &conflicting_table, &profile);
    try expectOk(cdrv.pancake_driver_add_provider(owned_loop.raw, &first_provider));

    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cdrv.pancake_driver_add_provider(owned_loop.raw, &conflicting_provider),
    );
    try std.testing.expectEqual(@as(usize, 1), conflicting.retains);
    try std.testing.expectEqual(@as(usize, 1), conflicting.releases);
    var message: [256]u8 = undefined;
    const message_len = @min(cdrv.pancake_driver_last_error(&message, message.len), message.len);
    try std.testing.expect(std.mem.indexOf(u8, message[0..message_len], "ProviderConfigurationConflict") != null);
    try std.testing.expect(std.mem.indexOf(u8, message[0..message_len], "TestPackageReleaseFailed") != null);

    try expectOk(cdrv.pancake_driver_release(owned_loop.raw));
    loop_live = false;
}

test "contradictory retain diagnostics retire the committed package lease" {
    var resident: TypedResident = .{
        .wake = try pancake.net.wake_channel.WakeChannel.open(),
        .opaque_hint = &.{},
        .retain_reports_failure = true,
    };
    defer resident.wake.deinit();
    const owned_loop = try newEmptyLoop(0x65);
    defer owned_loop.deinit();
    var table = resident.table();
    const profile = providerProfile("bad-retain-report");
    const provider = typedProvider(&resident, &table, &profile);

    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cdrv.pancake_driver_add_provider(owned_loop.raw, &provider),
    );
    try std.testing.expectEqual(@as(usize, 1), resident.retains);
    try std.testing.expectEqual(@as(usize, 1), resident.releases);
}

test "driver release returns final provider package failure" {
    var resident: TypedResident = .{
        .wake = try pancake.net.wake_channel.WakeChannel.open(),
        .opaque_hint = &.{},
        .release_code = c.PANCAKE_ERR_IO,
    };
    defer resident.wake.deinit();
    const owned_loop = try newEmptyLoop(0x64);
    var table = resident.table();
    const profile = providerProfile("release-failure");
    const provider = typedProvider(&resident, &table, &profile);
    try expectOk(cdrv.pancake_driver_add_provider(owned_loop.raw, &provider));

    try std.testing.expectEqual(c.PANCAKE_ERR_IO, cdrv.pancake_driver_release(owned_loop.raw));
    try std.testing.expectEqual(@as(usize, 1), resident.releases);
    var message: [128]u8 = undefined;
    const message_len = @min(cdrv.pancake_driver_last_error(&message, message.len), message.len);
    try std.testing.expect(std.mem.indexOf(u8, message[0..message_len], "TestPackageReleaseFailed") != null);
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
    _ = try resident.wake.nudge();
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, cdrv.pancake_driver_step(loop, 0));
}

test "multiplexed readiness failure preserves its exact chain" {
    var resident = InvalidMultiplexedResident{
        .wake = try pancake.net.wake_channel.WakeChannel.open(),
        .drain_failure = true,
    };
    defer resident.wake.deinit();
    const owned_loop = try newLoop(0x69);
    defer owned_loop.deinit();
    var table = resident.table();
    try expectOk(addMultiplexedProvider(owned_loop.raw, &table, "failed-drain"));
    _ = try resident.wake.nudge();

    try std.testing.expectEqual(c.PANCAKE_ERR_IO, cdrv.pancake_driver_step(owned_loop.raw, 0));
    var message: [256]u8 = undefined;
    const len = @min(cdrv.pancake_driver_last_error(&message, message.len), message.len);
    try std.testing.expect(std.mem.indexOf(u8, message[0..len], "InjectedReadinessFailure") != null);
    try std.testing.expect(std.mem.indexOf(u8, message[0..len], "InjectedDrainCleanupFailure") != null);
    try std.testing.expect(std.mem.indexOf(u8, message[0..len], "2 secondary failures") != null);
}

test "multiplexed readiness drain rejects contradictory failure reports" {
    inline for (.{ "success-with-failure", "failure-without-report" }, 0..) |name, index| {
        var resident = InvalidMultiplexedResident{
            .wake = try pancake.net.wake_channel.WakeChannel.open(),
            .drain_success_report = index == 0,
            .drain_empty_failure = index == 1,
        };
        defer resident.wake.deinit();
        const owned_loop = try newLoop(0x6a + index);
        defer owned_loop.deinit();
        var table = resident.table();
        try expectOk(addMultiplexedProvider(owned_loop.raw, &table, name));
        _ = try resident.wake.nudge();
        try std.testing.expectEqual(
            c.PANCAKE_ERR_INVALID_ARGUMENT,
            cdrv.pancake_driver_step(owned_loop.raw, 0),
        );
    }
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
    _ = try resident.wake.nudge();
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
    try expectOk(cdrv.pancake_driver_listen(loop, "missing-listener", "missing-listener".len, "", 0, null, &listener));
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cdrv.pancake_driver_step(loop, 0),
    );
    var event: cdrv.PancakeDriverEvent = undefined;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_WOULD_BLOCK,
        cdrv.pancake_driver_next_event(loop, &event),
    );
    try std.testing.expectEqual(@as(usize, 1), resident.cancel_listen_calls);
    try std.testing.expectEqual(@as(usize, 0), resident.stop_listen_calls);
}

test "an immediate-only stream listener rejects pending ownership without a fake cancel callback" {
    var stream: MalformedImmediateStream = .{};
    const owned_loop = try newEmptyLoop(0x5d);
    defer owned_loop.deinit();
    var table = stream.table();
    try expectOk(addStreamProvider(owned_loop.raw, &table, "malformed-immediate-stream"));

    var listener: u64 = 0;
    try expectOk(cdrv.pancake_driver_listen(
        owned_loop.raw,
        "malformed-immediate-stream",
        "malformed-immediate-stream".len,
        "endpoint",
        "endpoint".len,
        null,
        &listener,
    ));
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, cdrv.pancake_driver_step(owned_loop.raw, 0));
    try std.testing.expectEqual(@as(usize, 1), stream.listener_close_calls);
}

test "closing a pending listener abandons setup without publishing a failure" {
    var resident = InvalidMultiplexedResident{
        .wake = try pancake.net.wake_channel.WakeChannel.open(),
        .pending_listen = true,
    };
    defer resident.wake.deinit();
    const owned_loop = try newEmptyLoop(0x60);
    defer owned_loop.deinit();
    var table = resident.table();
    try expectOk(addMultiplexedProvider(owned_loop.raw, &table, "pending-listener-close"));

    var listener: u64 = 0;
    try expectOk(cdrv.pancake_driver_listen(
        owned_loop.raw,
        "pending-listener-close",
        "pending-listener-close".len,
        "endpoint",
        "endpoint".len,
        null,
        &listener,
    ));
    try expectOk(cdrv.pancake_driver_listener_close(owned_loop.raw, listener));
    try std.testing.expectEqual(@as(usize, 1), resident.cancel_listen_calls);

    var event: cdrv.PancakeDriverEvent = undefined;
    try std.testing.expectEqual(c.PANCAKE_ERR_WOULD_BLOCK, cdrv.pancake_driver_next_event(owned_loop.raw, &event));
    try std.testing.expectEqual(c.PANCAKE_ERR_NOT_FOUND, cdrv.pancake_driver_listener_close(owned_loop.raw, listener));
}

test "a failed provider callback cannot publish listener ownership" {
    var resident = InvalidMultiplexedResident{
        .wake = try pancake.net.wake_channel.WakeChannel.open(),
        .listen_output_on_failure = true,
    };
    defer resident.wake.deinit();
    const owned_loop = try newLoop(0x58);
    defer owned_loop.deinit();
    const loop = owned_loop.raw;
    var table = resident.table();
    try expectOk(addMultiplexedProvider(loop, &table, "failed-output"));

    var listener: u64 = 0;
    try expectOk(cdrv.pancake_driver_listen(loop, "failed-output", "failed-output".len, "", 0, null, &listener));
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, cdrv.pancake_driver_step(loop, 0));
}

test "a malformed pending multiplexed listener retires every published owner" {
    var resident = InvalidMultiplexedResident{
        .wake = try pancake.net.wake_channel.WakeChannel.open(),
        .pending_listen_with_stream_fields = true,
    };
    defer resident.wake.deinit();
    const owned_loop = try newLoop(0x59);
    defer owned_loop.deinit();
    const loop = owned_loop.raw;
    var table = resident.table();
    try expectOk(addMultiplexedProvider(loop, &table, "malformed-pending"));

    var listener: u64 = 0;
    try expectOk(cdrv.pancake_driver_listen(loop, "malformed-pending", "malformed-pending".len, "", 0, null, &listener));
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, cdrv.pancake_driver_step(loop, 0));
    try std.testing.expectEqual(@as(usize, 1), resident.cancel_listen_calls);
    try std.testing.expectEqual(@as(usize, 1), resident.stop_listen_calls);
}

test "the TCP archive installs its complete profile package atomically" {
    const owned_loop = try newLoop(0x39);
    defer owned_loop.deinit();
    const loop = owned_loop.raw;

    var duplicate_tcp: ?*ctcp.PancakeTcpNetlayer = null;
    try expectOk(ctcp.pancake_tcp_netlayer_new(&default_tcp_config, &duplicate_tcp));
    defer ctcp.pancake_tcp_netlayer_release(duplicate_tcp);
    var duplicate: cdrv.PancakeTransportProvider = undefined;
    try expectOk(ctcp.pancake_tcp_transport_provider(duplicate_tcp, &duplicate));
    try expectOk(cdrv.pancake_driver_add_provider(loop, &duplicate));

    const conflicting_config: ctcp.PancakeTcpConfig = .{ .stream = .{
        .keepalive_idle_sec = 30,
        .keepalive_interval_sec = 10,
        .keepalive_count = 3,
    } };
    var conflicting_tcp: ?*ctcp.PancakeTcpNetlayer = null;
    try expectOk(ctcp.pancake_tcp_netlayer_new(&conflicting_config, &conflicting_tcp));
    defer ctcp.pancake_tcp_netlayer_release(conflicting_tcp);
    var conflicting: cdrv.PancakeTransportProvider = undefined;
    try expectOk(ctcp.pancake_tcp_transport_provider(conflicting_tcp, &conflicting));
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cdrv.pancake_driver_add_provider(loop, &conflicting),
    );

    const plain_listener = try listenReady(loop, "tcp", "127.0.0.1:0");
    var restoration_len: usize = 99;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_NOT_FOUND,
        cdrv.pancake_driver_listener_restoration_state(
            loop,
            plain_listener,
            null,
            0,
            &restoration_len,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), restoration_len);
    const keyed_listener = try listenReady(loop, "keyed-tcp", "127.0.0.1:0");
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
        cdrv.pancake_driver_listen(loop, "tcp", 3, "127.0.0.1:0", 11, null, &duplicate_listener),
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

    const replacement_listener = try listenReady(loop, "tcp", "127.0.0.1:0");
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
    defer expectOk(crelay.pancake_relay_runtime_release(runtime)) catch unreachable;

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
    const listener = try listenReady(server, "tcp", "127.0.0.1:0");
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

test "driver release retires pending accepts before listener storage" {
    const owned_server = try newLoop(0x61);
    const server = owned_server.raw;
    const listener = try listenReady(server, "tcp", "127.0.0.1:0");
    try expectOk(cdrv.pancake_driver_listener_select(server, listener));
    const locator = try readListenerLocator(server, listener);
    defer pancake.ocapn.model.freePeerLocator(std.testing.allocator, locator);

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const address = try pancake.net.tcp.parseDesignator(locator.designator);
    var silent = try std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream });
    defer silent.close(io);

    try expectLoopReadable(server);
    try expectStep(cdrv.pancake_driver_step(server, 0));
    try expectOk(cdrv.pancake_driver_release(server));
}

test "an unselected listener refuses accept visibly until routing policy is selected" {
    const owned_server = try newLoop(0x3d);
    defer owned_server.deinit();
    const server = owned_server.raw;
    const listener = try listenReady(server, "tcp", "127.0.0.1:0");
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
    const listener = try listenReady(server, "tcp", "127.0.0.1:0");
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

test "driver close preserves delivered session handles until explicit release" {
    const owned_server = try newLoop(0x45);
    defer owned_server.deinit();
    const server = owned_server.raw;
    const listener = try listenReady(server, "tcp", "127.0.0.1:0");
    try expectOk(cdrv.pancake_driver_listener_select(server, listener));
    const locator = try readListenerLocator(server, listener);
    defer pancake.ocapn.model.freePeerLocator(std.testing.allocator, locator);

    const owned_client = try newLoop(0x46);
    defer owned_client.deinit();
    const client = owned_client.raw;
    var ticket: u64 = 0;
    try expectOk(try dialParts(client, "tcp", locator.designator, "", &ticket));

    var client_seen = Drained{};
    var server_seen = Drained{};
    var rounds: usize = 0;
    while ((client_seen.dialed_session == null or server_seen.accepted_session == null) and rounds < 2_000) : (rounds += 1) {
        try expectStep(cdrv.pancake_driver_step(client, 5));
        try drainEvents(client, &client_seen);
        try expectStep(cdrv.pancake_driver_step(server, 5));
        try drainEvents(server, &server_seen);
    }
    try std.testing.expect(client_seen.dialed_session != null);
    try std.testing.expect(server_seen.accepted_session != null);
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cd.pancake_host_session_break_far_vows(client_seen.dialed_session, "stale embedder", 14),
    );

    try expectOk(cdrv.pancake_driver_close(client, &close_cancel));
    try expectOk(cdrv.pancake_driver_close(server, &close_cancel));
    try expectStep(cdrv.pancake_driver_step(client, 0));
    try expectStep(cdrv.pancake_driver_step(server, 0));
    try drainEvents(client, &client_seen);
    try drainEvents(server, &server_seen);

    var state: u32 = undefined;
    try expectOk(cdrv.pancake_driver_lifecycle_state(client, &state));
    try std.testing.expectEqual(cd.PANCAKE_LIFECYCLE_CLOSED, state);
    try expectOk(cdrv.pancake_driver_lifecycle_state(server, &state));
    try std.testing.expectEqual(cd.PANCAKE_LIFECYCLE_CLOSED, state);

    try expectOk(cdrv.pancake_driver_session_release(client, client_seen.dialed_session));
    try expectOk(cdrv.pancake_driver_session_release(server, server_seen.accepted_session));
}

test "driver retirement preserves claimed sessions and owns the final release transition" {
    const owned_server = try newLoop(0x65);
    defer owned_server.deinit();
    const server = owned_server.raw;
    const listener = try listenReady(server, "tcp", "127.0.0.1:0");
    try expectOk(cdrv.pancake_driver_listener_select(server, listener));
    const locator = try readListenerLocator(server, listener);
    defer pancake.ocapn.model.freePeerLocator(std.testing.allocator, locator);

    const owned_client = try newLoop(0x66);
    defer owned_client.deinit();
    const client = owned_client.raw;
    var ticket: u64 = 0;
    try expectOk(try dialParts(client, "tcp", locator.designator, "", &ticket));

    var client_seen = Drained{};
    var server_seen = Drained{};
    var rounds: usize = 0;
    while ((client_seen.dialed_session == null or server_seen.accepted_session == null) and rounds < 2_000) : (rounds += 1) {
        try expectStep(cdrv.pancake_driver_step(client, 5));
        try drainEvents(client, &client_seen);
        try expectStep(cdrv.pancake_driver_step(server, 5));
        try drainEvents(server, &server_seen);
    }
    try std.testing.expect(client_seen.dialed_session != null);
    try std.testing.expect(server_seen.accepted_session != null);

    try expectOk(cdrv.pancake_driver_retire(server));
    var state: u32 = undefined;
    try expectOk(cdrv.pancake_driver_lifecycle_state(server, &state));
    try std.testing.expectEqual(cd.PANCAKE_LIFECYCLE_ACTIVE, state);

    var refused_listener: u64 = 0;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_CLOSED,
        cdrv.pancake_driver_listen(server, "tcp", 3, "127.0.0.1:0", 11, null, &refused_listener),
    );

    try expectOk(cdrv.pancake_driver_session_release(server, server_seen.accepted_session));
    rounds = 0;
    while (rounds < 2_000) : (rounds += 1) {
        try drainEvents(server, &server_seen);
        try expectOk(cdrv.pancake_driver_lifecycle_state(server, &state));
        if (state == cd.PANCAKE_LIFECYCLE_CLOSED) break;
        try expectStep(cdrv.pancake_driver_step(server, 0));
    }
    try std.testing.expectEqual(cd.PANCAKE_LIFECYCLE_CLOSED, state);
    try expectOk(cdrv.pancake_driver_session_release(client, client_seen.dialed_session));
}

test "driver session close reaches its transport barrier without closing the loop" {
    const owned_server = try newLoop(0x47);
    defer owned_server.deinit();
    const server = owned_server.raw;
    const listener = try listenReady(server, "tcp", "127.0.0.1:0");
    try expectOk(cdrv.pancake_driver_listener_select(server, listener));
    const locator = try readListenerLocator(server, listener);
    defer pancake.ocapn.model.freePeerLocator(std.testing.allocator, locator);

    const owned_client = try newLoop(0x48);
    defer owned_client.deinit();
    const client = owned_client.raw;
    var ticket: u64 = 0;
    try expectOk(try dialParts(client, "tcp", locator.designator, "", &ticket));

    var client_seen = Drained{};
    var server_seen = Drained{};
    var rounds: usize = 0;
    while ((client_seen.dialed_session == null or server_seen.accepted_session == null) and rounds < 2_000) : (rounds += 1) {
        try expectStep(cdrv.pancake_driver_step(client, 5));
        try drainEvents(client, &client_seen);
        try expectStep(cdrv.pancake_driver_step(server, 5));
        try drainEvents(server, &server_seen);
    }
    const client_session = client_seen.dialed_session orelse return error.DialNeverOpened;
    const server_session = server_seen.accepted_session orelse return error.AcceptNeverOpened;

    try expectOk(cdrv.pancake_driver_session_close(client, client_session, &close_cancel));
    var state: u32 = undefined;
    try expectOk(cdrv.pancake_driver_session_lifecycle_state(client, client_session, &state));
    try std.testing.expectEqual(cd.PANCAKE_LIFECYCLE_TERMINATING, state);
    try expectStep(cdrv.pancake_driver_step(client, 0));
    try expectOk(cdrv.pancake_driver_session_lifecycle_state(client, client_session, &state));
    try std.testing.expectEqual(cd.PANCAKE_LIFECYCLE_CLOSED, state);
    try drainEvents(client, &client_seen);

    try expectOk(cdrv.pancake_driver_lifecycle_state(client, &state));
    try std.testing.expectEqual(cd.PANCAKE_LIFECYCLE_ACTIVE, state);
    try expectOk(cdrv.pancake_driver_session_release(client, client_session));
    try expectOk(cdrv.pancake_driver_session_release(server, server_session));
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

    const listener_id = try listenReady(loop, "tcp", "127.0.0.1:0");
    try expectOk(cdrv.pancake_driver_listener_select(loop, listener_id));
    // A duplicate transport is refused because the Host has one advertised
    // locator per transport.
    var duplicate_listener: u64 = 0;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cdrv.pancake_driver_listen(loop, "tcp", 3, "127.0.0.1:0", 11, null, &duplicate_listener),
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
    var served_accept = false;
    while (!shared.stop.load(.acquire)) {
        try expectStep(cdrv.pancake_driver_step(loop, 20));
        try drainEvents(loop, &seen);
        if (seen.accepted) shared.accepted.store(true, .release);
        // An accepted session's inbound is held until the embedder announces
        // its setup is done; without this the client's pipelined fetch below
        // would wait forever.
        if (seen.accepted_session != null and !served_accept) {
            served_accept = true;
            try expectOk(cdrv.pancake_driver_session_serve(loop, seen.accepted_session));
        }
        if (seen.closed) {
            try std.testing.expectEqual(c.PANCAKE_OK, seen.closed_result);
            try std.testing.expectEqual(@as(usize, 0), seen.closed_message_len);
            shared.closed.store(true, .release);
        }
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
    var held_rounds: usize = 0;
    var client_served = false;
    while (client_seen.settle_ticket == 0 and rounds < 2000) : (rounds += 1) {
        try expectStep(cdrv.pancake_driver_step(client, 5));
        try drainEvents(client, &client_seen);
        if (client_seen.dialed_session != null and fetch_vow == 0) {
            try std.testing.expectEqual(ticket, client_seen.dialed_operation_id);
            try expectOk(cd.pancake_host_session_fetch(client_seen.dialed_session, "widget", 6, &fetch_vow));
        }
        // The settle answers over this session's inbound, which is held until
        // the embedder serves: a stretch of steps first, so a settle arriving
        // early would fail here and expose a hold that stopped holding.
        if (fetch_vow != 0 and !client_served) {
            held_rounds += 1;
            try std.testing.expectEqual(@as(u64, 0), client_seen.settle_ticket);
            if (held_rounds >= 20) {
                client_served = true;
                try expectOk(cdrv.pancake_driver_session_serve(client, client_seen.dialed_session));
            }
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
    const listener_id = try listenReady(server, "tcp", "127.0.0.1:0");
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
            // The serve verb is scoped the same way release is.
            try std.testing.expectEqual(
                c.PANCAKE_ERR_INVALID_ARGUMENT,
                cdrv.pancake_driver_session_serve(server, client_seen.dialed_session),
            );
            try serveBoth(client, client_seen.dialed_session, server, server_seen.accepted_session);
            try std.testing.expectEqual(ticket, client_seen.dialed_operation_id);
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

test "stream provider failure chain reaches SESSION_CLOSED exactly" {
    const owned_server = try newEmptyLoop(0x74);
    defer owned_server.deinit();
    const server = owned_server.raw;

    var tcp_handle: ?*ctcp.PancakeTcpNetlayer = null;
    try expectOk(ctcp.pancake_tcp_netlayer_new(&default_tcp_config, &tcp_handle));
    defer ctcp.pancake_tcp_netlayer_release(tcp_handle);
    var provider: cdrv.PancakeTransportProvider = undefined;
    try expectOk(ctcp.pancake_tcp_transport_provider(tcp_handle, &provider));
    try std.testing.expect(provider.entry_count <= 4);
    var entries: [4]cdrv.PancakeTransportProviderEntry = undefined;
    var tables: [4]cdrv.PancakeStreamTransport = undefined;
    for (provider.entries.?[0..provider.entry_count], 0..) |entry, i| {
        entries[i] = entry;
        try std.testing.expectEqual(cdrv.PANCAKE_TRANSPORT_EXEC_STREAM, entry.execution_model);
        const original: *const cdrv.PancakeStreamTransport = @ptrCast(@alignCast(entry.implementation.?));
        tables[i] = original.*;
        tables[i].conn_take_failure = injectedStreamConnectionFailure;
        entries[i].implementation = &tables[i];
    }
    provider.entries = &entries;
    try expectOk(cdrv.pancake_driver_add_provider(server, &provider));

    const listener = try listenReady(server, "tcp", "127.0.0.1:0");
    try expectOk(cdrv.pancake_driver_listener_select(server, listener));
    const locator = try readListenerLocator(server, listener);
    defer pancake.ocapn.model.freePeerLocator(std.testing.allocator, locator);

    const owned_client = try newLoop(0x75);
    defer owned_client.deinit();
    const client = owned_client.raw;
    var operation: u64 = 0;
    try expectOk(try dialParts(client, "tcp", locator.designator, "", &operation));
    var client_seen = Drained{};
    var server_seen = Drained{};
    var rounds: usize = 0;
    while ((client_seen.dialed_session == null or !server_seen.accepted) and rounds < 2_000) : (rounds += 1) {
        try expectStep(cdrv.pancake_driver_step(client, 5));
        try drainEvents(client, &client_seen);
        try expectStep(cdrv.pancake_driver_step(server, 5));
        try drainEvents(server, &server_seen);
    }
    try std.testing.expect(client_seen.dialed_session != null);
    try std.testing.expect(server_seen.accepted_session != null);
    try serveBoth(client, client_seen.dialed_session, server, server_seen.accepted_session);
    try expectOk(cdrv.pancake_driver_session_release(client, client_seen.dialed_session));

    rounds = 0;
    while (!server_seen.closed and rounds < 2_000) : (rounds += 1) {
        try expectStep(cdrv.pancake_driver_step(server, 5));
        try drainEvents(server, &server_seen);
    }
    try std.testing.expect(server_seen.closed);
    try std.testing.expectEqual(c.PANCAKE_ERR_IO, server_seen.closed_result);
    try std.testing.expectEqualStrings(
        "InjectedStreamReadFailure",
        server_seen.closed_message[0..server_seen.closed_message_len],
    );
    try std.testing.expectEqual(c.PANCAKE_ERR_INTERNAL, server_seen.closed_secondary_result);
    try std.testing.expectEqual(@as(u32, 2), server_seen.closed_secondary_count);
    try std.testing.expectEqualStrings(
        "InjectedStreamCleanupFailure",
        server_seen.closed_secondary_message[0..server_seen.closed_secondary_message_len],
    );
    try expectStep(cdrv.pancake_driver_step(server, 0));
    try drainEvents(server, &server_seen);
    try std.testing.expectEqual(@as(usize, 1), server_seen.closed_count);
    try expectOk(cdrv.pancake_driver_session_release(server, server_seen.accepted_session));
}

test "loop-owned session release refuses callback reentry before dropping the wire" {
    const owned_server = try newLoop(0x5f);
    defer owned_server.deinit();
    const server = owned_server.raw;
    const listener = try listenReady(server, "tcp", "127.0.0.1:0");
    try expectOk(cdrv.pancake_driver_listener_select(server, listener));
    const locator = try readListenerLocator(server, listener);
    defer pancake.ocapn.model.freePeerLocator(std.testing.allocator, locator);

    var release = ReentrantSessionRelease{ .loop = server, .listener = listener };
    try expectOk(cd.pancake_host_publish(
        owned_server.host,
        "release-probe",
        "release-probe".len,
        reentrantSessionReleaseBehavior,
        &release,
        null,
    ));

    const owned_client = try newLoop(0x60);
    defer owned_client.deinit();
    const client = owned_client.raw;
    var operation: u64 = 0;
    try expectOk(try dialParts(client, "tcp", locator.designator, "", &operation));

    var client_seen = Drained{};
    var server_seen = Drained{};
    for (0..2_000) |_| {
        try expectStep(cdrv.pancake_driver_step(client, 5));
        try drainEvents(client, &client_seen);
        try expectStep(cdrv.pancake_driver_step(server, 5));
        try drainEvents(server, &server_seen);
        if (client_seen.dialed_session != null and server_seen.accepted_session != null) break;
    }
    try std.testing.expect(client_seen.dialed_session != null);
    try std.testing.expect(server_seen.accepted_session != null);
    try serveBoth(client, client_seen.dialed_session, server, server_seen.accepted_session);
    release.session = server_seen.accepted_session;

    var fetch_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_fetch(
        client_seen.dialed_session,
        "release-probe",
        "release-probe".len,
        &fetch_vow,
    ));
    for (0..2_000) |_| {
        try expectStep(cdrv.pancake_driver_step(client, 5));
        try drainEvents(client, &client_seen);
        try expectStep(cdrv.pancake_driver_step(server, 5));
        try drainEvents(server, &server_seen);
        if (client_seen.settle_ticket == fetch_vow) break;
    }
    try std.testing.expectEqual(fetch_vow, client_seen.settle_ticket);
    try std.testing.expect(client_seen.settled_reference.id != 0);

    client_seen.settle_ticket = 0;
    var call_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_send(
        client_seen.dialed_session,
        &client_seen.settled_reference,
        "probe",
        "probe".len,
        null,
        0,
        &call_vow,
    ));
    for (0..2_000) |_| {
        try expectStep(cdrv.pancake_driver_step(client, 5));
        try drainEvents(client, &client_seen);
        try expectStep(cdrv.pancake_driver_step(server, 5));
        try drainEvents(server, &server_seen);
        if (client_seen.settle_ticket == call_vow) break;
    }

    try std.testing.expect(release.ran);
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, release.result);
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, release.readiness_result);
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, release.restoration_result);
    try std.testing.expectEqual(call_vow, client_seen.settle_ticket);
    try expectOk(cdrv.pancake_driver_session_release(client, client_seen.dialed_session));
    try expectOk(cdrv.pancake_driver_session_release(server, server_seen.accepted_session));
}

test "driver retirement requested in a behavior defers listener effects until callback unwind" {
    const owned_server = try newLoop(0x67);
    defer owned_server.deinit();
    const server = owned_server.raw;
    const listener = try listenReady(server, "tcp", "127.0.0.1:0");
    try expectOk(cdrv.pancake_driver_listener_select(server, listener));
    const locator = try readListenerLocator(server, listener);
    defer pancake.ocapn.model.freePeerLocator(std.testing.allocator, locator);

    var retirement = CallbackRetirement{ .loop = server };
    try expectOk(cd.pancake_host_publish(
        owned_server.host,
        "retirement-probe",
        "retirement-probe".len,
        callbackRetirementBehavior,
        &retirement,
        null,
    ));

    const owned_client = try newLoop(0x68);
    defer owned_client.deinit();
    const client = owned_client.raw;
    var operation: u64 = 0;
    try expectOk(try dialParts(client, "tcp", locator.designator, "", &operation));

    var client_seen = Drained{};
    var server_seen = Drained{};
    for (0..2_000) |_| {
        try expectStep(cdrv.pancake_driver_step(client, 5));
        try drainEvents(client, &client_seen);
        try expectStep(cdrv.pancake_driver_step(server, 5));
        try drainEvents(server, &server_seen);
        if (client_seen.dialed_session != null and server_seen.accepted_session != null) break;
    }
    try std.testing.expect(client_seen.dialed_session != null);
    try std.testing.expect(server_seen.accepted_session != null);
    try serveBoth(client, client_seen.dialed_session, server, server_seen.accepted_session);

    var fetch_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_fetch(
        client_seen.dialed_session,
        "retirement-probe",
        "retirement-probe".len,
        &fetch_vow,
    ));
    for (0..2_000) |_| {
        try expectStep(cdrv.pancake_driver_step(client, 5));
        try drainEvents(client, &client_seen);
        try expectStep(cdrv.pancake_driver_step(server, 5));
        try drainEvents(server, &server_seen);
        if (client_seen.settle_ticket == fetch_vow) break;
    }
    try std.testing.expectEqual(fetch_vow, client_seen.settle_ticket);

    client_seen.settle_ticket = 0;
    var call_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_send(
        client_seen.dialed_session,
        &client_seen.settled_reference,
        "retire",
        "retire".len,
        null,
        0,
        &call_vow,
    ));
    for (0..2_000) |_| {
        try expectStep(cdrv.pancake_driver_step(client, 5));
        try drainEvents(client, &client_seen);
        try expectStep(cdrv.pancake_driver_step(server, 5));
        try drainEvents(server, &server_seen);
        if (client_seen.settle_ticket == call_vow) break;
    }

    try std.testing.expect(retirement.ran);
    try std.testing.expectEqual(c.PANCAKE_OK, retirement.result);
    try std.testing.expectEqual(call_vow, client_seen.settle_ticket);
    var stale_locator: cdrv.PancakeLocatorView = undefined;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_NOT_FOUND,
        cdrv.pancake_driver_listener_locator(server, listener, &stale_locator),
    );

    try expectOk(cdrv.pancake_driver_session_release(server, server_seen.accepted_session));
    try expectOk(cdrv.pancake_driver_session_release(client, client_seen.dialed_session));
}

test "keyed-tcp is available at loop construction and retains unauthenticated provenance" {
    const owned_server = try newLoop(0x48);
    defer owned_server.deinit();
    const server = owned_server.raw;

    const listener_id = try listenReady(server, "keyed-tcp", "127.0.0.1:0");
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

    const listener_id = try listenReady(server, "noise-tcp", "127.0.0.1:0");
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
            try serveBoth(client, client_seen.dialed_session, server, server_seen.accepted_session);
            try std.testing.expectEqual(ticket, client_seen.dialed_operation_id);
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
        const server_relay_config: crelay.PancakeRelayConfig = .{
            .relay_url = relay_url.ptr,
            .relay_url_len = relay_url.len,
            .register_url = register_url.ptr,
            .register_url_len = register_url.len,
        };
        var server_relay_runtime: ?*crelay.PancakeRelayRuntime = null;
        try expectOk(crelay.pancake_relay_runtime_new(&server_relay_config, &server_relay_runtime));
        defer expectOk(crelay.pancake_relay_runtime_release(server_relay_runtime)) catch unreachable;
        var server_provider: cdrv.PancakeTransportProvider = undefined;
        try expectOk(crelay.pancake_relay_transport_provider(server_relay_runtime, &server_provider));
        try std.testing.expect(server_provider.entry_count <= 4);
        var server_entries: [4]cdrv.PancakeTransportProviderEntry = undefined;
        const original_table: *const cdrv.PancakeMultiplexedTransport = @ptrCast(@alignCast(server_provider.entries.?[0].implementation.?));
        var server_table = original_table.*;
        server_table.conn_take_failure = injectedMultiplexedConnectionFailure;
        for (server_provider.entries.?[0..server_provider.entry_count], 0..) |entry, i| {
            server_entries[i] = entry;
            try std.testing.expectEqual(cdrv.PANCAKE_TRANSPORT_EXEC_MULTIPLEXED, entry.execution_model);
            const original: *const cdrv.PancakeMultiplexedTransport = @ptrCast(@alignCast(entry.implementation.?));
            try std.testing.expectEqual(original_table, original);
            // All profiles in this package deliberately share one resident.
            // Preserve that identity while replacing the one callback under
            // test; distinct copied table addresses would falsely describe
            // distinct resident owners to the registry.
            server_entries[i].implementation = &server_table;
        }
        server_provider.entries = &server_entries;
        try expectOk(cdrv.pancake_driver_add_provider(owned_server.raw, &server_provider));
        const listener_id = try listenReady(owned_server.raw, "noise-relay", "");
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
                try serveBoth(owned_client.raw, client_seen.dialed_session, owned_server.raw, server_seen.accepted_session);
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
        rounds = 0;
        while (!server_seen.closed and rounds < 2_000) : (rounds += 1) {
            try expectStep(cdrv.pancake_driver_step(owned_server.raw, 5));
            try drainEvents(owned_server.raw, &server_seen);
        }
        try std.testing.expect(server_seen.closed);
        try std.testing.expectEqual(c.PANCAKE_ERR_IO, server_seen.closed_result);
        try std.testing.expectEqualStrings(
            "InjectedMultiplexedReadFailure",
            server_seen.closed_message[0..server_seen.closed_message_len],
        );
        try std.testing.expectEqual(c.PANCAKE_ERR_INTERNAL, server_seen.closed_secondary_result);
        try std.testing.expectEqual(@as(u32, 2), server_seen.closed_secondary_count);
        try std.testing.expectEqualStrings(
            "InjectedMultiplexedCleanupFailure",
            server_seen.closed_secondary_message[0..server_seen.closed_secondary_message_len],
        );
        try expectStep(cdrv.pancake_driver_step(owned_server.raw, 0));
        try drainEvents(owned_server.raw, &server_seen);
        try std.testing.expectEqual(@as(usize, 1), server_seen.closed_count);
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

fn releaseFromForeignThread(loop: ?*cdrv.PancakeDriverLoop, result: *std.atomic.Value(i32)) void {
    result.store(cdrv.pancake_driver_release(loop), .release);
}

test "a foreign-thread driver release is a nonfatal refusal" {
    const owned_loop = try newLoop(0x34);
    var loop_live = true;
    defer if (loop_live) owned_loop.deinit();

    // Claim the Host on this thread. A foreign finalizer or consumer cannot
    // silently transfer a live loop; it receives a retryable refusal and the
    // owning thread retains the deterministic release barrier.
    try expectOk(cd.pancake_host_publish(owned_loop.host, "widget", 6, widgetBehavior, null, null));
    var result = std.atomic.Value(i32).init(c.PANCAKE_OK);
    const worker = try std.Thread.spawn(.{}, releaseFromForeignThread, .{ owned_loop.raw, &result });
    worker.join();

    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, result.load(.acquire));
    try expectOk(cdrv.pancake_driver_release(owned_loop.raw));
    loop_live = false;
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
    try expectOk(cdrv.pancake_driver_listen(loop, "tcp", 3, "127.0.0.1:0", 11, null, &listener_id));
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
    var refused_operation_id: u64 = 99;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_WOULD_BLOCK,
        try dialParts(loop, "async-fail", "other", "", &refused_operation_id),
    );
    try std.testing.expectEqual(@as(u64, 99), refused_operation_id);
    counting.fail_allocations = true;
    const step_rc = cdrv.pancake_driver_step(loop, 10);
    counting.fail_allocations = false;
    try expectOk(step_rc);

    var event: cdrv.PancakeDriverEvent = undefined;
    try expectOk(cdrv.pancake_driver_next_event(loop, &event));
    try std.testing.expectEqual(cdrv.PANCAKE_DRIVER_EVENT_OPEN_FAILED, event.kind);
    try std.testing.expectEqual(ticket, event.operation_id);
    try std.testing.expectEqualStrings("ForcedAsyncDialFailure", event.primary_name.?[0..event.primary_name_len]);
    try std.testing.expectEqual(c.PANCAKE_ERR_INTERNAL, event.secondary_result);
    try std.testing.expectEqualStrings("ForcedDialCleanupFailure", event.secondary_name.?[0..event.secondary_name_len]);
    try std.testing.expectEqual(@as(u32, 2), event.secondary_count);
    try std.testing.expectEqual(
        c.PANCAKE_ERR_WOULD_BLOCK,
        cdrv.pancake_driver_next_event(loop, &event),
    );
    var retry_operation_id: u64 = 0;
    try expectOk(try dialParts(loop, "async-fail", "retry", "", &retry_operation_id));
    try expectOk(cdrv.pancake_driver_release(loop));
    c.pancake_context_release(ctx);
    try std.testing.expect(counting.balanced());
}
