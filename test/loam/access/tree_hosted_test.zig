//! Hosted tree calls through a real CapTP caller: a receipt-backed call creates
//! a child, a dependent facet shares a listed node, and one call moves a node
//! between two others with every change in one batch. Authority is the managed
//! access contract in ADR-0046.
const std = @import("std");
const t = @import("tree_fixture.zig");
const h = t.h;

const ExportProbe = struct {
    pub fn handle(_: *@This(), _: *h.driver.HostTurn, _: ?[]const u8, _: h.driver.Args) !h.driver.Value {
        return .void;
    }
};

// Keep successful ordinary projections so the next new actor still needs the
// growth that failed. No map capacity or export table is edited by the test.
fn reachExportGrowth(tree: *t.Tree) !void {
    const port = &tree.client.pair.b.served.port;
    const allocator = port.allocator;
    defer port.allocator = allocator;
    for (0..64) |_| {
        const actor = try tree.server.host.vat.spawn(h.driver.Hosting(ExportProbe), .{ .inner = .{} });
        defer tree.server.host.vat.releaseActor(actor.local);
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
        port.allocator = failing.allocator();
        defer port.allocator = allocator;
        _ = port.prepareProjection(&tree.server.host.vat, actor) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(failing.has_induced_failure);
            return;
        };
        try std.testing.expect(!failing.has_induced_failure);
    }
    return error.NoExportGrowth;
}

