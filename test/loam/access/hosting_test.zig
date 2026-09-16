//! Managed use and lifecycle edits share the ordinary Host transaction owner.
const std = @import("std");
const h = @import("hosting_fixture.zig");
const a = h.a;

const TransientActor = struct {
    pub fn handle(_: *TransientActor, _: *h.actors.Turn, _: h.actors.Message) !h.f.glowcap.ocapn.model.Argument {
        return .{ .void = {} };
    }
};

test "loam managed hosting separates use and control and gates content on confirmed commit" {
    var backend = try h.loam.Volatile.init(a, h.f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var store = try h.loam.core.Store.init(a, try backend.open(), &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    const data = try h.seed(&store, &backend);
    var host: h.Hosted = undefined;
    try host.init(&store, &backend, data);
    defer host.deinit();
    // Even a resident managed endpoint must take the durable admission path.
    try std.testing.expectError(error.DurableTurnRequired, host.host.vat.near(host.host.localActorFor(host.use).?, .{ .verb = "get", .args = &.{} }));
    try std.testing.expectEqual(@as(usize, 0), host.caps.operations);
    store.evict();
    var add: h.Answer = .{};
    try host.send(host.use, "add", &.{.{ .integer = 7 }}, &add);
    const batch = try host.untilWrite(&backend);
    try std.testing.expect(add.number == null);
    const portrait = host.attached.operations[0].lease;
    try host.attached.completeWrite(batch.ticket, backend.commit(batch));
    store.evict();
    if (portrait) |lease| _ = try h.loam.access.records.EndpointRecord.decode(try store.view(lease));
    try host.drain(&backend);
    try std.testing.expect(portrait != null);
    try std.testing.expectEqual(@as(?i64, 7), add.number);
    for ([_]struct { ref: h.driver.Capability, verb: []const u8 }{ .{ .ref = host.use, .verb = "pause" }, .{ .ref = host.control, .verb = "get" } }) |wrong| {
        var answer: h.Answer = .{};
        try host.send(wrong.ref, wrong.verb, &.{}, &answer);
        try host.drain(&backend);
        try std.testing.expect(answer.broken);
    }
    var paused: h.Answer = .{};
    try host.send(host.control, "pause", &.{}, &paused);
    try host.drain(&backend);
    try std.testing.expectEqual(@as(?bool, true), paused.changed);
    const revision = store.metadata.revision;
    var noop: h.Answer = .{};
    try host.send(host.control, "pause", &.{}, &noop);
    try host.drain(&backend);
    try std.testing.expectEqual(@as(?bool, false), noop.changed);
    try std.testing.expectEqual(revision, store.metadata.revision);
    var denied: h.Answer = .{};
    try host.send(host.use, "add", &.{.{ .integer = 10 }}, &denied);
    try host.drain(&backend);
    try std.testing.expect(denied.broken);
    var resumed: h.Answer = .{};
    try host.send(host.control, "resume", &.{}, &resumed);
    try host.drain(&backend);
    var failed: h.Answer = .{};
    try host.send(host.use, "fail", &.{.{ .integer = 99 }}, &failed);
    try host.drain(&backend);
    try std.testing.expect(failed.broken);
    var get: h.Answer = .{};
    try host.send(host.use, "get", &.{}, &get);
    try host.drain(&backend);
    try std.testing.expectEqual(@as(?i64, 7), get.number);
    try std.testing.expectEqual(@as(usize, 0), host.caps.operations);
    try std.testing.expectEqual(@as(usize, 0), host.caps.references);
    store.evict();
    try std.testing.expectEqual(@as(usize, 0), store.cache.allocated_bytes);
}

test "loam managed hosting admitted use waits for the control commit" {
    var backend = try h.loam.Volatile.init(a, h.f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var store = try h.loam.core.Store.init(a, try backend.open(), &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    const data = try h.seed(&store, &backend);
    var host: h.Hosted = undefined;
    try host.init(&store, &backend, data);
    defer host.deinit();
    var revoke: h.Answer = .{};
    try host.send(host.control, "revoke", &.{}, &revoke);
    _ = try host.host.vat.driveIngressBudgeted(.local, 64);
    // Prepare control first, keeping its ready invocation queued.
    for (0..128) |_| {
        try host.attached.advance();
        _ = try host.reads(&backend);
        if (host.attached.operations[0].phase == .scheduled) break;
    }
    var use: h.Answer = .{};
    try host.send(host.use, "add", &.{.{ .integer = 1 }}, &use);
    // Admit the use while the control is held in its write phase.
    const batch = try host.untilWrite(&backend);
    try std.testing.expect(revoke.changed == null);
    try host.attached.completeWrite(batch.ticket, backend.commit(batch));
    try host.drain(&backend);
    try std.testing.expectEqual(@as(?bool, true), revoke.changed);
    try std.testing.expect(use.broken);
    const lease = try h.c.load(&store, &backend, data.content);
    defer store.release(lease) catch unreachable;
    try std.testing.expectEqual(@as(i64, 0), std.mem.readInt(i64, (try store.currentView(lease)).payload[0..8], .little));
}

test "loam managed hosting restarts queued and cold authority snapshots without leaking reads" {
    for ([_]bool{ false, true }) |cold| {
        var backend = try h.loam.Volatile.init(a, h.f.store_id, 16 * 1024 * 1024);
        defer backend.deinit();
        var store = try h.loam.core.Store.init(a, try backend.open(), &h.schemas, h.limits);
        defer store.deinit() catch unreachable;
        const data = try h.seed(&store, &backend);
        var host: h.Hosted = undefined;
        try host.init(&store, &backend, data);
        defer host.deinit();
        store.evict();
        var use: h.Answer = .{};
        try host.send(host.use, "add", &.{.{ .integer = 1 }}, &use);
        _ = try host.host.vat.driveIngressBudgeted(.local, 64);
        var held: ?h.loam.core.Read = null;
        for (0..128) |_| {
            try host.attached.advance();
            if (host.attached.operations[0].phase == .scheduled) break;
            const work = (try host.attached.nextWork()) orelse return error.NoProgress;
            try std.testing.expect(work == .read);
            if (cold and host.attached.operations[0].pending_read) {
                held = work.read;
                break;
            }
            try host.attached.completeRead(work.read.ticket, backend.read(work.read));
        }
        if (cold) try std.testing.expect(held != null) else try std.testing.expect(host.attached.operations[0].phase == .scheduled);
        const read_result = if (held) |read| backend.read(read) else null;
        // Inject a concurrent durable actor's committed grant edit at this exact
        // boundary, without consuming the queued managed invocation.
        _ = try h.f.change(&store, &backend, data.owner, .{ .revoke = data.grant });
        if (held) |read| {
            try std.testing.expectError(error.Busy, host.attached.destroy());
            try host.attached.completeRead(read.ticket, read_result.?);
        }
        try host.drain(&backend);
        try std.testing.expect(use.broken);
        try std.testing.expectEqual(@as(usize, 0), host.caps.operations);
        try std.testing.expectEqual(@as(u64, 0), host.attached.stats.invocations);
        store.evict();
        try std.testing.expectEqual(@as(usize, 0), store.cache.allocated_bytes);
    }
}

test "loam managed hosting retires failed reads and partial operation allocations" {
    var backend = try h.loam.Volatile.init(a, h.f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var store = try h.loam.core.Store.init(a, try backend.open(), &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    const data = try h.seed(&store, &backend);
    var host: h.Hosted = undefined;
    try host.init(&store, &backend, data);
    defer host.deinit();
    var complete = false;
    for (0..32) |fail_index| {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = fail_index });
        host.caps.allocator = failing.allocator();
        defer host.caps.allocator = a;
        var answer: h.Answer = .{};
        try host.send(host.control, "pause", &.{}, &answer);
        try host.drain(&backend);
        try std.testing.expectEqual(@as(usize, 0), host.caps.references);
        try std.testing.expectEqual(@as(usize, 0), host.caps.operations);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        if (!failing.has_induced_failure) {
            try std.testing.expectEqual(@as(?bool, true), answer.changed);
            complete = true;
            break;
        }
        try std.testing.expect(answer.broken);
    }
    try std.testing.expect(complete);
    store.evict();
    var failed: h.Answer = .{};
    try host.send(host.use, "get", &.{}, &failed);
    _ = try host.host.vat.driveIngressBudgeted(.local, 64);
    for (0..64) |_| {
        try host.attached.advance();
        const work = (try host.attached.nextWork()).?;
        const read = work.read;
        if (host.attached.operations[0].pending_read) {
            try std.testing.expectError(error.InjectedReadFailure, host.attached.completeRead(read.ticket, .{ .failed = error.InjectedReadFailure }));
            break;
        }
        try host.attached.completeRead(read.ticket, backend.read(read));
    }
    try host.drain(&backend);
    try std.testing.expect(failed.broken);
    try std.testing.expectEqual(@as(usize, 0), host.caps.operations);
    store.evict();
    try std.testing.expectEqual(@as(usize, 0), store.cache.allocated_bytes);
}

fn readOnly(_: std.mem.Allocator, verb: []const u8, args: []const h.driver.Value) !h.c.core.Control.Edit {
    if (!std.mem.eql(u8, verb, "permissions") or args.len != 3 or args[0] != .integer or args[1] != .integer or args[2] != .integer) return error.InvalidArguments;
    const resource: h.c.core.ResourceId = .{ .owner = @fromBackingInt(81), .slot = std.math.cast(u32, args[0].integer) orelse return error.InvalidArguments, .generation = std.math.cast(u64, args[1].integer) orelse return error.InvalidArguments };
    const permissions: []const h.c.core.Policy.Key = if (args[2].integer == 0) &.{h.f.vocabulary.read} else &.{ h.f.vocabulary.read, h.f.vocabulary.post };
    return .{ .set_policy = try h.f.vocabulary.terms(.{ .object = resource }, permissions, null) };
}

test "loam managed hosting applies editable policy and keeps its endpoint binding" {
    var backend = try h.loam.Volatile.init(a, h.f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var store = try h.loam.core.Store.init(a, try backend.open(), &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    const data = try h.seed(&store, &backend);
    var host: h.Hosted = undefined;
    try host.init(&store, &backend, data);
    defer host.deinit();
    host.service.decode_control = readOnly;
    for ([_]i64{ 0, 1 }) |permissions| {
        var edit: h.Answer = .{};
        try host.send(host.control, "permissions", &.{ .{ .integer = data.resource.slot }, .{ .integer = @intCast(data.resource.generation) }, .{ .integer = permissions } }, &edit);
        try host.drain(&backend);
        try std.testing.expectEqual(@as(?bool, true), edit.changed);
        var add: h.Answer = .{};
        try host.send(host.use, "add", &.{.{ .integer = 2 }}, &add);
        try host.drain(&backend);
        try std.testing.expectEqual(permissions == 0, add.broken);
        var get: h.Answer = .{};
        try host.send(host.use, "get", &.{}, &get);
        try host.drain(&backend);
        try std.testing.expectEqual(@as(?i64, if (permissions == 0) 0 else 2), get.number);
    }
}

test "loam managed hosting refuses undeclared reply capabilities and weak disclosure" {
    try std.testing.expect(@typeInfo(h.access.ContentCall) == .@"opaque");
    var backend = try h.loam.Volatile.init(a, h.f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var store = try h.loam.core.Store.init(a, try backend.open(), &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    const data = try h.seed(&store, &backend);
    var host: h.Hosted = undefined;
    try host.init(&store, &backend, data);
    defer host.deinit();
    // An attachment-local capability the method never declared must not cross
    // the reply, even though it names a live endpoint this attachment owns.
    h.smuggle = host.use;
    defer h.smuggle = null;
    for ([_][]const u8{ "smuggle", "smuggle-list", "smuggle-set", "smuggle-tagged", "smuggle-struct" }) |verb| {
        var smuggled: h.Answer = .{};
        try host.send(host.use, verb, &.{}, &smuggled);
        try host.drain(&backend);
        try std.testing.expect(smuggled.broken);
        try std.testing.expectEqualStrings("UndeclaredDisclosure", smuggled.reason());
    }
    // A declared disclosure reaches the settlement machinery; only the
    // local-only resolver rule refuses an owning capability reply here.
    var shared: h.Answer = .{};
    try host.send(host.use, "share", &.{}, &shared);
    try host.drain(&backend);
    try std.testing.expect(shared.broken);
    try std.testing.expectEqualStrings("OwningReplyRequired", shared.reason());
    for ([_][]const u8{ "share-list", "share-set", "share-tagged", "share-struct", "share-dependent", "share-dependent-list", "share-dependent-set", "share-dependent-tagged", "share-dependent-struct" }) |verb| {
        var nested: h.Answer = .{};
        try host.send(host.use, verb, &.{}, &nested);
        try host.drain(&backend);
        try std.testing.expect(nested.broken);
        try std.testing.expectEqualStrings("OwningReplyRequired", nested.reason());
        _ = try host.host.vat.near(host.attached.runner, .{ .verb = "barrier", .args = &.{} });
        try std.testing.expectEqual(@as(usize, 0), host.attached.dependent_facets);
    }
    // Weak edges retain nothing and unknown fields do not exist.
    var weak: h.Answer = .{};
    try host.send(host.use, "share-weak", &.{}, &weak);
    try host.drain(&backend);
    try std.testing.expect(weak.broken);
    try std.testing.expectEqualStrings("NotDurable", weak.reason());
    var missing: h.Answer = .{};
    try host.send(host.use, "share-none", &.{}, &missing);
    try host.drain(&backend);
    try std.testing.expect(missing.broken);
    try std.testing.expectEqualStrings("NoSuchEdge", missing.reason());
    try std.testing.expectEqual(@as(usize, 0), host.caps.operations);
    store.evict();
    try std.testing.expectEqual(@as(usize, 0), store.cache.allocated_bytes);
}

test "loam managed hosting replaces and removes strong reference fields transactionally" {
    var backend = try h.loam.Volatile.init(a, h.f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var store = try h.loam.core.Store.init(a, try backend.open(), &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    const data = try h.seed(&store, &backend);
    var host: h.Hosted = undefined;
    try host.init(&store, &backend, data);
    defer host.deinit();
    h.replacement = host.use;
    defer h.replacement = null;

    var replaced: h.Answer = .{};
    try host.send(host.use, "replace-reference", &.{}, &replaced);
    const replacement_batch = try host.untilWrite(&backend);
    try std.testing.expect(replaced.changed == null);
    try host.attached.completeWrite(replacement_batch.ticket, backend.commit(replacement_batch));
    try host.drain(&backend);
    try std.testing.expectEqual(@as(?bool, true), replaced.changed);
    var lease = try h.c.load(&store, &backend, data.content);
    var view = try store.currentView(lease);
    var edges = view.edges();
    try std.testing.expect((edges.next().?).target.eql(data.use));
    const weak = edges.next().?;
    try std.testing.expect(weak.target.eql(data.control));
    try std.testing.expect(weak.strength == .weak);
    try std.testing.expect(edges.next() == null);
    try store.release(lease);

    // A refused write installs neither the removal nor its shifted edge order.
    var aborted: h.Answer = .{};
    try host.send(host.use, "remove-reference", &.{}, &aborted);
    const aborted_batch = try host.untilWrite(&backend);
    try host.attached.completeWrite(aborted_batch.ticket, .{ .unchanged = error.InjectedWriteFailure });
    try host.drain(&backend);
    try std.testing.expect(aborted.broken);
    lease = try h.c.load(&store, &backend, data.content);
    view = try store.currentView(lease);
    edges = view.edges();
    try std.testing.expect((edges.next().?).target.eql(data.use));
    try std.testing.expect(edges.next().?.strength == .weak);
    try store.release(lease);

    // Weak retention metadata is not a declared saved authority field.
    for ([_][]const u8{ "replace-reference-weak", "remove-reference-weak" }) |verb| {
        var refused: h.Answer = .{};
        try host.send(host.use, verb, &.{}, &refused);
        try host.drain(&backend);
        try std.testing.expect(refused.broken);
        try std.testing.expectEqualStrings("NotDurable", refused.reason());
    }
    const transient_actor = try host.host.vat.spawn(TransientActor, .{});
    const transient_ref = try host.host.liftLocalActor(transient_actor);
    h.replacement = transient_ref;
    var foreign: h.Answer = .{};
    try host.send(host.use, "replace-reference", &.{}, &foreign);
    try host.drain(&backend);
    try std.testing.expect(foreign.broken);
    try std.testing.expectEqualStrings("NotDurable", foreign.reason());
    try host.host.releaseCapability(transient_ref, 1);
    h.replacement = host.use;

    var removed: h.Answer = .{};
    try host.send(host.use, "remove-reference", &.{}, &removed);
    try host.drain(&backend);
    try std.testing.expectEqual(@as(?bool, true), removed.changed);
    lease = try h.c.load(&store, &backend, data.content);
    defer store.release(lease) catch unreachable;
    view = try store.currentView(lease);
    try std.testing.expectEqual(@as(usize, 1), view.edge_count);
    edges = view.edges();
    const remaining = edges.next().?;
    try std.testing.expect(remaining.target.eql(data.control));
    try std.testing.expect(remaining.strength == .weak);
}

test "loam managed hosting retries harmless commits with bounded preparation memory" {
    var backend = try h.loam.Volatile.init(a, h.f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var store = try h.loam.core.Store.init(a, try backend.open(), &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    const data = try h.seed(&store, &backend);
    var host: h.Hosted = undefined;
    try host.init(&store, &backend, data);
    defer host.deinit();
    var answer: h.Answer = .{};
    try host.send(host.use, "get", &.{}, &answer);
    _ = try host.host.vat.driveIngressBudgeted(.local, 64);
    var prepared_bytes: ?usize = null;
    for (0..8) |_| {
        for (0..128) |_| {
            try host.attached.advance();
            _ = try host.reads(&backend);
            if (host.attached.operations[0].phase == .scheduled) break;
        }
        const op = &host.attached.operations[0];
        try std.testing.expect(op.phase == .scheduled);
        if (prepared_bytes) |bytes| try std.testing.expectEqual(bytes, op.fixed.end_index) else prepared_bytes = op.fixed.end_index;
        // A different actor's unrelated content commit must cause a transparent
        // retry, rather than failing an otherwise still-authorized use call.
        try store.begin();
        const unrelated = try store.allocateId();
        try store.putCopying(.{ .id = unrelated, .revision = 0, .schema = 7, .payload = "unrelated" }, null);
        try h.f.commit(&store, &backend);
        _ = try host.host.vat.driveIngressBudgeted(.local, 64);
        try std.testing.expect(answer.number == null and !answer.broken);
        try std.testing.expectEqual(@as(usize, 0), host.caps.operations);
    }
    try host.drain(&backend);
    try std.testing.expectEqual(@as(?i64, 0), answer.number);
    try std.testing.expectEqual(@as(u64, 1), host.attached.stats.invocations);
}
