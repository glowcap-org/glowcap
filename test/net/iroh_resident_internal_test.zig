const std = @import("std");
const foundation = @import("foundation");
const engine = @import("engine");
const model = @import("model");
const net = @import("net");
const iroh = @import("iroh");
const c = @import("c_abi_shared");
const c_iroh = @import("c_abi_net_transport_iroh");
const stub = @import("iroh_sidecar_stub.zig");

var readiness_user_data: ?u64 = null;
var emit_platform_readiness = false;
var delegated_accepts: usize = 0;

fn resetSidecar() void {
    stub.reset();
    readiness_user_data = null;
    emit_platform_readiness = false;
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
    stub.next_connect = @ptrFromInt(2);
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
    try std.testing.expectEqual(@as(usize, 1), stub.conn_free_count);
}

test "accept OOM retires the sidecar conn without publishing channel identity" {
    resetSidecar();
    stub.next_accept = @ptrFromInt(3);
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
    try std.testing.expectEqual(@as(usize, 1), stub.conn_free_count);
}

test "successful dial publishes identity after stream adoption" {
    resetSidecar();
    stub.next_connect = @ptrFromInt(4);
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
    try std.testing.expect(peer.verifiedChannelKey().?.eql(foundation.crypto.PeerKey.fromBytes(stub.remote_key)));
    try std.testing.expectEqual(@as(usize, 0), stub.conn_free_count);
    connection.deinit();
    try std.testing.expectEqual(@as(usize, 1), stub.conn_free_count);
}

test "direct-address short output is typed and retryable" {
    resetSidecar();
    stub.direct_required = 8;
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
    stub.direct_required = 8;
    const config: c_iroh.GlowcapIrohConfig = .{
        .reachability = c_iroh.GLOWCAP_IROH_REACH_LOCAL_DISCOVERY,
        .connect_timeout_ms = 0,
        .idle_timeout_ms = 0,
        .worker_threads = 0,
    };
    var raw: ?*c_iroh.GlowcapIrohNetlayer = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, c_iroh.glowcap_iroh_netlayer_new(null, 0, &config, &raw, null, 0, null));
    defer {
        const release_rc = c_iroh.glowcap_iroh_netlayer_release(raw, null, 0, null);
        std.testing.expectEqual(c.GLOWCAP_OK, release_rc) catch @panic("iroh netlayer release failed");
    }
    const netlayer = raw.?;

    var len: usize = 0;
    try std.testing.expectEqual(c.GLOWCAP_ERR_BUFFER_TOO_SMALL, c_iroh.glowcap_iroh_netlayer_direct_addrs(netlayer, null, 0, &len));
    try std.testing.expectEqual(@as(usize, 8), len);

    var short: [4]u8 = undefined;
    try std.testing.expectEqual(c.GLOWCAP_ERR_BUFFER_TOO_SMALL, c_iroh.glowcap_iroh_netlayer_direct_addrs(netlayer, &short, short.len, &len));
    try std.testing.expectEqual(@as(usize, 8), len);

    var exact: [8]u8 = undefined;
    try std.testing.expectEqual(c.GLOWCAP_OK, c_iroh.glowcap_iroh_netlayer_direct_addrs(netlayer, &exact, exact.len, &len));
    try std.testing.expectEqualSlices(u8, "aaaaaaaa", exact[0..len]);
}

test "direct-address owned helper refuses oversized sidecar metadata" {
    resetSidecar();
    stub.direct_required = iroh.max_direct_address_bytes + 1;
    var transport = resident(undefined);
    try std.testing.expectError(error.AddressListTooLarge, transport.directAddrsOwned(std.testing.allocator));
}

