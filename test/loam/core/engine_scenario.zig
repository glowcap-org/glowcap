//! One suite proves that a storage engine honors the transaction contract, so a new engine earns its place by passing it.
const std = @import("std");
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

/// What the engine under test offers beyond the contract.
pub const Options = struct {
    /// Bytes of row storage the engine refuses to exceed, or null when its
    /// capacity is not a fixed byte count.
    capacity_bytes: ?usize = null,
};

/// `f` is the fixture module of the calling test root. `engine` is an opened
/// engine that has committed no record yet, and `metadata` is what its open status-allow: pending state or quoted runtime label
/// returned. The close case runs last and leaves the engine for its owner to
/// close once the active transaction ends.
pub fn exercise(comptime f: type, engine: anytype, metadata: f.core.Metadata, options: Options) !void {
    const core = f.core;
    const Engine = @TypeOf(engine.*);
    comptime core.backend.checkEngine(Engine);
    comptime core.backend.checkBackend(Engine);
    try claimsIncarnationOnOpen(f, engine, metadata);
    try @import("names_scenario.zig").exercise(f, engine, try current(f, engine));
    try readsItsOwnWrites(engine);
    try consumesBorrowedInputs(engine);
    try abortLeavesNothing(engine);
    try commitIsFinal(f, engine);
    try finishedTransactionsAreClosed(f, engine);
    try iteratesInKeyOrderWithinPrefix(f, engine);
    try refusesStaleTicket(f, engine);
    try recoversAfterUnknownCommit(f, engine);
    if (options.capacity_bytes) |bytes| try refusesPastCapacity(f, engine, bytes);
    try admitsItsReaderCapacity(engine);
    try closeRefusesWhileBusy(engine);
}

/// Every read the engine says it admits can be open at once, and one more is
/// refused. An engine that admits more than the suite holds is checked up to
/// that many.
fn admitsItsReaderCapacity(engine: anytype) !void {
    var reads: [64]@TypeOf(engine.*).ReadTransaction = undefined;
    const capacity = engine.readerCapacity();
    try std.testing.expect(capacity != 0);
    var open: usize = 0;
    defer for (reads[0..open]) |*read| read.end();
    while (open < @min(capacity, reads.len)) : (open += 1) reads[open] = try engine.beginRead();
    if (open == capacity) try expectError(error.ReaderCapacity, engine.beginRead());
}

fn current(comptime f: type, engine: anytype) !f.core.Metadata {
    const core = f.core;
    var read = try engine.beginRead();
    defer read.end();
    return core.backend.metadata(&read);
}

fn claimsIncarnationOnOpen(comptime f: type, engine: anytype, metadata: f.core.Metadata) !void {
    const stored = try current(f, engine);
    try expectEqual(metadata.store, stored.store);
    try expectEqual(metadata.incarnation, stored.incarnation);
    try std.testing.expect(stored.incarnation != 0);
}

fn readsItsOwnWrites(engine: anytype) !void {
    var write = try engine.beginWrite();
    defer write.abort();
    try write.put("r2", "two");
    try write.put("r1", "one");
    try write.put("r3", "three");
    try expectEqualStrings("one", (try write.get("r1")).?);
    try write.remove("r2");
    try std.testing.expect((try write.get("r2")) == null);
    const first = (try write.next("r", null)).?;
    try expectEqualStrings("r1", first.key);
    const second = (try write.next("r", first.key)).?;
    try expectEqualStrings("r3", second.key);
    try std.testing.expect((try write.next("r", second.key)) == null);
}

