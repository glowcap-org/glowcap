//! Hermetic harness goldens for `pancake app rooms-peer` (no iroh / no CapTP wire).
const std = @import("std");
const cli = @import("cli");

test "rooms-peer usage and unsupervised map to exit usage" {
    try std.testing.expectEqual(cli.exit_codes.usage, cli.rooms_peer.verbExit(error.UsageFailed).?);
    try std.testing.expectEqual(cli.exit_codes.usage, cli.rooms_peer.verbExit(error.Unsupervised).?);
    try std.testing.expectEqual(cli.exit_codes.usage, cli.rooms_peer.verbExit(error.MissingFlags).?);
    try std.testing.expectEqual(cli.exit_codes.internal, cli.rooms_peer.verbExit(error.PeerFailed).?);
    try std.testing.expect(cli.rooms_peer.verbExit(error.OutOfMemory) == null);
}

test "rooms-peer peerCliPrefix for install alias vs product" {
    try std.testing.expectEqualStrings("app rooms-peer ", cli.rooms_peer.peerCliPrefix("pancake"));
    try std.testing.expectEqualStrings("", cli.rooms_peer.peerCliPrefix("rooms-peer"));
}

test "rooms-peer peer is hidden from help and completion" {
    const gpa = std.testing.allocator;
    const root = &cli.tree.root;
    const app = root.findChild("app").?;
    const rp = app.findChild("rooms-peer").?;
    const peer = rp.findChild("peer").?;
    try std.testing.expect(peer.hidden_from_help);

    const path = [_]*const cli.cmd_types.Command{ root, app, rp };
    const help = try cli.cmd_help.writeNodeHelpAlloc(gpa, &path);
    defer gpa.free(help);
    try std.testing.expect(std.mem.indexOf(u8, help, "\n  peer") == null);
    try std.testing.expect(std.mem.indexOf(u8, help, "\n  tick") != null);

    const bash = try cli.cmd_completion.emitAlloc(gpa, root, .bash);
    defer gpa.free(bash);
    try std.testing.expect(std.mem.indexOf(u8, bash, "rooms-peer peer") == null);
    try std.testing.expect(std.mem.indexOf(u8, bash, "rooms-peer tick") != null);

    const fish = try cli.cmd_completion.emitAlloc(gpa, root, .fish);
    defer gpa.free(fish);
    // rooms-peer node must not offer the supervised daemon as a completable child.
    const rp_mark = std.mem.indexOf(u8, fish, "__fish_seen_subcommand_from rooms-peer");
    try std.testing.expect(rp_mark != null);
    const rp_line_end = std.mem.indexOfPos(u8, fish, rp_mark.?, "\n") orelse fish.len;
    const rp_line = fish[rp_mark.?..rp_line_end];
    try std.testing.expect(std.mem.indexOf(u8, rp_line, "-a 'peer'") == null);
    try std.testing.expect(std.mem.indexOf(u8, rp_line, "-a 'tick'") != null);
}

test "rooms-peer lineId is stable across rescans and distinct by offset" {
    const gpa = std.testing.allocator;
    const a = cli.rooms_peer_harness.lineId(gpa, 0, "alice", "hi", "room", "");
    defer gpa.free(a);
    const b = cli.rooms_peer_harness.lineId(gpa, 0, "alice", "hi", "room", "");
    defer gpa.free(b);
    const c = cli.rooms_peer_harness.lineId(gpa, 10, "alice", "hi", "room", "");
    defer gpa.free(c);
    try std.testing.expectEqualStrings(a, b);
    try std.testing.expect(!std.mem.eql(u8, a, c));
    try std.testing.expectEqual(@as(usize, 16), a.len);
}

test "rooms-peer lineId folds dm peer into the id" {
    const gpa = std.testing.allocator;
    const room = cli.rooms_peer_harness.lineId(gpa, 0, "bob", "hi", "room", "");
    defer gpa.free(room);
    const dm = cli.rooms_peer_harness.lineId(gpa, 0, "bob", "hi", "dm", "bob");
    defer gpa.free(dm);
    try std.testing.expect(!std.mem.eql(u8, room, dm));
}