test "listener metadata refuses a missing endpoint identity" {
    resetSidecar();
    stub.node_id_fails = true;
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
    /// No submission queue here, so a peek is a zero-timeout poll.
    pub fn peek(self: *ScriptPlatform, out: []net.completion.Completion) !usize {
        return self.poll(out, 0);
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

test "iroh loop preserves the selected Linux TCP backend" {
    resetSidecar();
    var transport = resident(undefined);
    const platform = try net.Backend.init(std.testing.allocator, 1, 1, 64);
    const expected = platform.tcpBackendStatus();
    const backend = try iroh.Backend.initBoundWithPlatform(
        std.testing.allocator,
        &transport,
        platform,
        1,
        64,
    );
    const IrohLoop = net.completion.Loop(iroh.Backend, iroh.DialResolver);
    var loop = try IrohLoop.initWithBackend(
        std.testing.allocator,
        backend,
        unusedMakePeer,
        null,
        .{ .max_conns = 0 },
    );
    defer loop.deinit();

    try std.testing.expectEqualDeep(expected, net.tcpBackendStatus(&loop));
}

fn unusedMakePeer(_: ?*anyopaque, _: std.mem.Allocator) anyerror!engine.Peer {
    return error.Unused;
}

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
    _ = try backend.openListener({});

    // First poll reserves the transient completion batch and arms both signal
    // descriptors. No sidecar work is available yet. status-allow: pending state or quoted runtime label
    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));

    // Refuse every subsequent allocation while an accepted connection moves
    // from the consumed sidecar edge into the preallocated 128-seat stash.
    failing.fail_index = failing.alloc_index;
    stub.next_accept = @ptrFromInt(91);
    stub.emit_sidecar_accept = true;
    emit_platform_readiness = true;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expect(stub.next_accept == null);
    try std.testing.expectEqual(@as(usize, 0), stub.conn_free_count);

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

/// One iroh loop connection's adapter row: the sidecar handle beside the
/// hinted try-I/O seats, hints, and terminal cause every multiplexed sidecar
/// backend shares. No embedded list header, so the number holds in every
/// build mode.
const iroh_connection_state_bytes: usize = 64;

test "iroh completion connection state has a measured footprint" {
    const Backend = iroh.CompletionBackend(ScriptPlatform);
    try std.testing.expectEqual(iroh_connection_state_bytes, Backend.connection_state_bytes);
}

test "managed iroh: a refused connection-map allocation closes the claimed handle once" {
    resetSidecar();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var endpoint = resident(threaded.io());
    var refusing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var adapter = try iroh.MultiplexedAdapter.init(refusing.allocator(), &endpoint);
    defer std.debug.assert(adapter.deinit() == null);
    stub.next_connect = @ptrFromInt(91);
    try std.testing.expectError(error.OutOfMemory, adapter.finishConnect(1, null));
    try std.testing.expectEqual(@as(usize, 1), stub.conn_free_count);
    adapter.closeConnection(91); // stale readiness cannot close another handle
    try std.testing.expectEqual(@as(usize, 1), stub.conn_free_count);
}

test "managed iroh: dial admission pressure retains its retry classification" {
    resetSidecar();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var endpoint = resident(threaded.io());
    var adapter = try iroh.MultiplexedAdapter.init(std.testing.allocator, &endpoint);
    defer std.debug.assert(adapter.deinit() == null);
    stub.dial_start_result = 7;
    const outcome = adapter.multiplexed().dialer().?.startDial(1, iroh.locator("node"), .inherit, .application);
    const failure = outcome.failed;
    try std.testing.expectEqual(error.WouldBlock, failure.classification);
    try std.testing.expectEqual(error.WouldBlock, failure.chain.cause);
    try std.testing.expectEqual(@as(usize, 0), stub.conn_free_count);
}

