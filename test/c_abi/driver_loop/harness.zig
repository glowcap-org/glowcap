//! The stepping-loop harness the `libglowcap_driver` suite drives: loop
//! construction with pinned options, provider installation, listener locators
//! and dial parts, the event drain, and readiness waits. No test lives here.

const std = @import("std");

const c = @import("c_abi");
const cshared = @import("c_abi_shared");
const cd = @import("c_abi_host");
const cdrv = @import("c_abi_driver");
const crelay = @import("c_abi_net_transport_relay");
const ctcp = @import("c_abi_net_transport_tcp");
const glowcap = @import("glowcap");

const ws_relay = @import("../../support/ws_relay.zig");
const host_harness = @import("../host/harness.zig");

/// The byte-fed Host harness owns these; the loop harness only adds what a
/// stepping loop needs on top of an accepted session.
pub const sessionLimitOptions = host_harness.sessionLimitOptions;
pub const openAccepted = host_harness.openAccepted;
pub const hostSeed = host_harness.hostSeed;

pub const frame_cap: usize = 4096;

pub fn closeListener(loop: ?*cdrv.GlowcapDriverLoop, listener: u64) i32 {
    var failure = cdrv.GlowcapDriverFailure.init();
    return cdrv.glowcap_driver_listener_close(loop, listener, &failure);
}

pub const default_tcp_config: ctcp.GlowcapTcpConfig = .{ .stream = .{
    .keepalive_idle_sec = 0,
    .keepalive_interval_sec = 0,
    .keepalive_count = 0,
} };

pub const driver_options_1s: cdrv.GlowcapDriverOptions = .{
    .abi_version = cdrv.GLOWCAP_DRIVER_OPTIONS_ABI_VERSION,
    .struct_size = @sizeOf(cdrv.GlowcapDriverOptions),
    .wire_buffer_bytes = 1024,
    .max_pending_opens = 256,
    .handshake_ms = 1_000,
    .listener_setup_ms = 1_000,
    .settle_ms = 1_000,
};

pub const driver_options_10s: cdrv.GlowcapDriverOptions = .{
    .abi_version = cdrv.GLOWCAP_DRIVER_OPTIONS_ABI_VERSION,
    .struct_size = @sizeOf(cdrv.GlowcapDriverOptions),
    .wire_buffer_bytes = 1024,
    .max_pending_opens = 256,
    .handshake_ms = 10_000,
    .listener_setup_ms = 10_000,
    .settle_ms = 10_000,
};

pub const driver_options_cap1: cdrv.GlowcapDriverOptions = .{
    .abi_version = cdrv.GLOWCAP_DRIVER_OPTIONS_ABI_VERSION,
    .struct_size = @sizeOf(cdrv.GlowcapDriverOptions),
    .wire_buffer_bytes = 1024,
    .max_pending_opens = 1,
    .handshake_ms = 1_000,
    .listener_setup_ms = 1_000,
    .settle_ms = 1_000,
};

pub const close_cancel: cdrv.GlowcapCloseOptions = .{
    .abi_version = cdrv.GLOWCAP_CLOSE_OPTIONS_ABI_VERSION,
    .struct_size = @sizeOf(cdrv.GlowcapCloseOptions),
    .pending = cd.GLOWCAP_PENDING_CANCEL,
    .grace_mode = cdrv.GLOWCAP_CLOSE_GRACE_UNSPECIFIED,
    .grace_ms = 0,
};

pub fn providerFailure(out: ?*cdrv.GlowcapProviderFailure, code: i32, primary: []const u8) i32 {
    const report = out orelse return code;
    report.* = cshared.transport_provider.emptyProviderFailure();
    report.result = code;
    report.primary_name = primary.ptr;
    report.primary_name_len = primary.len;
    return code;
}

pub fn drained(out_count: ?*usize, count: usize) i32 {
    out_count.?.* = count;
    return c.GLOWCAP_OK;
}

pub fn expectOk(rc: i32) !void {
    try std.testing.expectEqual(c.GLOWCAP_OK, rc);
}

pub fn expectStep(rc: i32) !void {
    try std.testing.expect(rc == c.GLOWCAP_OK or rc == c.GLOWCAP_ERR_WOULD_BLOCK);
}

pub fn releaseLoop(loop: ?*cdrv.GlowcapDriverLoop) i32 {
    var failure = cdrv.GlowcapDriverFailure.init();
    return cdrv.glowcap_driver_release(loop, &failure);
}

