//! Process-boundary proof: reopen a publication and cyclic actor capabilities,
//! then kill a CapTP-invoked writer before/after LMDB's native commit.
const std = @import("std");
const glowcap = @import("glowcap");
const core = glowcap.loam.core;
const hosting = glowcap.loam.hosting;
const Lmdb = @import("loam_lmdb").Lmdb;
const f = @import("loam/core/fixture.zig");
const actors = @import("loam/hosting/fixture.zig");
const hosts = @import("support/core_host.zig");
const pairs = @import("support/host_pair.zig");
const CapturedRef = @import("support/capture.zig").CapturedRef;
const entropy: hosting.publication.Entropy = @splat(0x29);
extern "c" fn pause() c_int;

pub fn main(init: std.process.Init) !void {
    const args = init.minimal.args.vector;
    if (args.len != 3) return error.InvalidArguments;
    const mode = std.mem.span(args[1]);
    const creating = std.mem.eql(u8, mode, "create");
    var db = try Lmdb.open(std.mem.span(args[2]), .{ .mode = if (creating) .{ .create = f.id } else .{ .open = f.id } });
    defer db.close() catch unreachable;
    var store = try core.Store.init(init.gpa, db.metadata, &actors.schemas, f.limits);
    defer store.deinit() catch unreachable;
    var server = hosts.init(init.gpa, @splat(0x71), actors.driver.Host.Options.withFrameCap(4096));
    defer server.deinit();
    const attachment = try hosting.Attachment.create(init.gpa, &server, &store, &actors.behaviors, .{ .sleep_policy = .every_turn });
    defer attachment.destroy() catch unreachable;
    const publication: core.ObjectId = .{ .store = f.id, .incarnation = 1, .sequence = 3 };
    if (creating) {
        try create(attachment, &db, publication);
        return;
    }
    const lease = try f.load(&store, &db, publication);
    const swiss = try hosting.publication.restore(attachment, lease);
    try store.release(lease);
    store.evict();
    if (store.cache.allocated_bytes != 0) return error.EagerRestore;
    var client = hosts.init(init.gpa, @splat(0x72), actors.driver.Host.Options.withFrameCap(4096));
    defer client.deinit();
    const pair = try pairs.openPair(&client, &server, "127.0.0.1:9714");
    var root: CapturedRef = .{};
    try client.vowOn(try client.fetch(pair.a, swiss.slice()), .{ .ctx = &root, .func = CapturedRef.record });
    try pairs.pumpToQuiescence(&.{pair});
    const target = try root.require();
    const verifying = std.mem.startsWith(u8, mode, "verify-");
    if (!verifying and !std.mem.eql(u8, mode, "before") and !std.mem.eql(u8, mode, "after")) return error.InvalidArguments;
    var answer: actors.Capture = .{};
    try client.vowOn(try client.send(pair.a, target, .{
        .verb = if (verifying) "get" else "add",
        .args = if (verifying) &.{} else &.{.{ .integer = 5 }},
    }), .{ .ctx = &answer, .func = actors.Capture.record });
    try pairs.pumpToQuiescence(&.{pair});
    if (answer.value != null) return error.PrematureReply;
    try drain(attachment, &db, if (verifying) null else mode, &answer);
    try pairs.pumpToQuiescence(&.{pair});
    if (!verifying) return error.MissedKillBoundary;
    const expected: i64 = if (std.mem.eql(u8, mode, "verify-old")) 0 else 5;
    if (answer.value != expected or answer.broken) return error.InvalidRecoveredState;
    // Follow the saved cycle through CapTP. Only the invoked node wakes, and
    // the reverse edge denotes the same actor rather than a reconstructed copy.
    var linked: CapturedRef = .{};
    try client.vowOn(try client.send(pair.a, target, .{ .verb = "edge", .args = &.{} }), .{ .ctx = &linked, .func = CapturedRef.record });
    try pairs.pumpToQuiescence(&.{pair});
    try drain(attachment, &db, null, &answer);
    try pairs.pumpToQuiescence(&.{pair});
    var back: CapturedRef = .{};
    try client.vowOn(try client.send(pair.a, try linked.require(), .{ .verb = "edge", .args = &.{} }), .{ .ctx = &back, .func = CapturedRef.record });
    try pairs.pumpToQuiescence(&.{pair});
    try drain(attachment, &db, null, &answer);
    try pairs.pumpToQuiescence(&.{pair});
    const original = try client.liftCapability(pair.a, target);
    defer client.releaseCapability(original, 1) catch unreachable;
    const returned = try client.liftCapability(pair.a, try back.require());
    defer client.releaseCapability(returned, 1) catch unreachable;
    if (!original.eql(returned)) return error.LostActorIdentity;
    if (attachment.stats.loads != 3 or store.cache.allocated_bytes != 0) return error.InvalidResidency;
}

fn create(attachment: *hosting.Attachment, db: *Lmdb, expected_publication: core.ObjectId) !void {
    const store = attachment.store;
    try store.begin();
    var ids: [2]core.ObjectId = undefined;
    for (&ids) |*id| {
        id.* = try store.allocateId();
        var record = f.record(id.*, &@as([8]u8, @splat(0)));
        record.rooted = true;
        try store.putCopying(record, null);
    }
    try f.commit(store, db);
    var caps: [2]actors.driver.Capability = undefined;
    for (ids, &caps) |id, *cap| {
        const lease = try f.load(store, db, id);
        cap.* = try attachment.restore(lease);
        try store.release(lease);
    }
    defer for (caps) |cap| attachment.host.releaseCapability(cap, 1) catch unreachable;
    try store.begin();
    for (ids, 0..) |id, i| {
        var record = f.record(id, &@as([8]u8, @splat(0)));
        record.rooted = true;
        record.edges = &.{try attachment.capture(caps[1 - i])};
        try store.putCopying(record, 1);
    }
    if (!(try hosting.publication.stage(attachment, entropy, caps[0])).eql(expected_publication)) return error.InvalidBootstrap;
    try f.commit(store, db);
}

fn drain(attachment: *hosting.Attachment, db: *Lmdb, boundary: ?[]const u8, answer: *actors.Capture) !void {
    for (0..64) |_| {
        try attachment.advance();
        while (try attachment.nextWork()) |work| switch (work) {
            .read => |read| try attachment.completeRead(read.ticket, db.read(read)),
            .write => |batch| {
                if (answer.value != null) return error.PrematureReply;
                var pending = try db.beginCommit(batch);
                if (boundary) |mode| {
                    if (std.mem.eql(u8, mode, "after") and pending.finish() != .committed) return error.CommitFailed;
                    std.debug.print("READY\n", .{});
                    while (true) _ = pause();
                }
                try attachment.completeWrite(batch.ticket, pending.finish());
            },
        };
        if (attachment.pending_bytes == 0) return;
    }
    return error.DidNotQuiesce;
}
