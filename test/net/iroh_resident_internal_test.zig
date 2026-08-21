const std = @import("std");
const foundation = @import("foundation");
const engine = @import("engine");
const model = @import("model");
const net = @import("net");
const iroh = @import("iroh");
const c = @import("c_abi_shared");
const c_iroh = @import("c_abi_net_transport_iroh");

var conn_free_count: usize = 0;
var next_connect: ?*anyopaque = null;
var next_accept: ?*anyopaque = null;
var endpoint_closed = false;
var direct_required: usize = 0;
var node_id_fails = false;
var remote_key: [foundation.crypto.PEER_KEY_BYTES]u8 = @as([foundation.crypto.PEER_KEY_BYTES]u8, @splat(0x61));
var readiness_user_data: ?u64 = null;
var emit_platform_readiness = false;
var emit_sidecar_accept = false;
var delegated_accepts: usize = 0;

fn resetSidecar() void {
    conn_free_count = 0;
    next_connect = null;
    next_accept = null;
    endpoint_closed = false;
    direct_required = 0;
    node_id_fails = false;
    readiness_user_data = null;
    emit_platform_readiness = false;
    emit_sidecar_accept = false;
    delegated_accepts = 0;
}

fn resident(io: std.Io) iroh.Resident {
    return .{
        .io = io,
        .endpoint = @ptrFromInt(1),
        .reachability = .local_discovery,
    };
}

fn listenerFrom(outcome: net.netlayer.ListenStartOutcome) !net.netlayer.Listener {
    return switch (outcome) {
        .failed => error.ListenFailed,
        .admitted => |result| switch (result) {
            .ready => |listener| listener,
            .pending => error.SetupPending,
        },
    };
}

test "dial OOM retires the sidecar conn without publishing channel identity" {
    resetSidecar();
    next_connect = @ptrFromInt(2);
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var transport = resident(threaded.io());
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var peer = engine.Peer.init(failing.allocator());
    defer peer.deinit();
    var read: [1]u8 = undefined;
    var write: [1]u8 = undefined;

    try std.testing.expectError(
        error.OutOfMemory,
        transport.netlayer().dial(
            &peer,
            iroh.locator("0000000000000000000000000000000000000000000000000000000000000000"),
            .{ .read = &read, .write = &write },
            .inherit,
        ),
    );
    try std.testing.expect(peer.verifiedChannelKey() == null);
    try std.testing.expectEqual(@as(usize, 1), conn_free_count);
}

test "accept OOM retires the sidecar conn without publishing channel identity" {
    resetSidecar();
    next_accept = @ptrFromInt(3);
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var transport = resident(threaded.io());
    const listener = try listenerFrom(transport.netlayer().listen(
        std.testing.allocator,
        .{ .designator = "" },
    ));
    defer std.debug.assert(listener.close() == null);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var peer = engine.Peer.init(failing.allocator());
    defer peer.deinit();
    var read: [1]u8 = undefined;
    var write: [1]u8 = undefined;
    try std.testing.expectError(
        error.OutOfMemory,
        listener.accept(&peer, .{ .read = &read, .write = &write }),
    );
    try std.testing.expect(peer.verifiedChannelKey() == null);
    try std.testing.expectEqual(@as(usize, 1), conn_free_count);
}

test "successful dial publishes identity after stream adoption" {
    resetSidecar();
    next_connect = @ptrFromInt(4);
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var transport = resident(threaded.io());
    var peer = engine.Peer.init(std.testing.allocator);
    defer peer.deinit();
    var read: [1]u8 = undefined;
    var write: [1]u8 = undefined;
    var connection = try transport.netlayer().dial(
        &peer,
        iroh.locator("0000000000000000000000000000000000000000000000000000000000000000"),
        .{ .read = &read, .write = &write },
        .inherit,
    );
    try std.testing.expect(peer.verifiedChannelKey().?.eql(foundation.crypto.PeerKey.fromBytes(remote_key)));
    try std.testing.expectEqual(@as(usize, 0), conn_free_count);
    connection.deinit();
    try std.testing.expectEqual(@as(usize, 1), conn_free_count);
}

test "direct-address short output is typed and retryable" {
    resetSidecar();
    direct_required = 8;
    var transport = resident(undefined);
    var short: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 8), (try transport.directAddrs(&short)).too_small);

    var exact: [8]u8 = undefined;
    const value = (try transport.directAddrs(&exact)).written;
    try std.testing.expectEqual(@as(usize, 8), value.len);
    try std.testing.expectEqualSlices(u8, "aaaaaaaa", value);
}

