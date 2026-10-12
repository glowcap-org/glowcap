const std = @import("std");
const builtin = @import("builtin");
const iroh = @import("iroh");
const model = @import("model");

comptime {
    _ = @import("iroh_sidecar_stub");
}

test "iroh locator constructors preserve discovery and direct-address postures" {
    const designator = "0000000000000000000000000000000000000000000000000000000000000000";
    const discovery = iroh.locator(designator);
    try std.testing.expectEqualStrings(iroh.transport_name, discovery.transport);
    try std.testing.expectEqualStrings(designator, discovery.designator);
    try std.testing.expectEqual(@as(usize, 0), discovery.hints.entries.len);
    try std.testing.expectEqual(model.Hints.WireForm.boolean_false, discovery.hints.wire_form);

    const direct_addresses = "127.0.0.1:9099";
    var hint_storage: [1]model.HintEntry = undefined;
    const direct = iroh.locatorWithDirectAddresses(designator, direct_addresses, &hint_storage);
    try std.testing.expectEqual(@as(usize, 1), direct.hints.entries.len);
    try std.testing.expect(@intFromPtr(direct.hints.entries.ptr) == @intFromPtr(&hint_storage[0]));
    try std.testing.expectEqualStrings(direct_addresses, direct.hints.entries[0].value.string);
}

test "supported iroh facade and nested surfaces stay exact" {
    const root_names = .{
        "transport_profile",
        "transport_name",
        "Reachability",
        "hint_direct_addresses",
        "max_direct_address_bytes",
        "node_id_len",
        "read_chunk_bytes",
        "locator",
        "locatorWithDirectAddresses",
        "ReadyEvent",
        "Resident",
        "MultiplexedAdapter",
        "loop_would_block",
        "loop_ev_readable",
        "loop_ev_writable",
        "loop_ev_closed",
        "loop_ev_accept",
        "loop_ev_connect",
        "ConnectTarget",
        "resolveConnectTarget",
        "DialResolver",
        "CompositeDialResolver",
        "validateListenerLocator",
        "CompletionBackend",
        "Backend",
        "DialText",
        "dial_text_bytes",
    };
    try std.testing.expectEqual(root_names.len, @typeInfo(iroh).@"struct".decl_names.len);
    inline for (root_names) |name| try std.testing.expect(@hasDecl(iroh, name));

    const resident_names = .{
        "InitError",
        "Config",
        "init",
        "close",
        "deinit",
        "netlayer",
        "nodeId",
        "DirectAddrsError",
        "DirectAddrsResult",
        "directAddrs",
        "directAddrsOwned",
        "enableLoop",
        "setLoopAdmission",
        "readinessFd",
        "drainReady",
        "loopTryAccept",
        "loopStartConnectResolved",
        "loopFinishConnect",
        "loopRequestConnectCancel",
        "loopCancelConnect",
        "loopConnId",
        "loopTryRead",
        "loopTryWrite",
        "loopConnClose",
        "loopConnRemoteKey",
    };
    try std.testing.expectEqual(resident_names.len, @typeInfo(iroh.Resident).@"struct".decl_names.len);
    inline for (resident_names) |name| try std.testing.expect(@hasDecl(iroh.Resident, name));

    const backend_names = .{ "Fd", "adapter_depth", "ListenerAddress", "ListenTarget", "loopListenTarget", "ConnectTarget", "listen_fd", "connection_state_bytes", "initBound", "initBoundWithPlatform", "deinit", "tcpBackendStatus", "wake", "openListener", "listenerPending", "startDial", "listenerAddress", "listenerPort", "applyKeepalive", "wireFraming", "closeFd", "shutdownFd", "recycleBorrowed", "verifiedChannelKey", "submitAccept", "submitRecv", "submitSend", "submitCancel", "submitClose", "poll" };
    try std.testing.expectEqual(backend_names.len, @typeInfo(iroh.Backend).@"struct".decl_names.len);
    inline for (backend_names) |name| try std.testing.expect(@hasDecl(iroh.Backend, name));

    try std.testing.expectEqual(@as(usize, 32), @sizeOf(iroh.Resident));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(iroh.Resident));
    // The platform backend's four listener-address bytes consume an existing
    // kqueue padding lane. io_uring needs one new aligned word, its listener
    // table (two maps and a close queue, so many listeners can share the ring)
    // two more, and the Linux selector tag another. This is one fixed charge
    // per loop, never a
    // per-connection or wire-path cost. Stated under runtime safety, where each
    // embedded `std.ArrayList` header carries std's one-word
    // `pointer_stability` lock: 32 of these bytes on both platforms.
    if (!std.debug.runtime_safety) return error.SkipZigTest;
    const expected_backend_bytes: usize = switch (builtin.os.tag) {
        .linux => 680,
        else => 528,
    };
    try std.testing.expectEqual(expected_backend_bytes, @sizeOf(iroh.Backend));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(iroh.Backend));
}