/// Inputs may borrow the preceding operation's result. The next operation
/// must consume them before releasing their owner, including on overwrite.
fn consumesBorrowedInputs(engine: anytype) !void {
    var write = try engine.beginWrite();
    defer write.abort();
    const large: [8192]u8 = @splat('B');
    for ([_][]const u8{ "", "abcdefghijklmnop", &large }) |payload| {
        try write.put("borrow-source", payload);
        try write.put("borrow-copy", (try write.get("borrow-source")).?);
        try expectEqualStrings(payload, (try write.get("borrow-copy")).?);
        try write.put("borrow-source", (try write.get("borrow-source")).?);
        try expectEqualStrings(payload, (try write.get("borrow-source")).?);
    }
    try write.put("prefix", "prefix");
    const borrowed = (try write.next("prefix", null)).?;
    const row = (try write.next(borrowed.value, null)).?;
    try expectEqualStrings("prefix", row.key);
    try expectEqualStrings("prefix", row.value);
    try write.put(row.key, row.value);
    try expectEqualStrings("prefix", (try write.get("prefix")).?);
    try write.put((try write.get("prefix")).?, "changed");
    try expectEqualStrings("changed", (try write.get("prefix")).?);
    try write.remove((try write.next("prefix", null)).?.key);
    try std.testing.expect((try write.get("prefix")) == null);
}

fn abortLeavesNothing(engine: anytype) !void {
    var write = try engine.beginWrite();
    defer write.abort();
    try write.put("a1", "gone");
    write.abort();
    write.abort();
    try expectError(error.Closed, write.commit());
    var read = try engine.beginRead();
    defer read.end();
    try std.testing.expect((try read.get("a1")) == null);
}

fn commitIsFinal(comptime f: type, engine: anytype) !void {
    const core = f.core;
    var write = try engine.beginWrite();
    defer write.abort();
    try write.put("c1", "kept");
    try expectEqual(core.backend.Commit.committed, try write.commit());
    try expectEqual(core.backend.Commit.committed, try write.commit());
    write.abort();
    var read = try engine.beginRead();
    defer read.end();
    try expectEqualStrings("kept", (try read.get("c1")).?);
}

fn finishedTransactionsAreClosed(comptime f: type, engine: anytype) !void {
    const core = f.core;
    var committed = try engine.beginWrite();
    defer committed.abort();
    try committed.put("f1", "one");
    try expectEqual(core.backend.Commit.committed, try committed.commit());
    var aborted = try engine.beginWrite();
    defer aborted.abort();
    aborted.abort();
    inline for (.{ &committed, &aborted }) |write| {
        try expectError(error.Closed, write.get("f1"));
        try expectError(error.Closed, write.next("f", null));
        try expectError(error.Closed, write.put("f2", "two"));
        try expectError(error.Closed, write.remove("f1"));
    }
    try expectError(error.Closed, aborted.commit());
    try expectEqual(core.backend.Commit.committed, try committed.commit());
}

fn iteratesInKeyOrderWithinPrefix(comptime f: type, engine: anytype) !void {
    const core = f.core;
    var write = try engine.beginWrite();
    defer write.abort();
    try write.put("l\x00", "outside");
    try write.put("k\x03", "three");
    try write.put("k\x01", "one");
    try write.put("k\x02", "two");
    try expectEqual(core.backend.Commit.committed, try write.commit());
    {
        var read = try engine.beginRead();
        defer read.end();
        try checkPrefixRows(f, &read);
    }
    var writer = try engine.beginWrite();
    defer writer.abort();
    try checkPrefixRows(f, &writer);
}

fn checkPrefixRows(comptime f: type, txn: anytype) !void {
    var after: ?[]const u8 = null;
    for ([_][]const u8{ "k\x01", "k\x02", "k\x03" }) |key| {
        const row = (try txn.next("k", after)).?;
        try expectEqualStrings(key, row.key);
        after = row.key;
    }
    try std.testing.expect((try txn.next("k", after)) == null);
    try expectEqualStrings("k\x03", (try txn.next("k", "k\x02")).?.key);
    // The floor need not be inside the prefix. Both bounds still apply.
    for ([_][]const u8{ "a", "", "k" }) |floor| {
        try expectEqualStrings("k\x01", (try txn.next("k", floor)).?.key);
    }
    try std.testing.expect((try txn.next("k", "l")) == null);
    const first_key = (try txn.next("", null)).?.key;
    var saved: [f.core.max_key_bytes]u8 = undefined;
    @memcpy(saved[0..first_key.len], first_key);
    const first_length = first_key.len;
    try expectEqualStrings(saved[0..first_length], (try txn.next("", "")).?.key);
}