pub fn addProvider(
    loop: ?*cdrv.GlowcapDriverLoop,
    provider: ?*const cdrv.GlowcapTransportProvider,
) i32 {
    var failure = cdrv.GlowcapDriverFailure.init();
    return cdrv.glowcap_driver_add_provider(loop, provider, &failure);
}

pub fn retainStaticProvider(_: ?*anyopaque, _: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
    return c.GLOWCAP_OK;
}

pub fn releaseStaticProvider(_: ?*anyopaque, _: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
    return c.GLOWCAP_OK;
}

pub fn sameStaticProvider(ctx: ?*anyopaque, other_ctx: ?*anyopaque) callconv(.c) u8 {
    return @intFromBool(ctx == other_ctx);
}

pub fn providerProfile(name: []const u8) cdrv.GlowcapTransportProfile {
    return .{
        .abi_version = cdrv.GLOWCAP_TRANSPORT_PROFILE_ABI_VERSION,
        .struct_size = @sizeOf(cdrv.GlowcapTransportProfile),
        .transport_name = name.ptr,
        .transport_name_len = name.len,
        .designator_scheme = cdrv.GLOWCAP_DESIGNATOR_SCHEME_ADDRESS,
        .sealed_channel = cdrv.GLOWCAP_SEALED_CHANNEL_NONE,
        .wire_framing = cdrv.GLOWCAP_WIRE_FRAMING_BYTE_STREAM,
        .max_packet_bytes = 0,
    };
}

pub fn addMultiplexedProviderWithProfile(
    loop: ?*cdrv.GlowcapDriverLoop,
    resident: *const cdrv.GlowcapMultiplexedTransport,
    profile: *const cdrv.GlowcapTransportProfile,
) i32 {
    const entry: cdrv.GlowcapTransportProviderEntry = .{
        .profile = profile,
        .execution_model = cdrv.GLOWCAP_TRANSPORT_EXEC_MULTIPLEXED,
        .implementation = resident,
    };
    const provider: cdrv.GlowcapTransportProvider = .{
        .abi_version = cdrv.GLOWCAP_TRANSPORT_PROVIDER_ABI_VERSION,
        .struct_size = @sizeOf(cdrv.GlowcapTransportProvider),
        .entries = @ptrCast(&entry),
        .entry_count = 1,
        .lease_ctx = @constCast(resident),
        .same_configuration = sameStaticProvider,
        .retain = retainStaticProvider,
        .release = releaseStaticProvider,
    };
    return addProvider(loop, &provider);
}

pub fn addMultiplexedProvider(loop: ?*cdrv.GlowcapDriverLoop, resident: *const cdrv.GlowcapMultiplexedTransport, name: []const u8) i32 {
    const profile = providerProfile(name);
    return addMultiplexedProviderWithProfile(loop, resident, &profile);
}

pub fn addStreamProvider(
    loop: ?*cdrv.GlowcapDriverLoop,
    stream: *const cdrv.GlowcapStreamTransport,
    name: []const u8,
) i32 {
    const profile = providerProfile(name);
    const entry: cdrv.GlowcapTransportProviderEntry = .{
        .profile = &profile,
        .execution_model = cdrv.GLOWCAP_TRANSPORT_EXEC_STREAM,
        .implementation = stream,
    };
    const provider: cdrv.GlowcapTransportProvider = .{
        .abi_version = cdrv.GLOWCAP_TRANSPORT_PROVIDER_ABI_VERSION,
        .struct_size = @sizeOf(cdrv.GlowcapTransportProvider),
        .entries = @ptrCast(&entry),
        .entry_count = 1,
        .lease_ctx = @constCast(stream),
        .same_configuration = sameStaticProvider,
        .retain = retainStaticProvider,
        .release = releaseStaticProvider,
    };
    return addProvider(loop, &provider);
}

