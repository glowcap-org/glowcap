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
