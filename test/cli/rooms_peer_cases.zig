//! Hermetic harness goldens for `glowcap app rooms-peer` (no iroh / no CapTP wire).
const std = @import("std");
const cli = @import("cli");
const glowcap = @import("glowcap");

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
    try std.testing.expectEqualStrings("ws://localhost:8000/relay", url);

    try std.testing.expect((try cli.rooms_peer_common.deriveRendezvousUrl(gpa, "https://localhost:8000/locator")) == null);
    try std.testing.expect((try cli.rooms_peer_common.deriveRendezvousUrl(gpa, "ocapn://abc.iroh")) == null);

    const ip = (try cli.rooms_peer_common.deriveRendezvousUrl(gpa, "http://127.0.0.1:8000/locator")).?;
    defer gpa.free(ip);
    try std.testing.expectEqualStrings("ws://127.0.0.1:8000/relay", ip);
}

test "rooms-peer resolveRendezvousUrl prefers GLOWCAP_RENDEZVOUS" {
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

test "rooms-peer admitRelayUrl passes a DNS host through for the resident to resolve" {
    // `RelayUrl.parse` admits validated DNS names, and the keyed-relay resident
    // resolves one at dial time so a resolution failure stays a visible dial
    // failure. Admission therefore keeps the name verbatim; rewriting it to an
    // IP here would be a second resolver whose failures could only become null.
    const gpa = std.testing.allocator;
    const url = (try cli.rooms_peer_common.admitRelayUrl(gpa, "ws://localhost:8000/relay")).?;
    defer gpa.free(url);
    try std.testing.expectEqualStrings("ws://localhost:8000/relay", url);
    const parsed = try glowcap.net.relay.RelayUrl.parse(url);
    try std.testing.expectEqualStrings("localhost", parsed.host);
    try std.testing.expectEqual(@as(u16, 8000), parsed.port);
    try std.testing.expectEqualStrings("/relay", parsed.path);

    // What the grammar refuses stays refused: no scheme, and a host with a
    // byte no DNS name validates.
    try std.testing.expect((try cli.rooms_peer_common.admitRelayUrl(gpa, "http://not-ws")) == null);
    try std.testing.expect((try cli.rooms_peer_common.admitRelayUrl(gpa, "ws://bad_host!:8000/relay")) == null);
}

test "rooms-peer peerCliPrefix for install alias vs product" {
    try std.testing.expectEqualStrings("app rooms-peer ", cli.rooms_peer.peerCliPrefix("glowcap"));
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
    const a = try cli.rooms_peer_ledger.lineId(gpa, 0, "alice", "hi", "room", "");
    defer gpa.free(a);
    const b = try cli.rooms_peer_ledger.lineId(gpa, 0, "alice", "hi", "room", "");
    defer gpa.free(b);
    const c = try cli.rooms_peer_ledger.lineId(gpa, 10, "alice", "hi", "room", "");
    defer gpa.free(c);
    try std.testing.expectEqualStrings(a, b);
    try std.testing.expect(!std.mem.eql(u8, a, c));
    try std.testing.expectEqual(@as(usize, 16), a.len);
}

test "rooms-peer lineId folds dm peer into the id" {
    const gpa = std.testing.allocator;
    const room = try cli.rooms_peer_ledger.lineId(gpa, 0, "bob", "hi", "room", "");
    defer gpa.free(room);
    const dm = try cli.rooms_peer_ledger.lineId(gpa, 0, "bob", "hi", "dm", "bob");
    defer gpa.free(dm);
    try std.testing.expect(!std.mem.eql(u8, room, dm));
}

test "parseOutboxLine room and dm shapes" {
    const gpa = std.testing.allocator;
    const room = try cli.rooms_peer_harness.parseOutboxLine(gpa, "{\"channel\":\"room\",\"text\":\"hi\"}");
    defer room.deinit(gpa);
    try std.testing.expect(!room.is_dm);
    try std.testing.expectEqualStrings("hi", room.text);
    try std.testing.expectEqualStrings("", room.peer);

    const dm = try cli.rooms_peer_harness.parseOutboxLine(gpa, "{\"channel\":\"dm\",\"peer\":\"bob\",\"text\":\"secret\"}");
    defer dm.deinit(gpa);
    try std.testing.expect(dm.is_dm);
    try std.testing.expectEqualStrings("secret", dm.text);
    try std.testing.expectEqualStrings("bob", dm.peer);

    try std.testing.expectError(error.MalformedOutbox, cli.rooms_peer_harness.parseOutboxLine(gpa, "not-json"));

    const bare = try cli.rooms_peer_harness.parseOutboxLine(gpa, "{\"channel\":\"dm\",\"text\":\"no-peer\"}");
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
    try std.testing.expectEqual(@as(usize, 0), try cli.rooms_peer_harness.loadOutboxOffset(io, gpa, dir));
    try std.testing.expectEqual(@as(usize, 0), try cli.rooms_peer_harness.outboxBacklogBytes(io, gpa, dir));
    try cli.rooms_peer_harness.saveOutboxOffset(io, dir, 42);
    try std.testing.expectEqual(@as(usize, 42), try cli.rooms_peer_harness.loadOutboxOffset(io, gpa, dir));
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

    // Another member's lines: scanInbox drops the scanning peer's own author,
    // so the author here must not be the "alice" that scans below.
    const line1 = "{\"kind\":\"msg\",\"channel\":\"room\",\"author\":\"Bob\",\"text\":\"old\"}\n";
    const line2 = "{\"kind\":\"msg\",\"channel\":\"room\",\"author\":\"Bob\",\"text\":\"new\"}\n";
    try cli.rooms_peer_files.overwriteFile(io, dir, "inbox.jsonl", line1 ++ line2);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // No watermark: both lines visible.
    const all = try cli.rooms_peer_ledger.scanInbox(arena, io, dir, "alice");
    try std.testing.expectEqual(@as(usize, 2), all.items.len);

    try cli.rooms_peer_ledger.saveInboxWatermark(io, dir, line1.len);
    const after = try cli.rooms_peer_ledger.scanInbox(arena, io, dir, "alice");
    try std.testing.expectEqual(@as(usize, 1), after.items.len);
    try std.testing.expectEqualStrings("new", after.items[0].text);

    try cli.rooms_peer_ledger.advanceInboxWatermark(io, gpa, dir);
    const none = try cli.rooms_peer_ledger.scanInbox(arena, io, dir, "alice");
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
    try cli.rooms_peer_files.overwriteFile(io, dir, "outbox.jsonl", body);
    try std.testing.expectEqual(body.len, try cli.rooms_peer_harness.outboxBacklogBytes(io, gpa, dir));
    try cli.rooms_peer_harness.saveOutboxOffset(io, dir, body.len);
    try std.testing.expectEqual(@as(usize, 0), try cli.rooms_peer_harness.outboxBacklogBytes(io, gpa, dir));
    // Restart posture: load offset then clamp — undrained prefix remains if offset mid-file.
    try cli.rooms_peer_harness.saveOutboxOffset(io, dir, 10);
    const loaded = cli.rooms_peer_harness.clampOutboxOffset(try cli.rooms_peer_harness.loadOutboxOffset(io, gpa, dir), body.len);
    try std.testing.expectEqual(@as(usize, 10), loaded);
    try std.testing.expectEqual(body.len - 10, try cli.rooms_peer_harness.outboxBacklogBytes(io, gpa, dir));
}

test "rooms-peer first-contact DM queues durably for introduction" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = "/tmp/rooms-peer-first-contact-dm-test";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);

    try cli.rooms_peer_harness.appendOutbox(io, gpa, dir, "hello", "Alice");
    const raw = try cli.rooms_peer_files.readFile(io, gpa, dir, "outbox.jsonl");
    defer gpa.free(raw);
    const parsed = try cli.rooms_peer_harness.parseOutboxLine(gpa, std.mem.trimEnd(u8, raw, "\n"));
    defer parsed.deinit(gpa);
    try std.testing.expect(parsed.is_dm);
    try std.testing.expectEqualStrings("Alice", parsed.peer);
    try std.testing.expectEqualStrings("hello", parsed.text);
    try std.testing.expectEqual(@as(usize, 0), try cli.rooms_peer_harness.loadOutboxOffset(io, gpa, dir));
    try std.testing.expectEqual(raw.len, try cli.rooms_peer_harness.outboxBacklogBytes(io, gpa, dir));
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
        \\{"kind":"msg","channel":"room","author":"Alice","text":"are you getting general?"}
        \\{"kind":"msg","channel":"dm","author":"Alice","text":"hello","peer":"Alice"}
        \\
    ;
    try cli.rooms_peer_files.overwriteFile(io, dir, "inbox.jsonl", inbox);
    try cli.rooms_peer_files.overwriteFile(io, dir, "roster.json", "{\"nicks\":[\"fresh-eyes\",\"agentic-lead\",\"engineering-steward\"]}\n");

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const scanned = try cli.rooms_peer_ledger.scanInbox(arena, io, dir, "fresh-eyes");
    try std.testing.expectEqual(@as(usize, 2), scanned.items.len);
    cli.rooms_peer_ledger.sortPending(scanned.items);
    try std.testing.expectEqualStrings("dm", scanned.items[0].channel);
    try std.testing.expectEqualStrings("room", scanned.items[1].channel);
    try std.testing.expect(cli.rooms_peer_ledger.humanRoomPending(scanned.items, try cli.rooms_peer_ledger.loadRosterNicks(arena, io, gpa, dir)));
}