pub fn readListenerLocator(loop: ?*cdrv.GlowcapDriverLoop, listener: u64) !glowcap.ocapn.model.PeerLocator {
    var borrowed: cdrv.GlowcapLocatorView = undefined;
    try expectOk(cdrv.glowcap_driver_listener_locator(loop, listener, &borrowed));
    var handle: ?*c.GlowcapLocator = null;
    try expectOk(c.glowcap_locator_clone(&borrowed, &handle));
    defer c.glowcap_locator_release(handle);

    const allocator = std.testing.allocator;
    const readField = struct {
        fn call(
            locator: ?*c.GlowcapLocator,
            accessor: *const fn (?*c.GlowcapLocator, ?*?[*]const u8, ?*usize) callconv(.c) i32,
        ) ![]u8 {
            var ptr: ?[*]const u8 = null;
            var len: usize = 0;
            try expectOk(accessor(locator, &ptr, &len));
            return allocator.dupe(u8, if (len == 0) &.{} else ptr.?[0..len]);
        }
    }.call;
    const transport = try readField(handle, c.glowcap_locator_transport);
    errdefer allocator.free(transport);
    const designator = try readField(handle, c.glowcap_locator_designator);
    errdefer allocator.free(designator);
    var hint_count: usize = 0;
    try expectOk(c.glowcap_locator_hint_count(handle, &hint_count));
    const hints = try allocator.alloc(glowcap.ocapn.model.HintEntry, hint_count);
    errdefer allocator.free(hints);
    var initialized: usize = 0;
    errdefer for (hints[0..initialized]) |entry| glowcap.ocapn.model.freeHintEntry(allocator, entry);
    for (hints) |*entry| {
        var view: cdrv.GlowcapLocatorHintView = undefined;
        try expectOk(c.glowcap_locator_hint_at(handle, initialized, &view));
        const name = try allocator.dupe(u8, view.name.?[0..view.name_len]);
        errdefer allocator.free(name);
        const value: glowcap.ocapn.model.HintValue = switch (view.kind) {
            cdrv.GLOWCAP_HINT_STRING => .{ .string = try allocator.dupe(u8, if (view.bytes_len == 0) &.{} else view.bytes.?[0..view.bytes_len]) },
            cdrv.GLOWCAP_HINT_BYTES => .{ .bytes = try allocator.dupe(u8, if (view.bytes_len == 0) &.{} else view.bytes.?[0..view.bytes_len]) },
            cdrv.GLOWCAP_HINT_BOOLEAN => .{ .boolean = view.boolean_value == 1 },
            cdrv.GLOWCAP_HINT_INTEGER => .{ .integer = view.integer_value },
            else => return error.InvalidHintKind,
        };
        entry.* = .{ .name = name, .value = value };
        initialized += 1;
    }
    var raw_wire_form: u32 = undefined;
    try expectOk(c.glowcap_locator_hint_wire_form(handle, &raw_wire_form));
    const wire_form: glowcap.ocapn.model.Hints.WireForm = switch (raw_wire_form) {
        cdrv.GLOWCAP_HINTS_MAP => .map,
        cdrv.GLOWCAP_HINTS_BOOLEAN_FALSE => .boolean_false,
        else => return error.InvalidHintWireForm,
    };
    return .{ .transport = transport, .designator = designator, .hints = .{ .entries = hints, .wire_form = wire_form } };
}

pub fn expectLoopReadable(loop: ?*cdrv.GlowcapDriverLoop) !void {
    var fd: i32 = -1;
    try expectOk(cdrv.glowcap_driver_readiness_fd(loop, &fd));
    var fds = [_]std.posix.pollfd{
        .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 },
    };
    try std.testing.expectEqual(@as(usize, 1), try std.posix.poll(&fds, 1_000));
}

