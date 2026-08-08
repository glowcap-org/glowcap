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

test "rooms-peer deriveRendezvousUrl from http locator bootstrap" {
    const gpa = std.testing.allocator;
    const url = (try cli.rooms_peer_common.deriveRendezvousUrl(gpa, "http://localhost:8000/locator")).?;
    defer gpa.free(url);
    try std.testing.expectEqualStrings("ws://127.0.0.1:8000/relay", url);

    try std.testing.expect((try cli.rooms_peer_common.deriveRendezvousUrl(gpa, "https://localhost:8000/locator")) == null);
    try std.testing.expect((try cli.rooms_peer_common.deriveRendezvousUrl(gpa, "ocapn://abc.iroh")) == null);
}

test "rooms-peer resolveRendezvousUrl prefers PANCAKE_RENDEZVOUS" {
    const gpa = std.testing.allocator;
    const url = (try cli.rooms_peer_common.resolveRendezvousUrl(
        gpa,
        "ws://127.0.0.1:9/relay",
        "http://localhost:8000/locator",
    )).?;
    defer gpa.free(url);
    try std.testing.expectEqualStrings("ws://127.0.0.1:9/relay", url);

    try std.testing.expectError(
        error.InvalidRendezvousUrl,
        cli.rooms_peer_common.resolveRendezvousUrl(gpa, "http://not-ws", "http://localhost:8000/locator"),
    );
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
    try cli.rooms_peer_harness.saveOutboxOffset(io, dir, 42);
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
    try cli.rooms_peer_harness.saveOutboxOffset(io, dir, body.len);
    try std.testing.expectEqual(@as(usize, 0), cli.rooms_peer_harness.outboxBacklogBytes(io, gpa, dir));
    // Restart posture: load offset then clamp — undrained prefix remains if offset mid-file.
    try cli.rooms_peer_harness.saveOutboxOffset(io, dir, 10);
    const loaded = cli.rooms_peer_harness.clampOutboxOffset(cli.rooms_peer_harness.loadOutboxOffset(io, gpa, dir), body.len);
    try std.testing.expectEqual(@as(usize, 10), loaded);
    try std.testing.expectEqual(body.len - 10, cli.rooms_peer_harness.outboxBacklogBytes(io, gpa, dir));
}

test "rooms-peer dm_backchannels armed map fails closed when missing" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = "/tmp/rooms-peer-dm-backchannels-test";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);

    // Missing file → not armed (no false-sent --dm).
    try std.testing.expect(!cli.rooms_peer_harness.dmBackchannelArmed(io, gpa, dir, "Jim"));

    cli.rooms_peer_harness.persistDmBackchannels(io, gpa, dir, &.{ "Jim", "Bob" });
    try std.testing.expect(cli.rooms_peer_harness.dmBackchannelArmed(io, gpa, dir, "Jim"));
    try std.testing.expect(cli.rooms_peer_harness.dmBackchannelArmed(io, gpa, dir, "Bob"));
    try std.testing.expect(!cli.rooms_peer_harness.dmBackchannelArmed(io, gpa, dir, "Eve"));

    cli.rooms_peer_harness.persistDmBackchannels(io, gpa, dir, &.{});
    try std.testing.expect(!cli.rooms_peer_harness.dmBackchannelArmed(io, gpa, dir, "Jim"));
}

test "rooms-peer one-wake both-surfaces: DM ranks before human room" {
    // Hermetic golden for multi-surface drain: one wake must surface BOTH a
    // human DM and a human room line, with DM first — so agents cannot drain
    // DMs and leave room starved in the same tick JSON.
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = "/tmp/rooms-peer-one-wake-both-surfaces-test";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);

    // Room line first in the file; sort must still put DM first.
    const inbox =
        \\{"kind":"msg","channel":"room","author":"Jim","text":"are you getting general?"}
        \\{"kind":"msg","channel":"dm","author":"Jim","text":"hello","peer":"Jim"}
        \\
    ;
    try cli.rooms_peer_harness.overwriteFile(io, dir, "inbox.jsonl", inbox);
    try cli.rooms_peer_harness.overwriteFile(io, dir, "roster.json", "{\"nicks\":[\"fresh-eyes\",\"agentic-lead\",\"engineering-steward\"]}\n");

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const scanned = cli.rooms_peer_harness.scanInbox(arena, io, dir, "fresh-eyes");
    try std.testing.expectEqual(@as(usize, 2), scanned.items.len);
    cli.rooms_peer_harness.sortPending(scanned.items);
    try std.testing.expectEqualStrings("dm", scanned.items[0].channel);
    try std.testing.expectEqualStrings("room", scanned.items[1].channel);
    try std.testing.expect(cli.rooms_peer_harness.humanRoomPending(scanned.items, cli.rooms_peer_harness.loadRosterNicks(arena, io, gpa, dir)));
}

test "rooms-peer sortPending is DM then @mention then room (one-wake order)" {
    // Hermetic stand-in for multi-surface drain: tick must surface DM before
    // room chatter so a wake that only answers DMs cannot pretend the room
    // was empty. Order is owned by harness.sortPending (verbs.zig uses it).
    var items = [_]cli.rooms_peer_harness.Pending{
        .{ .id = "c", .channel = "room", .author = "peer", .text = "chatter", .peer = "", .mention = false },
        .{ .id = "a", .channel = "dm", .author = "Jim", .text = "hi", .peer = "Jim", .mention = false },
        .{ .id = "b", .channel = "room", .author = "Jim", .text = "@you", .peer = "", .mention = true },
    };
    cli.rooms_peer_harness.sortPending(&items);
    try std.testing.expectEqualStrings("dm", items[0].channel);
    try std.testing.expectEqualStrings("a", items[0].id);
    try std.testing.expect(items[1].mention);
    try std.testing.expectEqualStrings("b", items[1].id);
    try std.testing.expectEqualStrings("room", items[2].channel);
    try std.testing.expectEqualStrings("c", items[2].id);
}