test "parseOutboxLine room and dm shapes" {
    const gpa = std.testing.allocator;
    const room = cli.rooms_peer_harness.parseOutboxLine(gpa, "{\"channel\":\"room\",\"text\":\"hi\"}").?;
    defer room.deinit(gpa);
    try std.testing.expect(!room.is_dm);
    try std.testing.expectEqualStrings("hi", room.text);
    try std.testing.expectEqualStrings("", room.peer);

    const dm = cli.rooms_peer_harness.parseOutboxLine(gpa, "{\"channel\":\"dm\",\"peer\":\"bob\",\"text\":\"secret\"}").?;
    defer dm.deinit(gpa);
    try std.testing.expect(dm.is_dm);
    try std.testing.expectEqualStrings("secret", dm.text);
    try std.testing.expectEqualStrings("bob", dm.peer);

    try std.testing.expect(cli.rooms_peer_harness.parseOutboxLine(gpa, "not-json") == null);

    const bare = cli.rooms_peer_harness.parseOutboxLine(gpa, "{\"channel\":\"dm\",\"text\":\"no-peer\"}").?;
    defer bare.deinit(gpa);
    try std.testing.expect(bare.is_dm);
    try std.testing.expectEqualStrings("", bare.peer);
}

test "rooms-peer outbox offset clamps and never invents EOF" {
    const h = cli.rooms_peer_harness;
    try std.testing.expectEqual(@as(usize, 0), h.clampOutboxOffset(0, 0));
    try std.testing.expectEqual(@as(usize, 0), h.clampOutboxOffset(10, 0));
    try std.testing.expectEqual(@as(usize, 5), h.clampOutboxOffset(5, 10));
    try std.testing.expectEqual(@as(usize, 10), h.clampOutboxOffset(99, 10));
}

test "rooms-peer outbox.offset persists and missing means zero not EOF" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = "/tmp/rooms-peer-outbox-offset-test";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);

    // Missing offset must not invent EOF, or undrained lines vanish on restart.
    try std.testing.expectEqual(@as(usize, 0), cli.rooms_peer_harness.loadOutboxOffset(io, gpa, dir));
    try std.testing.expectEqual(@as(usize, 0), cli.rooms_peer_harness.outboxBacklogBytes(io, gpa, dir));
    cli.rooms_peer_harness.saveOutboxOffset(io, dir, 42);
    try std.testing.expectEqual(@as(usize, 42), cli.rooms_peer_harness.loadOutboxOffset(io, gpa, dir));
    try std.testing.expectEqual(@as(usize, 40), cli.rooms_peer_harness.clampOutboxOffset(42, 40));
}

test "rooms-peer inbox.watermark hides scrollback from scanInbox" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = "/tmp/rooms-peer-inbox-watermark-test";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);

    const line1 = "{\"kind\":\"msg\",\"channel\":\"room\",\"author\":\"Jim\",\"text\":\"old\"}\n";
    const line2 = "{\"kind\":\"msg\",\"channel\":\"room\",\"author\":\"Jim\",\"text\":\"new\"}\n";
    try cli.rooms_peer_harness.overwriteFile(io, dir, "inbox.jsonl", line1 ++ line2);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // No watermark: both lines visible.
    const all = cli.rooms_peer_harness.scanInbox(arena, io, dir, "alice");
    try std.testing.expectEqual(@as(usize, 2), all.items.len);

    cli.rooms_peer_harness.saveInboxWatermark(io, dir, line1.len);
    const after = cli.rooms_peer_harness.scanInbox(arena, io, dir, "alice");
    try std.testing.expectEqual(@as(usize, 1), after.items.len);
    try std.testing.expectEqualStrings("new", after.items[0].text);

    cli.rooms_peer_harness.advanceInboxWatermark(io, gpa, dir);
    const none = cli.rooms_peer_harness.scanInbox(arena, io, dir, "alice");
    try std.testing.expectEqual(@as(usize, 0), none.items.len);
}

test "rooms-peer outbox backlog reflects undrained bytes after offset persist" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = "/tmp/rooms-peer-outbox-backlog-test";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);

    const body = "{\"channel\":\"room\",\"text\":\"a\"}\n{\"channel\":\"room\",\"text\":\"b\"}\n";
    try cli.rooms_peer_harness.overwriteFile(io, dir, "outbox.jsonl", body);
    try std.testing.expectEqual(body.len, cli.rooms_peer_harness.outboxBacklogBytes(io, gpa, dir));
    cli.rooms_peer_harness.saveOutboxOffset(io, dir, body.len);
    try std.testing.expectEqual(@as(usize, 0), cli.rooms_peer_harness.outboxBacklogBytes(io, gpa, dir));
    // Restart posture: load offset then clamp — undrained prefix remains if offset mid-file.
    cli.rooms_peer_harness.saveOutboxOffset(io, dir, 10);
    const loaded = cli.rooms_peer_harness.clampOutboxOffset(cli.rooms_peer_harness.loadOutboxOffset(io, gpa, dir), body.len);
    try std.testing.expectEqual(@as(usize, 10), loaded);
    try std.testing.expectEqual(body.len - 10, cli.rooms_peer_harness.outboxBacklogBytes(io, gpa, dir));
}
