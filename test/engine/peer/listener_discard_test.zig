//! An inbound listener the engine discards leaves like one it fires: the
//! listener's import goes back to the partner as one `op:gc-export`, with no
//! callback. The spec discards a settling listener when its promise fulfills
//! with a far promise, and the partner counted the listener mention as one
//! export retain, so a discard that kept it would pin that export for the
//! session's life.

const std = @import("std");
const glowcap = @import("glowcap");

const codec = glowcap.ocapn.codec;
const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const peer_fixture = @import("../../support/peer_fixture.zig");

fn expectListenerRelease(peer: *engine.Peer, listener: u64) !void {
    while ((try peer.step()) != .idle) {}
    var release = peer.takeOutbound().?;
    defer release.deinit();
    const body = try codec.syrup.decodeBodyForProfile(.next, release.view());
    try std.testing.expect(body == .gc_export);
    try std.testing.expectEqual(@as(usize, 1), try body.gc_export.positions.len());
    try std.testing.expectEqual(listener, try body.gc_export.positions.at(0));
    try std.testing.expectEqual(@as(u64, 1), try body.gc_export.deltas.at(0));
    try std.testing.expect(peer.takeOutbound() == null);
    try std.testing.expect(!peer.session_state.hasImport(.from(listener)));
}

test "a settling listener discarded by a far promise releases its import on the wire" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.installInboundAnswer(.from(7));
    try peer.session_state.registerImport(.from(5));
    try peer.recvBorrowed(.{ .bytes = "<9'op:listen<11'desc:answer7+><18'desc:import-object9+>2+>", .shape = .byte });
    {
        var event = peer.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(engine.EventKind.listen, event.kind());
    }
    try std.testing.expect(peer.session_state.hasImport(.from(9)));

    try peer.sendBorrowed(.{ .resolve = .{
        .answer = .from(7),
        .resolution = .{ .fulfill = .{ .reference = .{ .far = model.FarRef.promise(5) } } },
    } });
    try expectListenerRelease(&peer, 9);
}

test "a settling listener installed after the far promise stored is discarded the same way" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.installInboundAnswer(.from(7));
    try peer.session_state.registerImport(.from(5));
    try peer.sendBorrowed(.{ .resolve = .{
        .answer = .from(7),
        .resolution = .{ .fulfill = .{ .reference = .{ .far = model.FarRef.promise(5) } } },
    } });
    while ((try peer.step()) != .idle) {}
    try std.testing.expect(peer.takeOutbound() == null);

    try peer.recvBorrowed(.{ .bytes = "<9'op:listen<11'desc:answer7+><18'desc:import-object9+>2+>", .shape = .byte });
    {
        var event = peer.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(engine.EventKind.listen, event.kind());
    }
    try expectListenerRelease(&peer, 9);
}

test "a shortening listener on a live object export is discarded and released at once" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));
    try peer.recvBorrowed(.{ .bytes = "<9'op:listen<11'desc:export7+><18'desc:import-object9+>1+>", .shape = .byte });
    {
        var event = peer.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(engine.EventKind.listen, event.kind());
    }
    try expectListenerRelease(&peer, 9);
}

test "a discard the outbound queue refuses aborts the session like a refused fire" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));
    peer.outbound_budget = 1;
    const inbound = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .listen = .{
        .target = .{ .far = model.FarRef.object(7) },
        .listener = .{ .near = model.NearRef.object(9) },
        .mode = .shortening_only,
    } });
    try peer.feedOwned(inbound);
    try std.testing.expectError(error.OutboundBackpressure, peer.step());
    try std.testing.expect(!peer.sessionIsOpen());
    try std.testing.expect(!peer.session_state.hasImport(.from(9)));
    var abort_frame = peer.takeOutbound() orelse return error.MissingAbort;
    defer abort_frame.deinit();
    const abort = try codec.syrup.decodeBodyForProfile(.next, abort_frame.view());
    try std.testing.expect(abort == .abort);
    try std.testing.expectEqual(model.AbortKind.resource_exhausted, abort.abort.kind);
    try std.testing.expect(peer.takeOutbound() == null);
}

test "a queued discard carrier releases its retain locally when the peer is torn down" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.installInboundAnswer(.from(7));
    try peer.session_state.registerImport(.from(5));
    try peer.recvBorrowed(.{ .bytes = "<9'op:listen<11'desc:answer7+><18'desc:import-object9+>2+>", .shape = .byte });
    {
        var event = peer.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(engine.EventKind.listen, event.kind());
    }
    try peer.sendBorrowed(.{ .resolve = .{
        .answer = .from(7),
        .resolution = .{ .fulfill = .{ .reference = .{ .far = model.FarRef.promise(5) } } },
    } });
    // The carrier is queued and never drained: `deinit` releases the retain
    // with the queue, and the testing allocator holds the row to that.
    try std.testing.expect(peer.session_state.hasImport(.from(9)));
}