test "rooms-peer one-wake clears DM and human room together" {
    // Stranger failure: answer the DM, leave human room pending, claim idle.
    // After markReplied on both ids from one sorted wake, neither resurfaces.
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = "/tmp/rooms-peer-one-wake-both-surfaces";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);

    try cli.rooms_peer_harness.overwriteFile(io, dir, "roster.json", "{\"nicks\":[\"agentic-lead\",\"fresh-eyes\"]}\n");
    const inbox =
        \\{"kind":"msg","channel":"room","author":"Jim","text":"general?"}
    ++ "\n" ++
        \\{"kind":"msg","channel":"dm","author":"Jim","peer":"Jim","text":"psst"}
    ++ "\n";
    try cli.rooms_peer_harness.overwriteFile(io, dir, "inbox.jsonl", inbox);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const roster = cli.rooms_peer_harness.loadRosterNicks(arena, io, gpa, dir);
    const pending = cli.rooms_peer_harness.scanInbox(arena, io, dir, "fresh-eyes");
    try std.testing.expectEqual(@as(usize, 2), pending.items.len);
    cli.rooms_peer_harness.sortPending(pending.items);
    try std.testing.expectEqualStrings("dm", pending.items[0].channel);
    try std.testing.expectEqualStrings("room", pending.items[1].channel);
    try std.testing.expect(cli.rooms_peer_harness.humanRoomPending(pending.items, roster));

    const ids = [_][]const u8{ pending.items[0].id, pending.items[1].id };
    _ = try cli.rooms_peer_harness.markReplied(io, gpa, dir, &ids);

    var after_arena = std.heap.ArenaAllocator.init(gpa);
    defer after_arena.deinit();
    const after_alloc = after_arena.allocator();
    const replied = cli.rooms_peer_harness.loadReplied(after_alloc, io, dir);
    var remaining: std.ArrayList(cli.rooms_peer_harness.Pending) = .empty;
    for (cli.rooms_peer_harness.scanInbox(after_alloc, io, dir, "fresh-eyes").items) |item| {
        if (replied.contains(item.id)) continue;
        try remaining.append(after_alloc, item);
    }
    try std.testing.expectEqual(@as(usize, 0), remaining.items.len);
    try std.testing.expect(!cli.rooms_peer_harness.humanRoomPending(remaining.items, roster));
}

test "rooms-peer humanRoomPending needs roster; peer chatter is not human" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = "/tmp/rooms-peer-roster-filter-test";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);

    const peer_line = cli.rooms_peer_harness.Pending{
        .id = "1",
        .channel = "room",
        .author = "fresh-eyes",
        .text = "hi",
        .peer = "",
        .mention = false,
    };
    const human_line = cli.rooms_peer_harness.Pending{
        .id = "2",
        .channel = "room",
        .author = "Jim",
        .text = "hi",
        .peer = "",
        .mention = false,
    };
    const mixed = [_]cli.rooms_peer_harness.Pending{ peer_line, human_line };

    // No roster → never claim human (avoids stuck_human_room false positive).
    try std.testing.expect(!cli.rooms_peer_harness.humanRoomPending(&mixed, &.{}));

    try cli.rooms_peer_harness.overwriteFile(io, dir, "roster.json", "{\"nicks\":[\"agentic-lead\",\"fresh-eyes\",\"engineering-steward\"]}\n");
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const roster = cli.rooms_peer_harness.loadRosterNicks(arena_state.allocator(), io, gpa, dir);
    try std.testing.expectEqual(@as(usize, 3), roster.len);
    try std.testing.expect(!cli.rooms_peer_harness.humanRoomPending(&[_]cli.rooms_peer_harness.Pending{peer_line}, roster));
    try std.testing.expect(cli.rooms_peer_harness.humanRoomPending(&mixed, roster));
    try std.testing.expect(cli.rooms_peer_harness.humanRoomPending(&[_]cli.rooms_peer_harness.Pending{human_line}, roster));
}

test "rooms-peer a failed introduce ages out instead of poisoning the outbox" {
    // A refusal is the one cached thing no object can invalidate: it names a
    // peer that was *not* there, so nothing can report itself gone. Held
    // without a clock, the outbox drain stops at that peer's line and never
    // advances — silencing every later line behind it, room posts included —
    // until the room session itself drops, which for a healthy long-lived
    // session never happens.
    const gpa = std.testing.allocator;
    var table: std.StringHashMapUnmanaged(u32) = .{};
    defer {
        var it = table.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        table.deinit(gpa);
    }

    try table.put(gpa, try gpa.dupe(u8, "bob"), 2);
    try table.put(gpa, try gpa.dupe(u8, "carol"), 0);

    // carol's wait is already over, so she is retried on this wake; bob's is
    // not, so he still waits. A refusal that expired immediately would be no
    // cooldown at all.
    try std.testing.expectEqual(@as(usize, 1), cli.rooms_peer.expireCooldowns(gpa, &table));
    try std.testing.expect(!table.contains("carol"));
    try std.testing.expect(table.contains("bob"));

    // And bob's clears on his own schedule rather than never. The keys are
    // freed with the rows, which the testing allocator checks.
    var wakes: usize = 0;
    while (table.count() != 0 and wakes < 8) : (wakes += 1) {
        _ = cli.rooms_peer.expireCooldowns(gpa, &table);
    }
    try std.testing.expectEqual(@as(usize, 0), table.count());
    try std.testing.expect(wakes > 0);
}