test "direct-address C ABI reports required length on short output" {
    resetSidecar();
    direct_required = 8;
    const config: c_iroh.PancakeIrohConfig = .{
        .reachability = c_iroh.PANCAKE_IROH_REACH_LOCAL_DISCOVERY,
        .connect_timeout_ms = 0,
        .idle_timeout_ms = 0,
        .worker_threads = 0,
    };
    var raw: ?*c_iroh.PancakeIrohNetlayer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c_iroh.pancake_iroh_netlayer_new(null, 0, &config, &raw, null, 0, null));
    defer {
        const release_rc = c_iroh.pancake_iroh_netlayer_release(raw, null, 0, null);
        std.testing.expectEqual(c.PANCAKE_OK, release_rc) catch @panic("iroh netlayer release failed");
    }
    const netlayer = raw.?;

    var len: usize = 0;
    try std.testing.expectEqual(c.PANCAKE_ERR_BUFFER_TOO_SMALL, c_iroh.pancake_iroh_netlayer_direct_addrs(netlayer, null, 0, &len));
    try std.testing.expectEqual(@as(usize, 8), len);

    var short: [4]u8 = undefined;
    try std.testing.expectEqual(c.PANCAKE_ERR_BUFFER_TOO_SMALL, c_iroh.pancake_iroh_netlayer_direct_addrs(netlayer, &short, short.len, &len));
    try std.testing.expectEqual(@as(usize, 8), len);

    var exact: [8]u8 = undefined;
    try std.testing.expectEqual(c.PANCAKE_OK, c_iroh.pancake_iroh_netlayer_direct_addrs(netlayer, &exact, exact.len, &len));
    try std.testing.expectEqualSlices(u8, "aaaaaaaa", exact[0..len]);
}

test "direct-address owned helper refuses oversized sidecar metadata" {
    resetSidecar();
    direct_required = iroh.max_direct_address_bytes + 1;
    var transport = resident(undefined);
    try std.testing.expectError(error.AddressListTooLarge, transport.directAddrsOwned(std.testing.allocator));
}

test "listener metadata refuses a missing endpoint identity" {
    resetSidecar();
    node_id_fails = true;
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var transport = resident(threaded.io());
    const listener = try listenerFrom(transport.netlayer().listen(
        std.testing.allocator,
        .{ .designator = "" },
    ));
    defer std.debug.assert(listener.close() == null);

    try std.testing.expectError(error.BindFailed, listener.localLocator(std.testing.allocator));
    const candidate = iroh.locator("0000000000000000000000000000000000000000000000000000000000000000");
    try std.testing.expectError(
        error.BindFailed,
        listener.canonicalizeLocator(std.testing.allocator, candidate),
    );
}

test "bounded accept timeout stays retryable while endpoint close is terminal" {
    resetSidecar();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var transport = resident(threaded.io());
    const listener = try listenerFrom(transport.netlayer().listen(
        std.testing.allocator,
        .{ .designator = "" },
    ));
    defer std.debug.assert(listener.close() == null);

    try std.testing.expect(!try listener.waitAcceptable(0));
    transport.close();
    try std.testing.expectError(error.ConnectionLost, listener.waitAcceptable(-1));
}

const ScriptPlatform = struct {
    pub const Fd = i32;
    pub const adapter_depth = 0;
    pub const ConnectTarget = void;

    pub fn deinit(_: *ScriptPlatform) void {}
    pub fn submitRecv(_: *ScriptPlatform, user_data: u64, fd: Fd) !void {
        if (fd == 100) readiness_user_data = user_data;
    }
    pub fn recycleBorrowed(_: *ScriptPlatform, _: net.completion.Completion) void {}
    pub fn submitAccept(_: *ScriptPlatform, _: u64, _: Fd) !void {
        delegated_accepts += 1;
    }
    pub fn poll(_: *ScriptPlatform, out: []net.completion.Completion, _: i32) !usize {
        if (!emit_platform_readiness) return 0;
        emit_platform_readiness = false;
        out[0] = .{
            .user_data = readiness_user_data orelse return error.ReadinessNotArmed,
            .result = 1,
            .recv_no_buffer = true,
        };
        return 1;
    }
};

test "accept readiness uses the endpoint reservation before later settlement" {
    resetSidecar();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var transport = resident(undefined);
    const Backend = iroh.CompletionBackend(ScriptPlatform);
    var backend = try Backend.initBoundWithPlatform(
        failing.allocator(),
        &transport,
        .{},
        1,
        64,
    );
    defer backend.deinit();
    _ = try backend.openListener(0);

    // First poll reserves the transient completion batch and arms both signal
    // descriptors. No sidecar work is available yet.
    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));

    // Refuse every subsequent allocation while an accepted connection moves
    // from the consumed sidecar edge into the preallocated 128-seat stash.
    failing.fail_index = failing.alloc_index;
    next_accept = @ptrFromInt(91);
    emit_sidecar_accept = true;
    emit_platform_readiness = true;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expect(next_accept == null);
    try std.testing.expectEqual(@as(usize, 0), conn_free_count);

    // Restore ordinary allocator service. The retained accept is claimed once
    // and publishes through the normal pending-accept boundary.
    failing.fail_index = std.math.maxInt(usize);
    try backend.submitAccept(77, Backend.listen_fd);
    try std.testing.expectEqual(@as(usize, 0), delegated_accepts);
    const settled = try backend.poll(&completions, 0);
    try std.testing.expectEqual(@as(usize, 1), settled);
    try std.testing.expectEqual(@as(u64, 77), completions[0].user_data);
    try std.testing.expect(completions[0].accepted_fd != null);
}