test "loam hosted creation retries a postcommit export allocation refusal without repeating its effect" {
    var backend = try h.loam.Volatile.init(h.a, h.f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var store: h.loam.core.Store = undefined;
    const data = try open(&backend, &store);
    defer store.deinit() catch unreachable;
    var tree: t.Tree = undefined;
    try tree.init(&store, &backend, data);
    defer tree.deinit();
    // This fixture negotiates the default profile. The proof concerns native
    // export ownership after commit, independently of encoding the reply.
    try std.testing.expectEqual(t.s.model.Preference.default_offer.codec, tree.client.pair.b.served.port.peer.session_state.codec);
    try std.testing.expectEqual(t.s.model.Preference.default_offer.captp_version, tree.client.pair.b.served.port.peer.session_state.captp_version);
    try reachExportGrowth(&tree);

    var answer: t.s.captures.CapturedRef = .{};
    const arguments = [_]t.s.model.Argument{ .{ .integer = 1 }, .{ .string = "add" } };
    try tree.client.send(tree.client.parent, "mutate", &arguments, &answer);
    const batch = try tree.server.untilWrite(&backend);
    const index = tree.server.attached.writing.?.operation.?;
    const op = &tree.server.attached.operations[index];
    const revision = store.metadata.revision;
    const outcome = backend.commit(batch);
    try std.testing.expect(outcome == .committed);
    try tree.server.attached.completeWrite(batch.ticket, outcome);
    try std.testing.expect(op.phase == .settling);
    try std.testing.expect(answer.ref == null and !answer.broken);
    try std.testing.expectEqual(revision + 1, store.metadata.revision);
    const committed = store.metadata;
    const result = op.reply.capability;
    const endpoint = try tree.server.attached.designated(result);
    const actor = tree.server.host.localActorFor(result).?.local;
    const roots = tree.server.host.vat.actors.get(actor).?.roots;
    const retains = tree.server.host.capabilities.retainCount(result);
    const resolver = op.resolver;
    const pending = tree.server.attached.pending_bytes;
    const invocations = tree.server.attached.stats.invocations;
    const resolver_count = tree.server.host.resolver_index.count();
    const routes = tree.server.host.node.foreign_imports.count();
    const port = &tree.client.pair.b.served.port;
    try std.testing.expect(!port.reverse_exports.contains(actor));
    try std.testing.expect(roots > 0 and retains != null and retains.? > 0);
    try std.testing.expect(pending > 0 and resolver_count > 0);
    const exports = port.exports.count();
    const reverse = port.reverse_exports.count();
    const positions = port.peer.session_state.exports.len();
    const allocator = port.allocator;
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    port.allocator = failing.allocator();
    defer {
        port.allocator = allocator;
        // An assertion failure must not hide its cause behind Busy teardown.
        if (op.phase != .free) tree.server.drain(&backend) catch unreachable;
    }
    try std.testing.expectError(error.OutOfMemory, tree.server.attached.advance());
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(positions, port.peer.session_state.exports.len());
    try std.testing.expectEqual(exports, port.exports.count());
    try std.testing.expectEqual(reverse, port.reverse_exports.count());
    try std.testing.expectEqual(roots, tree.server.host.vat.actors.get(actor).?.roots);
    try std.testing.expectEqual(retains, tree.server.host.capabilities.retainCount(result));
    try std.testing.expectEqual(resolver_count, tree.server.host.resolver_index.count());
    try std.testing.expectEqual(routes, tree.server.host.node.foreign_imports.count());
    try std.testing.expectEqualDeep(resolver, op.resolver);
    try std.testing.expect(op.phase == .settling and op.reply.capability.eql(result));
    try std.testing.expectEqual(pending, tree.server.attached.pending_bytes);
    try std.testing.expectEqualDeep(committed, store.metadata);
    try std.testing.expect(answer.ref == null and !answer.broken);

    port.allocator = allocator;
    try tree.server.attached.advance();
    try tree.client.pump();
    const child = try answer.require();
    try std.testing.expectEqual(invocations, tree.server.attached.stats.invocations);
    try std.testing.expectEqual(@as(usize, 0), tree.server.attached.pending_bytes);
    try std.testing.expectEqual(resolver_count - 1, tree.server.host.resolver_index.count());
    try std.testing.expectEqualDeep(committed, store.metadata);
    const replayed = try tree.add(&backend, tree.client.parent, 1);
    // Every-turn sleeping may restore a fresh actor and wire name. The exact
    // durable endpoint, rather than that ephemeral name, is receipt identity.
    const replay_actor = port.refForExport(replayed.far.import_position.int()) orelse return error.NoReplayExport;
    const replay_capability = try tree.server.host.liftLocalActor(replay_actor);
    defer tree.server.host.releaseCapabilityTerminal(replay_capability, null);
    try std.testing.expect(endpoint.eql(try tree.server.attached.designated(replay_capability)));
    try std.testing.expectEqual(@as(i64, 0), try tree.count(&backend, child));
    try std.testing.expectEqual(committed.revision, store.metadata.revision);
    try std.testing.expectEqual(@as(i64, 3), try tree.count(&backend, tree.client.parent));
    try std.testing.expectEqualDeep(t.Latest{ .created = 1, .content = 1 }, try t.latest(&store, &backend, data.owner));
    try std.testing.expectEqual(@as(usize, 0), tree.server.attached.pending_bytes);
}

fn open(backend: *h.loam.Volatile, store: *h.loam.core.Store) !h.Data {
    store.* = try h.loam.core.Store.init(h.a, try backend.open(), &h.schemas, h.limits);
    return h.seedSubtree(store, backend, 2);
}

test "loam hosted tree creates children, shares a listed node, and moves a node in one batch" {
    var backend = try h.loam.Volatile.init(h.a, h.f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var store: h.loam.core.Store = undefined;
    const data = try open(&backend, &store);
    defer store.deinit() catch unreachable;
    var tree: t.Tree = undefined;
    try tree.init(&store, &backend, data);
    defer tree.deinit();
    const root = tree.client.parent;
    // Each creation replies with the child it made, which the seeded root's
    // two fields put at 2 and 3.
    const first = try tree.add(&backend, root, 1);
    const second = try tree.add(&backend, root, 2);
    try std.testing.expectEqual(@as(i64, 4), try tree.count(&backend, root));
    try std.testing.expectEqualDeep(t.Latest{ .created = 1, .content = 1 }, try t.latest(&store, &backend, data.owner));
    // A retried creation replays its receipt, creates nothing more, and
    // replies with the same child.
    const replayed = try tree.add(&backend, root, 2);
    try std.testing.expectEqual(@as(i64, 4), try tree.count(&backend, root));

    _ = try tree.add(&backend, first, 3);
    try std.testing.expectEqual(@as(i64, 1), try tree.count(&backend, first));
    try std.testing.expectEqual(@as(i64, 1), try tree.count(&backend, try tree.open(&backend, root, 2)));

    // A refused move leaves every record as it was and spends no sequence.
    const leaf = try tree.open(&backend, first, 0);
    var refused: t.Outcome = .{};
    try tree.mutate(&backend, first, 4, "move-fail", &.{ .{ .reference = leaf }, .{ .reference = second } }, &refused);
    try std.testing.expectEqualStrings("Refused", refused.reason());
    try std.testing.expectEqual(@as(i64, 1), try tree.count(&backend, first));
    try std.testing.expectEqual(@as(i64, 0), try tree.count(&backend, second));
    // A node is moved only from a node whose fields hold it.
    var unlisted: t.Outcome = .{};
    try tree.mutate(&backend, second, 4, "move", &.{ .{ .reference = leaf }, .{ .reference = first } }, &unlisted);
    try std.testing.expectEqualStrings("NotListed", unlisted.reason());

    const before = store.metadata.revision;
    var moved: t.Outcome = .{};
    try tree.mutate(&backend, first, 4, "move", &.{ .{ .reference = leaf }, .{ .reference = second } }, &moved);
    try std.testing.expectEqual(@as(?i64, 1), moved.value);
    try std.testing.expectEqual(before + 1, store.metadata.revision);
    // One batch names the moved node and both nodes whose fields changed.
    try std.testing.expectEqualDeep(t.Latest{ .moved = 1, .content = 2 }, try t.latest(&store, &backend, data.owner));
    try std.testing.expectEqual(@as(i64, 0), try tree.count(&backend, first));
    try std.testing.expectEqual(@as(i64, 1), try tree.count(&backend, second));
    try std.testing.expectEqual(@as(i64, 1), try tree.count(&backend, replayed));
    // The moved node is reachable through its new home.
    const relocated = try tree.open(&backend, second, 0);
    try std.testing.expectEqual(@as(i64, 0), try tree.count(&backend, relocated));

    // Two content records change together in one batch.
    var both: t.Outcome = .{};
    try tree.mutate(&backend, second, 5, "bump-both", &.{.{ .integer = 0 }}, &both);
    try std.testing.expectEqual(@as(?i64, 1), both.value);
    try std.testing.expectEqualDeep(t.Latest{ .content = 2 }, try t.latest(&store, &backend, data.owner));
    // A participant must be named by a field that holds a node.
    var stray: t.Outcome = .{};
    try tree.mutate(&backend, second, 6, "bump-both", &.{.{ .integer = 7 }}, &stray);
    try std.testing.expectEqualStrings("NoSuchEdge", stray.reason());

    // A share of a listed node binds that node under the reader's own grant.
    var derived: t.s.captures.CapturedRef = .{};
    try tree.call(&backend, second, "derive", &.{ .{ .integer = 1 }, .{ .integer = 0 }, .{ .integer = 0 } }, &derived);
    const shared = try derived.require();
    // The same derivation sequence through another node is a changed intent.
    var elsewhere: t.Outcome = .{};
    try tree.call(&backend, relocated, "derive", &.{ .{ .integer = 1 }, .{ .integer = 0 }, .{ .integer = 0 } }, &elsewhere);
    try std.testing.expectEqualStrings("OperationConflict", elsewhere.reason());
    try std.testing.expectEqual(@as(i64, 1), try tree.count(&backend, shared));
    // Reading through the share is enough. Changing through it is not.
    var denied: t.Outcome = .{};
    try tree.mutate(&backend, shared, 1, "add", &.{}, &denied);
    try std.testing.expectEqualStrings("Denied", denied.reason());
    // A share that may post at one node still cannot reach a node below it.
    var posting: t.s.captures.CapturedRef = .{};
    try tree.call(&backend, second, "derive", &.{ .{ .integer = 2 }, .{ .integer = 1 }, .{ .integer = 0 } }, &posting);
    var outside: t.Outcome = .{};
    try tree.mutate(&backend, try posting.require(), 1, "bump-both", &.{.{ .integer = 0 }}, &outside);
    try std.testing.expectEqualStrings("OutOfScope", outside.reason());
    // A child made through that share comes back under the share's own
    // grant, so the reply reaches no further than the share does.
    const made = try tree.add(&backend, try posting.require(), 1);
    var beyond: t.Outcome = .{};
    try tree.call(&backend, made, "count", &.{}, &beyond);
    try std.testing.expectEqualStrings("OutOfScope", beyond.reason());
}

test "loam hosted tree call bounds count each declared participant" {
    const plain = try h.access.invocationAllocationBound(.{ .receipt = true });
    const two = try h.access.invocationAllocationBound(.{ .receipt = true, .participants = 2 });
    try std.testing.expect(two.bytes > plain.bytes);
    // A creating call holds the child and its facet and replies with the facet.
    const creates = try h.access.invocationAllocationBound(.{ .receipt = true, .creates = true });
    const spelled = try h.access.invocationAllocationBound(.{ .receipt = true, .reply = .{ .values = 1, .capabilities = 1 }, .held_occurrences = 2 });
    try std.testing.expectEqual(spelled.bytes, creates.bytes);
    try std.testing.expect(creates.bytes > plain.bytes);
    try std.testing.expectError(error.TooManyParticipants, h.access.invocationAllocationBound(.{ .participants = h.access.max_participants + 1 }));
}

const Capture = @import("description_fixture.zig").Capture;

/// One observation reply's cursor, changed flag, and notice symbols.
const Observed = struct {
    cursor: [@sizeOf(h.c.storage.Observation.Cursor)]u8,
    changed: bool,
    notices: []const t.s.model.Argument,

    fn of(capture: *Capture) !Observed {
        const value = capture.value orelse return error.VowDidNotSettle;
        if (value != .tagged or value.tagged.value.len != 5) return error.NotAnObservation;
        const fields = value.tagged.value;
        return .{ .cursor = fields[0].bytes[0..@sizeOf(h.c.storage.Observation.Cursor)].*, .changed = fields[3].boolean, .notices = fields[4].list };
    }

    fn has(self: Observed, notice: []const u8) bool {
        for (self.notices) |item| if (std.mem.eql(u8, item.symbol, notice)) return true;
        return false;
    }
};

fn poll(tree: *t.Tree, backend: anytype, arena: std.mem.Allocator, receiver: t.s.model.Reference, cursor: ?*const [@sizeOf(h.c.storage.Observation.Cursor)]u8) !Observed {
    var answer: Capture = .{ .arena = arena };
    try tree.call(backend, receiver, "poll", if (cursor) |bytes| &.{.{ .bytes = bytes }} else &.{}, &answer);
    return Observed.of(&answer);
}

fn observe(tree: *t.Tree, backend: anytype, arena: std.mem.Allocator, target: t.s.model.Reference, sequence: i64) !t.s.model.Reference {
    var registration: Capture = .{ .arena = arena };
    try tree.mutate(backend, target, sequence, "observe", &.{}, &registration);
    const pair = registration.value orelse return error.VowDidNotSettle;
    return pair.list[0].reference;
}

test "loam hosted tree observation reports changes below its target only to a subtree grant" {
    var backend = try h.loam.Volatile.init(h.a, h.f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var store: h.loam.core.Store = undefined;
    const data = try open(&backend, &store);
    defer store.deinit() catch unreachable;
    var tree: t.Tree = undefined;
    try tree.init(&store, &backend, data);
    defer tree.deinit();
    var memory = std.heap.ArenaAllocator.init(h.a);
    defer memory.deinit();
    const arena = memory.allocator();
    const root = tree.client.parent;

    const child = try tree.add(&backend, root, 1);
    // The seeded root grant covers its subtree. A derived share covers the
    // root object alone.
    var derived: t.s.captures.CapturedRef = .{};
    try tree.call(&backend, root, "derive", &.{ .{ .integer = 1 }, .{ .integer = 0 }, .{ .integer = 0 } }, &derived);
    const object_share = try derived.require();
    const whole = try observe(&tree, &backend, arena, root, 2);
    const narrow = try observe(&tree, &backend, arena, object_share, 1);
    const whole_start = try poll(&tree, &backend, arena, whole, null);
    const narrow_start = try poll(&tree, &backend, arena, narrow, null);

    // A grandchild added below the child changes the child, not the root.
    _ = try tree.add(&backend, child, 3);
    const seen = try poll(&tree, &backend, arena, whole, &whole_start.cursor);
    try std.testing.expect(seen.changed and seen.has("subtree") and !seen.has("target"));
    // The object share sees no change, and its cursor stays put.
    const hidden = try poll(&tree, &backend, arena, narrow, &narrow_start.cursor);
    try std.testing.expect(!hidden.changed);
    try std.testing.expectEqualSlices(u8, &narrow_start.cursor, &hidden.cursor);

    // A change to the root itself is a target notice for both.
    _ = try tree.add(&backend, root, 4);
    const direct = try poll(&tree, &backend, arena, whole, &seen.cursor);
    try std.testing.expect(direct.changed and direct.has("target"));
    const narrow_direct = try poll(&tree, &backend, arena, narrow, &hidden.cursor);
    try std.testing.expect(narrow_direct.changed and narrow_direct.has("target") and !narrow_direct.has("subtree"));
}