test "managed iroh: failure custody is claim-once and connection close is idempotent" {
    resetSidecar();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var endpoint = resident(threaded.io());
    var adapter = try iroh.MultiplexedAdapter.init(std.testing.allocator, &endpoint);
    defer std.debug.assert(adapter.deinit() == null);
    stub.next_connect = @ptrFromInt(92);
    const id = try adapter.finishConnect(1, null);
    var bytes: [4]u8 = undefined;
    try std.testing.expectEqual(iroh.loop_would_block, adapter.tryRead(id, &bytes));
    try std.testing.expect(adapter.takeFailure(id) == null);
    stub.io_result = -1;
    try std.testing.expectEqual(@as(isize, -1), adapter.tryWrite(id, "x"));
    try std.testing.expectEqual(@as(isize, -1), adapter.tryRead(id, &bytes));
    try std.testing.expectEqual(error.ConnectionLost, adapter.takeFailure(id).?.cause);
    try std.testing.expect(adapter.takeFailure(id) == null);
    adapter.closeConnection(id);
    adapter.closeConnection(id);
    try std.testing.expectEqual(@as(usize, 1), stub.conn_free_count);
}

test "managed iroh: listener stop seals raw admission and preserves a claimed sibling" {
    resetSidecar();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var endpoint = resident(threaded.io());
    var adapter = try iroh.MultiplexedAdapter.init(std.testing.allocator, &endpoint);
    defer std.debug.assert(adapter.deinit() == null);
    try std.testing.expect(!stub.admission_enabled);
    try adapter.listen(7, iroh.transport_name, "", .inherit);
    try std.testing.expect(stub.admission_enabled);
    const original = try adapter.borrowListenerLocator();
    var invalid = original;
    invalid.transport = "tcp";
    try std.testing.expectError(error.InvalidAddress, adapter.validateAdvertisement(invalid));
    try std.testing.expectEqualStrings(original.designator, (try adapter.borrowListenerLocator()).designator);
    stub.next_accept = @ptrFromInt(93);
    const sibling = (try adapter.finishAccept()).?;
    stub.next_accept = @ptrFromInt(94);
    try adapter.stopListen();
    try std.testing.expect(!stub.admission_enabled);
    try std.testing.expect(stub.next_accept == null);
    try std.testing.expectEqual(@as(usize, 0), stub.conn_free_count);
    try std.testing.expect(adapter.remoteKey(sibling) != null);
    adapter.closeConnection(sibling);
    try std.testing.expectEqual(@as(usize, 1), stub.conn_free_count);
    try adapter.listen(8, iroh.transport_name, "", .inherit);
    try std.testing.expect((try adapter.finishAccept()) == null);
    try adapter.stopListen();
}

test "managed iroh: terminal admission failure still releases locator and connection custody" {
    resetSidecar();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var endpoint = resident(threaded.io());
    var adapter = try iroh.MultiplexedAdapter.init(std.testing.allocator, &endpoint);
    try adapter.listen(1, iroh.transport_name, "", .inherit);
    stub.next_connect = @ptrFromInt(95);
    _ = try adapter.finishConnect(1, null);
    stub.admission_fails = true;
    try std.testing.expectEqual(error.SidecarFailed, adapter.deinit().?.cause);
    try std.testing.expectEqual(@as(usize, 1), stub.conn_free_count);
    try std.testing.expect(!stub.endpoint_closed);
    var id: [iroh.node_id_len]u8 = undefined;
    try std.testing.expect(endpoint.nodeId(&id).len != 0);
}

test "managed iroh: cancellation consumes a connection that won the race exactly once" {
    resetSidecar();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var endpoint = resident(threaded.io());
    var adapter = try iroh.MultiplexedAdapter.init(std.testing.allocator, &endpoint);
    defer std.debug.assert(adapter.deinit() == null);
    stub.next_connect = @ptrFromInt(96);
    adapter.cancelConnect(1);
    adapter.cancelConnect(1);
    try std.testing.expectEqual(@as(usize, 2), stub.cancel_calls);
    try std.testing.expectEqual(@as(usize, 1), stub.conn_free_count);
    try std.testing.expect(stub.next_connect == null);
    try std.testing.expect(adapter.remoteKey(96) == null);
}