export fn pancake_iroh_sidecar_endpoint_new(_: ?*const [32]u8, _: *const anyopaque) callconv(.c) ?*anyopaque {
    return @ptrFromInt(1);
}
export fn pancake_iroh_sidecar_endpoint_node_id(_: *const anyopaque, out: [*]u8, out_cap: usize) callconv(.c) isize {
    if (node_id_fails) return -1;
    if (out_cap < iroh.node_id_len) return iroh.node_id_len;
    @memset(out[0..iroh.node_id_len], '0');
    return iroh.node_id_len;
}
export fn pancake_iroh_sidecar_endpoint_direct_addrs(_: *const anyopaque, out: [*]u8, out_cap: usize) callconv(.c) isize {
    if (out_cap < direct_required) return @intCast(direct_required);
    @memset(out[0..direct_required], 'a');
    return @intCast(direct_required);
}
export fn pancake_iroh_sidecar_connect_blocking(_: *anyopaque, _: [*]const u8, _: usize, _: [*]const u8, _: usize, out_code: *i32) callconv(.c) ?*anyopaque {
    out_code.* = 0;
    const conn = next_connect;
    next_connect = null;
    return conn;
}
export fn pancake_iroh_sidecar_accept_timeout(_: *anyopaque, _: i32, out_code: *i32) callconv(.c) ?*anyopaque {
    const conn = next_accept;
    next_accept = null;
    out_code.* = if (conn != null) 0 else if (endpoint_closed) 4 else 2;
    return conn;
}
export fn pancake_iroh_sidecar_conn_remote_node_id(_: *const anyopaque, out: [*]u8) callconv(.c) i32 {
    @memcpy(out[0..remote_key.len], &remote_key);
    return 0;
}
export fn pancake_iroh_sidecar_conn_read(_: *anyopaque, _: [*]u8, _: usize) callconv(.c) isize {
    return -1;
}
export fn pancake_iroh_sidecar_conn_write(_: *anyopaque, _: [*]const u8, _: usize) callconv(.c) isize {
    return -1;
}
export fn pancake_iroh_sidecar_conn_flush(_: *anyopaque) callconv(.c) i32 {
    return 0;
}
export fn pancake_iroh_sidecar_conn_close(_: *anyopaque) callconv(.c) void {}
export fn pancake_iroh_sidecar_conn_free(_: *anyopaque) callconv(.c) void {
    conn_free_count += 1;
}
export fn pancake_iroh_sidecar_endpoint_close(_: *anyopaque) callconv(.c) void {
    endpoint_closed = true;
}
export fn pancake_iroh_sidecar_endpoint_free(_: *anyopaque) callconv(.c) i32 {
    return 0;
}
export fn pancake_iroh_sidecar_endpoint_readiness_fd(_: *const anyopaque) callconv(.c) i32 {
    return 100;
}
export fn pancake_iroh_sidecar_endpoint_drain_ready(_: *const anyopaque, out: [*]iroh.ReadyEvent, out_cap: usize) callconv(.c) isize {
    if (!emit_sidecar_accept or out_cap == 0) return 0;
    emit_sidecar_accept = false;
    out[0] = .{ .subject = 0, .events = iroh.loop_ev_accept };
    return 1;
}
export fn pancake_iroh_sidecar_endpoint_start_connect(_: *anyopaque, _: usize, _: [*]const u8, _: usize, _: [*]const u8, _: usize) callconv(.c) i32 {
    return 0;
}
export fn pancake_iroh_sidecar_endpoint_finish_connect(_: *anyopaque, _: usize, out_conn: *?*anyopaque) callconv(.c) i32 {
    out_conn.* = null;
    return -1;
}
export fn pancake_iroh_sidecar_endpoint_cancel_connect(_: *anyopaque, _: usize) callconv(.c) i32 {
    return 0;
}
export fn pancake_iroh_sidecar_endpoint_set_nonblocking_accept(_: *anyopaque) callconv(.c) i32 {
    return 0;
}
export fn pancake_iroh_sidecar_endpoint_try_accept(_: *anyopaque) callconv(.c) ?*anyopaque {
    const conn = next_accept;
    next_accept = null;
    return conn;
}
export fn pancake_iroh_sidecar_conn_set_nonblocking(_: *anyopaque, _: *anyopaque) callconv(.c) i32 {
    return 0;
}
export fn pancake_iroh_sidecar_conn_id(conn: *const anyopaque) callconv(.c) usize {
    return @intFromPtr(conn);
}
export fn pancake_iroh_sidecar_conn_try_read(_: *anyopaque, _: [*]u8, _: usize) callconv(.c) isize {
    return iroh.loop_would_block;
}
export fn pancake_iroh_sidecar_conn_try_write(_: *anyopaque, _: [*]const u8, _: usize) callconv(.c) isize {
    return iroh.loop_would_block;
}
