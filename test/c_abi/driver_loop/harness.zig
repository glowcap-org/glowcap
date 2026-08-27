//! The stepping-loop harness the `libpancake_driver` suite drives: loop
//! construction with pinned options, provider installation, listener locators
//! and dial parts, the event drain, and readiness waits. No test lives here.

const std = @import("std");

const c = @import("c_abi");
const cshared = @import("c_abi_shared");
const cd = @import("c_abi_host");
const cdrv = @import("c_abi_driver");
const crelay = @import("c_abi_net_transport_relay");
const ctcp = @import("c_abi_net_transport_tcp");
const pancake = @import("pancake");

const ws_relay = @import("../../support/ws_relay.zig");
const host_harness = @import("../host/harness.zig");

/// The byte-fed Host harness owns these; the loop harness only adds what a
/// stepping loop needs on top of an accepted session.
pub const sessionLimitOptions = host_harness.sessionLimitOptions;
pub const openAccepted = host_harness.openAccepted;
pub const hostSeed = host_harness.hostSeed;

pub const frame_cap: usize = 4096;

pub fn closeListener(loop: ?*cdrv.PancakeDriverLoop, listener: u64) i32 {
    var failure = cdrv.PancakeDriverFailure.init();
    return cdrv.pancake_driver_listener_close(loop, listener, &failure);
}

pub const default_tcp_config: ctcp.PancakeTcpConfig = .{ .stream = .{
    .keepalive_idle_sec = 0,
    .keepalive_interval_sec = 0,
    .keepalive_count = 0,
} };

pub const driver_options_1s: cdrv.PancakeDriverOptions = .{
    .abi_version = cdrv.PANCAKE_DRIVER_OPTIONS_ABI_VERSION,
    .struct_size = @sizeOf(cdrv.PancakeDriverOptions),
    .wire_buffer_bytes = 1024,
    .max_pending_opens = 256,
    .handshake_ms = 1_000,
    .listener_setup_ms = 1_000,
    .settle_ms = 1_000,
};

pub const driver_options_10s: cdrv.PancakeDriverOptions = .{
    .abi_version = cdrv.PANCAKE_DRIVER_OPTIONS_ABI_VERSION,
    .struct_size = @sizeOf(cdrv.PancakeDriverOptions),
    .wire_buffer_bytes = 1024,
    .max_pending_opens = 256,
    .handshake_ms = 10_000,
    .listener_setup_ms = 10_000,
    .settle_ms = 10_000,
};

pub const driver_options_cap1: cdrv.PancakeDriverOptions = .{
    .abi_version = cdrv.PANCAKE_DRIVER_OPTIONS_ABI_VERSION,
    .struct_size = @sizeOf(cdrv.PancakeDriverOptions),
    .wire_buffer_bytes = 1024,
    .max_pending_opens = 1,
    .handshake_ms = 1_000,
    .listener_setup_ms = 1_000,
    .settle_ms = 1_000,
};

pub const close_cancel: cdrv.PancakeCloseOptions = .{
    .abi_version = cdrv.PANCAKE_CLOSE_OPTIONS_ABI_VERSION,
    .struct_size = @sizeOf(cdrv.PancakeCloseOptions),
    .pending = cd.PANCAKE_PENDING_CANCEL,
    .grace_mode = cdrv.PANCAKE_CLOSE_GRACE_UNSPECIFIED,
    .grace_ms = 0,
};

pub fn providerFailure(out: ?*cdrv.PancakeProviderFailure, code: i32, primary: []const u8) i32 {
    const report = out orelse return code;
    report.* = cshared.transport_provider.emptyProviderFailure();
    report.result = code;
    report.primary_name = primary.ptr;
    report.primary_name_len = primary.len;
    return code;
}

pub fn drained(out_count: ?*usize, count: usize) i32 {
    out_count.?.* = count;
    return c.PANCAKE_OK;
}

pub fn expectOk(rc: i32) !void {
    try std.testing.expectEqual(c.PANCAKE_OK, rc);
}

pub fn expectStep(rc: i32) !void {
    try std.testing.expect(rc == c.PANCAKE_OK or rc == c.PANCAKE_ERR_WOULD_BLOCK);
}

pub fn releaseLoop(loop: ?*cdrv.PancakeDriverLoop) i32 {
    var failure = cdrv.PancakeDriverFailure.init();
    return cdrv.pancake_driver_release(loop, &failure);
}

pub fn addProvider(
    loop: ?*cdrv.PancakeDriverLoop,
    provider: ?*const cdrv.PancakeTransportProvider,
) i32 {
    var failure = cdrv.PancakeDriverFailure.init();
    return cdrv.pancake_driver_add_provider(loop, provider, &failure);
}

pub fn retainStaticProvider(_: ?*anyopaque, _: ?*cdrv.PancakeProviderFailure) callconv(.c) i32 {
    return c.PANCAKE_OK;
}

pub fn releaseStaticProvider(_: ?*anyopaque, _: ?*cdrv.PancakeProviderFailure) callconv(.c) i32 {
    return c.PANCAKE_OK;
}

pub fn sameStaticProvider(ctx: ?*anyopaque, other_ctx: ?*anyopaque) callconv(.c) u8 {
    return @intFromBool(ctx == other_ctx);
}

pub fn providerProfile(name: []const u8) cdrv.PancakeTransportProfile {
    return .{
        .abi_version = cdrv.PANCAKE_TRANSPORT_PROFILE_ABI_VERSION,
        .struct_size = @sizeOf(cdrv.PancakeTransportProfile),
        .transport_name = name.ptr,
        .transport_name_len = name.len,
        .designator_scheme = cdrv.PANCAKE_DESIGNATOR_SCHEME_ADDRESS,
        .sealed_channel = cdrv.PANCAKE_SEALED_CHANNEL_NONE,
        .wire_framing = cdrv.PANCAKE_WIRE_FRAMING_BYTE_STREAM,
        .max_packet_bytes = 0,
    };
}