test "managed iroh: one readiness turn drains at most 32 records" {
    resetSidecar();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var endpoint = resident(threaded.io());
    var adapter = try iroh.MultiplexedAdapter.init(std.testing.allocator, &endpoint);
    defer std.debug.assert(adapter.deinit() == null);
    var events: [128]net.multiplexed_resident.ReadyEvent = undefined;
    stub.ready_records = 96;
    try std.testing.expectEqual(@as(usize, 32), try adapter.drainReady(&events));
    try std.testing.expectEqual(@as(usize, 64), stub.ready_records);
    try std.testing.expectEqual(@as(usize, 100), events[0].subject);
    // The remaining records stay with the endpoint for another runtime turn.
    try std.testing.expectEqual(@as(usize, 32), try adapter.drainReady(&events));
    try std.testing.expectEqual(@as(usize, 32), stub.ready_records);
}

test "managed iroh: a readiness count past the buffer is refused, not read" {
    resetSidecar();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var endpoint = resident(threaded.io());
    var adapter = try iroh.MultiplexedAdapter.init(std.testing.allocator, &endpoint);
    defer std.debug.assert(adapter.deinit() == null);
    var events: [8]net.multiplexed_resident.ReadyEvent = undefined;
    stub.ready_past_cap = true;
    try std.testing.expectError(error.ReadinessFailed, adapter.drainReady(&events));
}

test "managed iroh: a read or write reporting more bytes than offered faults the connection" {
    resetSidecar();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var endpoint = resident(threaded.io());
    var adapter = try iroh.MultiplexedAdapter.init(std.testing.allocator, &endpoint);
    defer std.debug.assert(adapter.deinit() == null);
    stub.next_connect = @ptrFromInt(97);
    const id = try adapter.finishConnect(1, null);
    var bytes: [4]u8 = undefined;
    stub.io_result = bytes.len + 1;
    try std.testing.expectEqual(@as(isize, -1), adapter.tryRead(id, &bytes));
    try std.testing.expectEqual(error.IrohSidecarContract, adapter.takeFailure(id).?.cause);
    stub.io_result = 2;
    try std.testing.expectEqual(@as(isize, -1), adapter.tryWrite(id, "x"));
    try std.testing.expectEqual(error.IrohSidecarContract, adapter.takeFailure(id).?.cause);
    adapter.closeConnection(id);
    try std.testing.expectEqual(@as(usize, 1), stub.conn_free_count);
}

test "iroh completion backend fails a readiness drain the library overfills" {
    resetSidecar();
    var transport = resident(undefined);
    const Backend = iroh.CompletionBackend(ScriptPlatform);
    var backend = try Backend.initBoundWithPlatform(std.testing.allocator, &transport, .{}, 1, 64);
    defer backend.deinit();
    _ = try backend.openListener({});
    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));

    stub.ready_past_cap = true;
    emit_platform_readiness = true;
    try std.testing.expectError(error.SidecarDrainFailed, backend.poll(&completions, 0));
}

test "iroh completion backend drops accepts past the stash bound and keeps serving" {
    resetSidecar();
    var transport = resident(undefined);
    const Backend = iroh.CompletionBackend(ScriptPlatform);
    var backend = try Backend.initBoundWithPlatform(std.testing.allocator, &transport, .{}, 1, 64);
    defer backend.deinit();
    _ = try backend.openListener({});
    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));

    // One readiness record announces more accepted connections than the
    // stash seats. The one past the bound is released, the rest wait.
    stub.accept_burst = Backend.max_accept_stash + 1;
    stub.emit_sidecar_accept = true;
    emit_platform_readiness = true;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(usize, 0), stub.accept_burst);
    try std.testing.expectEqual(@as(usize, 1), stub.conn_free_count);

    // The backend still serves: a claim takes the oldest stashed connection.
    try backend.submitAccept(77, Backend.listen_fd);
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 77), completions[0].user_data);
    try std.testing.expect(completions[0].accepted_fd != null);
}