test "rooms-peer sortPending is DM then @mention then room (one-wake order)" {
    // Hermetic stand-in for multi-surface drain: tick must surface DM before
    // room chatter so a wake that only answers DMs cannot pretend the room
    // was empty. Order is owned by harness.sortPending (verbs.zig uses it).
    var items = [_]cli.rooms_peer_ledger.Pending{
        .{ .id = "c", .channel = "room", .author = "peer", .text = "chatter", .peer = "", .mention = false },
        .{ .id = "a", .channel = "dm", .author = "Alice", .text = "hi", .peer = "Alice", .mention = false },
        .{ .id = "b", .channel = "room", .author = "Alice", .text = "@you", .peer = "", .mention = true },
    };
    cli.rooms_peer_ledger.sortPending(&items);
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

    try cli.rooms_peer_files.overwriteFile(io, dir, "roster.json", "{\"nicks\":[\"agentic-lead\",\"fresh-eyes\"]}\n");
    const inbox =
        \\{"kind":"msg","channel":"room","author":"Alice","text":"general?"}
    ++ "\n" ++
        \\{"kind":"msg","channel":"dm","author":"Alice","peer":"Alice","text":"psst"}
    ++ "\n";
    try cli.rooms_peer_files.overwriteFile(io, dir, "inbox.jsonl", inbox);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const roster = try cli.rooms_peer_ledger.loadRosterNicks(arena, io, gpa, dir);
    const pending = try cli.rooms_peer_ledger.scanInbox(arena, io, dir, "fresh-eyes");
    try std.testing.expectEqual(@as(usize, 2), pending.items.len);
    cli.rooms_peer_ledger.sortPending(pending.items);
    try std.testing.expectEqualStrings("dm", pending.items[0].channel);
    try std.testing.expectEqualStrings("room", pending.items[1].channel);
    try std.testing.expect(cli.rooms_peer_ledger.humanRoomPending(pending.items, roster));

    const ids = [_][]const u8{ pending.items[0].id, pending.items[1].id };
    _ = try cli.rooms_peer_ledger.markReplied(io, gpa, dir, &ids);

    var after_arena = std.heap.ArenaAllocator.init(gpa);
    defer after_arena.deinit();
    const after_alloc = after_arena.allocator();
    const replied = try cli.rooms_peer_ledger.loadReplied(after_alloc, io, dir);
    var remaining: std.ArrayList(cli.rooms_peer_ledger.Pending) = .empty;
    for ((try cli.rooms_peer_ledger.scanInbox(after_alloc, io, dir, "fresh-eyes")).items) |item| {
        if (replied.contains(item.id)) continue;
        try remaining.append(after_alloc, item);
    }
    try std.testing.expectEqual(@as(usize, 0), remaining.items.len);
    try std.testing.expect(!cli.rooms_peer_ledger.humanRoomPending(remaining.items, roster));
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

    const peer_line = cli.rooms_peer_ledger.Pending{
        .id = "1",
        .channel = "room",
        .author = "fresh-eyes",
        .text = "hi",
        .peer = "",
        .mention = false,
    };
    const human_line = cli.rooms_peer_ledger.Pending{
        .id = "2",
        .channel = "room",
        .author = "Alice",
        .text = "hi",
        .peer = "",
        .mention = false,
    };
    const mixed = [_]cli.rooms_peer_ledger.Pending{ peer_line, human_line };

    // No roster → never claim human (avoids stuck_human_room false positive).
    try std.testing.expect(!cli.rooms_peer_ledger.humanRoomPending(&mixed, &.{}));

    try cli.rooms_peer_files.overwriteFile(io, dir, "roster.json", "{\"nicks\":[\"agentic-lead\",\"fresh-eyes\",\"engineering-steward\"]}\n");
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const roster = try cli.rooms_peer_ledger.loadRosterNicks(arena_state.allocator(), io, gpa, dir);
    try std.testing.expectEqual(@as(usize, 3), roster.len);
    try std.testing.expect(!cli.rooms_peer_ledger.humanRoomPending(&[_]cli.rooms_peer_ledger.Pending{peer_line}, roster));
    try std.testing.expect(cli.rooms_peer_ledger.humanRoomPending(&mixed, roster));
    try std.testing.expect(cli.rooms_peer_ledger.humanRoomPending(&[_]cli.rooms_peer_ledger.Pending{human_line}, roster));
}