pub fn directAddresses(locator: glowcap.ocapn.model.PeerLocator) ?[]const u8 {
    for (locator.hints.entries) |entry| {
        if (!std.mem.eql(u8, entry.name, glowcap.ocapn.model.transport.hint_direct_addresses)) continue;
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
    comptime call: fn (@TypeOf(ctx), *const cdrv.GlowcapLocatorView) i32,
) i32 {
    var locator: ?*c.GlowcapLocator = null;
    const wire_form = if (direct.len == 0) cdrv.GLOWCAP_HINTS_BOOLEAN_FALSE else cdrv.GLOWCAP_HINTS_MAP;
    const created = c.glowcap_locator_new(
        transport.ptr,
        transport.len,
        designator.ptr,
        designator.len,
        wire_form,
        &locator,
    );
    if (created != c.GLOWCAP_OK) return created;
    defer c.glowcap_locator_release(locator);
    if (direct.len != 0) {
        const added = c.glowcap_locator_add_string(
            locator,
            glowcap.ocapn.model.transport.hint_direct_addresses,
            glowcap.ocapn.model.transport.hint_direct_addresses.len,
            direct.ptr,
            direct.len,
        );
        if (added != c.GLOWCAP_OK) return added;
    }
    var view: ?*const c.GlowcapLocatorView = null;
    const borrowed = c.glowcap_locator_borrow_view(locator, &view);
    if (borrowed != c.GLOWCAP_OK) return borrowed;
    return call(ctx, view.?);
}

pub fn dialParts(loop: ?*cdrv.GlowcapDriverLoop, transport: []const u8, designator: []const u8, direct: []const u8, out_operation_id: *u64) !i32 {
    const Context = struct { loop: ?*cdrv.GlowcapDriverLoop, operation_id: *u64 };
    return callWithLocator(transport, designator, direct, Context{ .loop = loop, .operation_id = out_operation_id }, struct {
        fn call(ctx: Context, locator: *const cdrv.GlowcapLocatorView) i32 {
            return cdrv.glowcap_driver_dial(ctx.loop, locator, null, ctx.operation_id);
        }
    }.call);
}

pub fn dialLocator(
    loop: ?*cdrv.GlowcapDriverLoop,
    locator: glowcap.ocapn.model.PeerLocator,
    out_operation_id: *u64,
) !i32 {
    var hints: [cshared.locator_adapter.inline_hint_capacity]cdrv.GlowcapLocatorHintView = undefined;
    var projection = try cshared.locator_adapter.Projection.init(
        std.testing.allocator,
        locator,
        &hints,
    );
    defer projection.deinit(std.testing.allocator);
    return cdrv.glowcap_driver_dial(loop, &projection.view, null, out_operation_id);
}

pub fn advertiseParts(loop: ?*cdrv.GlowcapDriverLoop, listener: u64, transport: []const u8, designator: []const u8, direct: []const u8) !i32 {
    const Context = struct { loop: ?*cdrv.GlowcapDriverLoop, listener: u64 };
    return callWithLocator(transport, designator, direct, Context{ .loop = loop, .listener = listener }, struct {
        fn call(ctx: Context, locator: *const cdrv.GlowcapLocatorView) i32 {
            return cdrv.glowcap_driver_listener_advertise(ctx.loop, ctx.listener, locator);
        }
    }.call);
}

pub const TestLoop = struct {
    raw: ?*cdrv.GlowcapDriverLoop,
    host: ?*cd.GlowcapHost,

    pub fn deinit(self: TestLoop) void {
        _ = releaseLoop(self.raw);
    }
};

pub fn installTcp(loop: ?*cdrv.GlowcapDriverLoop) !void {
    var tcp: ?*ctcp.GlowcapTcpNetlayer = null;
    try expectOk(ctcp.glowcap_tcp_netlayer_new(&default_tcp_config, &tcp));
    defer ctcp.glowcap_tcp_netlayer_release(tcp);
    var provider: cdrv.GlowcapTransportProvider = undefined;
    try expectOk(ctcp.glowcap_tcp_transport_provider(tcp, &provider));
    try expectOk(addProvider(loop, &provider));
}

pub fn installRelay(
    loop: ?*cdrv.GlowcapDriverLoop,
    relay_url: []const u8,
    register_url: []const u8,
) !void {
    const config: crelay.GlowcapRelayConfig = .{
        .relay_url = relay_url.ptr,
        .relay_url_len = relay_url.len,
        .register_url = register_url.ptr,
        .register_url_len = register_url.len,
    };
    var runtime: ?*crelay.GlowcapRelayRuntime = null;
    try expectOk(crelay.glowcap_relay_runtime_new(&config, &runtime));
    defer expectOk(crelay.glowcap_relay_runtime_release(runtime, null, 0, null)) catch unreachable;
    var provider: cdrv.GlowcapTransportProvider = undefined;
    try expectOk(crelay.glowcap_relay_transport_provider(runtime, &provider));
    try expectOk(addProvider(loop, &provider));
}

pub fn newEmptyLoop(seed_byte: u8) !TestLoop {
    const host = try newByteFedHost(seed_byte);
    errdefer _ = cd.glowcap_host_release(host);
    var loop: ?*cdrv.GlowcapDriverLoop = null;
    try expectOk(cdrv.glowcap_driver_take_host(host, &driver_options_10s, &loop));
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

pub fn newByteFedHost(seed_byte: u8) !?*cd.GlowcapHost {
    var host: ?*cd.GlowcapHost = null;
    const seed = hostSeed(seed_byte);
    try expectOk(cd.glowcap_host_new(
        &seed,
        seed.len,
        frame_cap,
        1,
        c.GLOWCAP_CODEC_SYRUP,
        c.GLOWCAP_CAPTP_V1_0,
        c.GLOWCAP_FEATURE_FULL,
        0,
        &host,
    ));
    return host;
}

/// What one loop's drained events amounted to; scalar facts only, because a
/// COMPLETION's views die at the next `glowcap_driver_next_event`.
pub const Drained = struct {
    dialed_session: ?*cd.GlowcapHostSession = null,
    dialed_operation_id: u64 = 0,
    dial_failed: bool = false,
    accepted: bool = false,
    accepted_listener: u64 = 0,
    accepted_session: ?*cd.GlowcapHostSession = null,
    listener_ready: bool = false,
    ready_listener: u64 = 0,
    listener_failed: bool = false,
    failed_listener: u64 = 0,
    closed: bool = false,
    closed_count: usize = 0,
    closed_result: i32 = c.GLOWCAP_OK,
    closed_message: [64]u8 = undefined,
    closed_message_len: usize = 0,
    closed_secondary_result: i32 = c.GLOWCAP_OK,
    closed_secondary_count: u32 = 0,
    closed_secondary_message: [64]u8 = undefined,
    closed_secondary_message_len: usize = 0,
    settle_ticket: u64 = 0,
    settled_reference: c.GlowcapReference = .{ .id = 0 },
    fail_ticket: u64 = 0,
};

/// Announce both embedders' post-open setup is done, so held inbound flows.
/// Loop scenarios call this once their OPENED and ACCEPTED events landed.
pub fn serveBoth(
    client: ?*cdrv.GlowcapDriverLoop,
    client_session: ?*cd.GlowcapHostSession,
    server: ?*cdrv.GlowcapDriverLoop,
    server_session: ?*cd.GlowcapHostSession,
) !void {
    try expectOk(cdrv.glowcap_driver_session_serve(client, client_session));
    try expectOk(cdrv.glowcap_driver_session_serve(server, server_session));
}

pub fn drainEvents(loop: ?*cdrv.GlowcapDriverLoop, into: *Drained) !void {
    var event: cdrv.GlowcapDriverEvent = undefined;
    while (true) {
        const rc = cdrv.glowcap_driver_next_event(loop, &event);
        if (rc == c.GLOWCAP_ERR_WOULD_BLOCK) return;
        try expectOk(rc);
        switch (event.kind) {
            cdrv.GLOWCAP_DRIVER_EVENT_OPENED => {
                into.dialed_session = event.session;
                into.dialed_operation_id = event.operation_id;
            },
            cdrv.GLOWCAP_DRIVER_EVENT_OPEN_FAILED => {
                into.dial_failed = true;
                if (event.primary_name) |name| std.debug.print("dial failed: {s}\n", .{name[0..event.primary_name_len]});
            },
            cdrv.GLOWCAP_DRIVER_EVENT_ACCEPTED => {
                into.accepted = true;
                into.accepted_listener = event.listener_id;
                into.accepted_session = event.session;
            },
            cdrv.GLOWCAP_DRIVER_EVENT_LISTENER_READY => {
                into.listener_ready = true;
                into.ready_listener = event.listener_id;
            },
            cdrv.GLOWCAP_DRIVER_EVENT_LISTENER_FAILED => {
                into.listener_failed = true;
                into.failed_listener = event.listener_id;
                if (event.primary_name) |name| std.debug.print("listener failed: {s}\n", .{name[0..event.primary_name_len]});
            },
            cdrv.GLOWCAP_DRIVER_EVENT_SESSION_CLOSED => {
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
            cdrv.GLOWCAP_DRIVER_EVENT_COMPLETION => switch (event.action.kind) {
                cd.GLOWCAP_HOST_ACTION_SETTLE => {
                    into.settle_ticket = event.action.ticket;
                    if (event.action.value.kind == c.GLOWCAP_ARG_REFERENCE)
                        into.settled_reference = event.action.value.reference;
                },
                cd.GLOWCAP_HOST_ACTION_FAIL => into.fail_ticket = event.action.ticket,
                else => return error.UnexpectedCompletionKind,
            },
            else => return error.UnexpectedEventKind,
        }
    }
}

pub fn awaitListenerReady(loop: ?*cdrv.GlowcapDriverLoop, listener: u64) !void {
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
        try expectStep(cdrv.glowcap_driver_step(loop, 5));
    }
    return error.ListenerSetupTimedOut;
}

pub fn listenReady(
    loop: ?*cdrv.GlowcapDriverLoop,
    transport: []const u8,
    designator: []const u8,
) !u64 {
    var listener: u64 = 0;
    try expectOk(cdrv.glowcap_driver_listen(
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
