//! Containment goldens for rooms-peer lifecycle and durable state.
const std = @import("std");
const cli = @import("cli");

test "rooms-peer state paths fail instead of escaping their directory" {
    var buf: [8]u8 = undefined;
    try std.testing.expectError(
        error.NoSpaceLeft,
        cli.rooms_peer_files.pathIn(&buf, "/state/that/does/not/fit", "peer.pid"),
    );
}

test "rooms-peer process lease serializes ownership and stale pid text" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = "/tmp/rooms-peer-process-lease-test";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);

    const held = try cli.rooms_peer_files.tryLockLeaf(io, dir, "peer.pid");
    defer held.unlock();
    try std.testing.expectError(error.Busy, cli.rooms_peer_files.tryLockLeaf(io, dir, "peer.pid"));
    try cli.rooms_peer_files.overwriteFile(io, dir, "peer.pid", "1\n");
    // A PID-looking file cannot establish ownership while its lease is held.
    // The supervisor must refuse to guess at a process in this state.
    try std.testing.expectError(error.Busy, cli.rooms_peer_files.tryLockLeaf(io, dir, "peer.pid"));
}

test "rooms-peer malformed replied ledger is preserved and reported" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = "/tmp/rooms-peer-ledger-failure-test";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const corrupt = "{\"answered\":true}\n";
    try cli.rooms_peer_files.overwriteFile(io, dir, "replied.json", corrupt);

    try std.testing.expectError(
        error.LedgerCorrupt,
        cli.rooms_peer_ledger.markReplied(io, gpa, dir, &.{"new-id"}),
    );
    const after = try cli.rooms_peer_files.readFile(io, gpa, dir, "replied.json");
    defer gpa.free(after);
    try std.testing.expectEqualStrings(corrupt, after);
}

test "rooms-peer failed state replacement preserves the last readable state" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = "/tmp/rooms-peer-state-failure-test";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const previous = "{\"status\":\"joined\"}\n";
    try cli.rooms_peer_files.overwriteFile(io, dir, "state.json", previous);

    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        cli.rooms_peer_harness.writeState(io, failing.allocator(), dir, "closed", "alice", "general", "ocapn://room", false, 0),
    );
    const after = try cli.rooms_peer_files.readFile(io, gpa, dir, "state.json");
    defer gpa.free(after);
    try std.testing.expectEqualStrings(previous, after);
}

test "rooms-peer failed ledger fold preserves answered ids" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = "/tmp/rooms-peer-ledger-oom-test";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const previous = "[\"old-id\"]";
    try cli.rooms_peer_files.overwriteFile(io, dir, "replied.json", previous);

    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        cli.rooms_peer_ledger.markReplied(io, failing.allocator(), dir, &.{"new-id"}),
    );
    const after = try cli.rooms_peer_files.readFile(io, gpa, dir, "replied.json");
    defer gpa.free(after);
    try std.testing.expectEqualStrings(previous, after);
}

test "rooms-peer outbox OOM keeps the complete remainder" {
    const remainder = "{\"channel\":\"room\",\"text\":\"keep\"}\n";
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const Ctx = struct {
        fn decide(_: void, _: cli.rooms_peer_harness.OutboxLine) cli.rooms_peer_harness.OutboxLineFate {
            return .drop;
        }
    };
    try std.testing.expectError(
        error.OutOfMemory,
        cli.rooms_peer_harness.compactOutboxRemainder(failing.allocator(), remainder, {}, Ctx.decide),
    );
}

test "rooms-peer pending offer distinguishes capacity from allocation failure" {
    const gpa = std.testing.allocator;
    var table: std.StringHashMapUnmanaged(void) = .{};
    defer {
        var it = table.keyIterator();
        while (it.next()) |key| gpa.free(key.*);
        table.deinit(gpa);
    }
    try std.testing.expectEqual(
        cli.rooms_peer_phase.PendingOfferResult.queued,
        cli.rooms_peer_phase.schedulePendingOffer(gpa, &table, "alice", 1),
    );
    try std.testing.expectEqual(
        cli.rooms_peer_phase.PendingOfferResult.at_capacity,
        cli.rooms_peer_phase.schedulePendingOffer(gpa, &table, "bob", 1),
    );
}

test "rooms-peer malformed state surfaces instead of becoming empty" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = "/tmp/rooms-peer-state-read-failure-test";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);

    try cli.rooms_peer_files.overwriteFile(io, dir, "state.json", "{\n");
    try std.testing.expectError(
        error.StateCorrupt,
        cli.rooms_peer_harness.stateField(io, gpa, dir, "status"),
    );

    try cli.rooms_peer_files.overwriteFile(io, dir, "state.json", "[]\n");
    try std.testing.expectError(
        error.StateCorrupt,
        cli.rooms_peer_harness.stateField(io, gpa, dir, "status"),
    );
}

test "rooms-peer malformed roster and watermark are not accepted as empty" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = "/tmp/rooms-peer-aux-read-failure-test";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);

    try cli.rooms_peer_files.overwriteFile(io, dir, "roster.json", "{\"nicks\":[1]}\n");
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    try std.testing.expectError(
        error.RosterCorrupt,
        cli.rooms_peer_ledger.loadRosterNicks(arena_state.allocator(), io, gpa, dir),
    );

    try cli.rooms_peer_files.overwriteFile(io, dir, "inbox.watermark", "not-a-number\n");
    try std.testing.expectError(
        error.WatermarkCorrupt,
        cli.rooms_peer_ledger.loadInboxWatermark(io, gpa, dir),
    );

    try cli.rooms_peer_files.overwriteFile(io, dir, "outbox.offset", "not-a-number\n");
    try std.testing.expectError(
        error.OutboxOffsetCorrupt,
        cli.rooms_peer_harness.loadOutboxOffset(io, gpa, dir),
    );
}