test "rooms-peer pending inbox offers survive a failed drain and clear on success" {
    // mintInboxFor arrives under the host callback latch; publishGiftable and
    // tell both refuse ReenteredHost there. The offer must queue, then drain
    // from maintain outside the latch. A false offer keeps the nick so the
    // next wake retries. The old inline offer failed once and was never queued.
    const gpa = std.testing.allocator;
    var table: std.StringHashMapUnmanaged(void) = .{};
    defer {
        var it = table.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        table.deinit(gpa);
    }

    _ = cli.rooms_peer.schedulePendingOffer(gpa, &table, "Alice", 1);
    _ = cli.rooms_peer.schedulePendingOffer(gpa, &table, "Alice", 1);
    _ = cli.rooms_peer.schedulePendingOffer(gpa, &table, "unbounded", 1);
    try std.testing.expectEqual(@as(usize, 1), table.count());

    const Fail = struct {
        fn offer(_: void, _: []const u8) bool {
            return false;
        }
    };
    cli.rooms_peer.drainPendingOffers(gpa, &table, {}, Fail.offer);
    try std.testing.expect(table.contains("Alice"));

    const Ok = struct {
        fn offer(_: void, peer: []const u8) bool {
            return std.mem.eql(u8, peer, "Alice");
        }
    };
    cli.rooms_peer.drainPendingOffers(gpa, &table, {}, Ok.offer);
    try std.testing.expectEqual(@as(usize, 0), table.count());
}