pub fn addMultiplexedProviderWithProfile(
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
    return addProvider(loop, &provider);
}

pub fn addMultiplexedProvider(loop: ?*cdrv.PancakeDriverLoop, resident: *const cdrv.PancakeMultiplexedTransport, name: []const u8) i32 {
    const profile = providerProfile(name);
    return addMultiplexedProviderWithProfile(loop, resident, &profile);
}

pub fn addStreamProvider(
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
    return addProvider(loop, &provider);
}

pub fn readListenerLocator(loop: ?*cdrv.PancakeDriverLoop, listener: u64) !pancake.ocapn.model.PeerLocator {
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

pub fn expectLoopReadable(loop: ?*cdrv.PancakeDriverLoop) !void {
    var fd: i32 = -1;
    try expectOk(cdrv.pancake_driver_readiness_fd(loop, &fd));
    var fds = [_]std.posix.pollfd{
        .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 },
    };
    try std.testing.expectEqual(@as(usize, 1), try std.posix.poll(&fds, 1_000));
}

pub fn directAddresses(locator: pancake.ocapn.model.PeerLocator) ?[]const u8 {
    for (locator.hints.entries) |entry| {
        if (!std.mem.eql(u8, entry.name, pancake.ocapn.model.transport.hint_direct_addresses)) continue;
        return switch (entry.value) {
            .string => |value| value,
            else => null,
        };
    }
    return null;
}

pub fn callWithLocator(
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

pub fn dialParts(loop: ?*cdrv.PancakeDriverLoop, transport: []const u8, designator: []const u8, direct: []const u8, out_operation_id: *u64) !i32 {
    const Context = struct { loop: ?*cdrv.PancakeDriverLoop, operation_id: *u64 };
    return callWithLocator(transport, designator, direct, Context{ .loop = loop, .operation_id = out_operation_id }, struct {
        fn call(ctx: Context, locator: *const cdrv.PancakeLocatorView) i32 {
            return cdrv.pancake_driver_dial(ctx.loop, locator, null, ctx.operation_id);
        }
    }.call);
}

pub fn dialLocator(
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

pub fn advertiseParts(loop: ?*cdrv.PancakeDriverLoop, listener: u64, transport: []const u8, designator: []const u8, direct: []const u8) !i32 {
    const Context = struct { loop: ?*cdrv.PancakeDriverLoop, listener: u64 };
    return callWithLocator(transport, designator, direct, Context{ .loop = loop, .listener = listener }, struct {
        fn call(ctx: Context, locator: *const cdrv.PancakeLocatorView) i32 {
            return cdrv.pancake_driver_listener_advertise(ctx.loop, ctx.listener, locator);
        }
    }.call);
}

pub const TestLoop = struct {
    raw: ?*cdrv.PancakeDriverLoop,
    host: ?*cd.PancakeHost,

    pub fn deinit(self: TestLoop) void {
        _ = releaseLoop(self.raw);
    }
};

pub fn installTcp(loop: ?*cdrv.PancakeDriverLoop) !void {
    var tcp: ?*ctcp.PancakeTcpNetlayer = null;
    try expectOk(ctcp.pancake_tcp_netlayer_new(&default_tcp_config, &tcp));
    defer ctcp.pancake_tcp_netlayer_release(tcp);
    var provider: cdrv.PancakeTransportProvider = undefined;
    try expectOk(ctcp.pancake_tcp_transport_provider(tcp, &provider));
    try expectOk(addProvider(loop, &provider));
}

pub fn installRelay(
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
    defer expectOk(crelay.pancake_relay_runtime_release(runtime, null, 0, null)) catch unreachable;
    var provider: cdrv.PancakeTransportProvider = undefined;
    try expectOk(crelay.pancake_relay_transport_provider(runtime, &provider));
    try expectOk(addProvider(loop, &provider));
}

pub fn newEmptyLoop(seed_byte: u8) !TestLoop {
    const host = try newByteFedHost(seed_byte);
    errdefer _ = cd.pancake_host_release(host);
    var loop: ?*cdrv.PancakeDriverLoop = null;
    try expectOk(cdrv.pancake_driver_take_host(host, &driver_options_10s, &loop));
    errdefer _ = releaseLoop(loop);
    return .{ .raw = loop, .host = host };
}

pub fn newLoop(seed_byte: u8) !TestLoop {
    const owned = try newEmptyLoop(seed_byte);
    errdefer owned.deinit();
    const loop = owned.raw;
    try installTcp(loop);
    return owned;
}

pub fn newByteFedHost(seed_byte: u8) !?*cd.PancakeHost {
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

/// What one loop's drained events amounted to; scalar facts only, because a
/// COMPLETION's views die at the next `pancake_driver_next_event`.
pub const Drained = struct {
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
pub fn serveBoth(
    client: ?*cdrv.PancakeDriverLoop,
    client_session: ?*cd.PancakeHostSession,
    server: ?*cdrv.PancakeDriverLoop,
    server_session: ?*cd.PancakeHostSession,
) !void {
    try expectOk(cdrv.pancake_driver_session_serve(client, client_session));
    try expectOk(cdrv.pancake_driver_session_serve(server, server_session));
}

pub fn drainEvents(loop: ?*cdrv.PancakeDriverLoop, into: *Drained) !void {
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

pub fn awaitListenerReady(loop: ?*cdrv.PancakeDriverLoop, listener: u64) !void {
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

pub fn listenReady(
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