fn refusesStaleTicket(comptime f: type, engine: anytype) !void {
    const core = f.core;
    const meta = try current(f, engine);
    var store = try core.Store.init(std.testing.allocator, meta, &f.schemas, f.limits);
    // best-effort: a failed case leaves the store busy, and the assertion is the report.
    defer store.deinit() catch {};
    try store.begin();
    const object = try store.allocateId();
    try store.abort();
    var buffer: [64]u8 = undefined;
    var request: core.Read = .{
        .ticket = .{ .store = meta.store, .incarnation = meta.incarnation, .sequence = 1, .revision = meta.revision + 1 },
        .id = object,
        .buffer = &buffer,
    };
    switch (core.backend.read(engine, request)) {
        .failed => |err| try expectEqual(error.StaleCompletion, err),
        else => return error.TestExpectedStale,
    }
    request.ticket.revision = meta.revision;
    try expectEqual(.missing, std.meta.activeTag(core.backend.read(engine, request)));
}

fn recoversAfterUnknownCommit(comptime f: type, engine: anytype) !void {
    const core = f.core;
    const meta = try current(f, engine);
    var store = try core.Store.init(std.testing.allocator, meta, &f.schemas, f.limits);
    // best-effort: a failed case leaves the store busy, and the assertion is the report.
    defer store.deinit() catch {};
    try store.begin();
    try store.putCopying(f.record(try store.allocateId(), "one"), null);
    var ticket = try store.prepare();
    var write = try engine.beginWrite();
    defer write.abort();
    _ = try (try store.beginWrite(ticket)).apply(&write);
    try expectEqual(core.backend.Commit.committed, try write.commit());
    try store.completeWrite(ticket, .unknown);
    try store.resolve(ticket, try core.backend.recover(engine, try store.recoveryBatch()));
    try expectEqual(meta.objects + 1, store.metadata.objects);

    try store.begin();
    try store.putCopying(f.record(try store.allocateId(), "two"), null);
    ticket = try store.prepare();
    var abandoned = try engine.beginWrite();
    defer abandoned.abort();
    _ = try (try store.beginWrite(ticket)).apply(&abandoned);
    abandoned.abort();
    try store.completeWrite(ticket, .unknown);
    try store.resolve(ticket, try core.backend.recover(engine, try store.recoveryBatch()));
    try expectEqual(meta.objects + 1, store.metadata.objects);
}

fn refusesPastCapacity(comptime f: type, engine: anytype, capacity_bytes: usize) !void {
    const core = f.core;
    const before = try current(f, engine);
    const big = try std.testing.allocator.alloc(u8, capacity_bytes + 4096);
    defer std.testing.allocator.free(big);
    @memset(big, 0x5a);
    var write = try engine.beginWrite();
    defer write.abort();
    // An engine refuses the row as soon as it knows it cannot fit, at the
    // put or at the commit. Either refusal ends the transaction.
    if (write.put("z1", big)) |_| {
        try expectError(error.StorageCapacity, write.commit());
    } else |err| {
        try expectEqual(error.StorageCapacity, err);
    }
    try expectError(error.Closed, write.commit());
    var read = try engine.beginRead();
    defer read.end();
    try std.testing.expect((try read.get("z1")) == null);
    try std.testing.expectEqualDeep(before, try core.backend.metadata(&read));
}

fn closeRefusesWhileBusy(engine: anytype) !void {
    var write = try engine.beginWrite();
    defer write.abort();
    try expectError(error.Busy, engine.close());
    try expectError(error.Closed, engine.beginRead());
    try expectError(error.Closed, engine.beginWrite());
}