test "rooms-peer a failed introduce ages out instead of poisoning the outbox" {
    // A refusal is the one cached thing no object can invalidate: it names a
    // peer that was *not* there, so nothing can report itself gone. Held
    // without a clock, that peer's DM line stays in the remainder forever.
    // Compaction still sends later room posts; the cooldown is so the held
    // DM is retried, not so the rest of the outbox can move.
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

test "rooms-peer outbox compact sends later room lines past a held DM" {
    const gpa = std.testing.allocator;
    const remainder =
        \\{"channel":"dm","peer":"bob","text":"x"}
        \\{"channel":"room","text":"hi"}
        \\{"channel":"dm","peer":"carol","text":"y"}
        \\
    ;
    const Ctx = struct {
        fn decide(_: void, line: cli.rooms_peer_harness.OutboxLine) cli.rooms_peer_harness.OutboxLineFate {
            if (line.is_dm and std.mem.eql(u8, line.peer, "bob")) return .hold;
            return .drop;
        }
    };
    const kept = try cli.rooms_peer_harness.compactOutboxRemainder(gpa, remainder, {}, Ctx.decide);
    defer gpa.free(kept);
    try std.testing.expectEqualStrings("{\"channel\":\"dm\",\"peer\":\"bob\",\"text\":\"x\"}\n", kept);
}

test "rooms-peer outbox compact stop keeps the failed line and the tail" {
    const gpa = std.testing.allocator;
    const remainder =
        \\{"channel":"dm","peer":"bob","text":"x"}
        \\{"channel":"room","text":"hi"}
        \\{"channel":"dm","peer":"carol","text":"y"}
        \\
    ;
    const Ctx = struct {
        fn decide(_: void, line: cli.rooms_peer_harness.OutboxLine) cli.rooms_peer_harness.OutboxLineFate {
            if (line.is_dm and std.mem.eql(u8, line.peer, "bob")) return .hold;
            if (!line.is_dm) return .stop;
            return .drop;
        }
    };
    const kept = try cli.rooms_peer_harness.compactOutboxRemainder(gpa, remainder, {}, Ctx.decide);
    defer gpa.free(kept);
    try std.testing.expectEqualStrings(remainder, kept);
}

test "rooms-peer outbox compact keeps an incomplete trailing write" {
    const gpa = std.testing.allocator;
    const remainder = "{\"channel\":\"room\",\"text\":\"hi\"}\npartial";
    const Ctx = struct {
        fn decide(_: void, _: cli.rooms_peer_harness.OutboxLine) cli.rooms_peer_harness.OutboxLineFate {
            return .drop;
        }
    };
    const kept = try cli.rooms_peer_harness.compactOutboxRemainder(gpa, remainder, {}, Ctx.decide);
    defer gpa.free(kept);
    try std.testing.expectEqualStrings("partial", kept);
}
