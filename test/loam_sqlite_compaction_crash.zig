//! Child process for loam-sqlite-compaction-crash-test. The parent kills it
//! while SQLite's vacuum runs or after it completes, and a fresh process
//! must find every live row, no removed row, and a usable store.
const std = @import("std");
const core = @import("loam_core");
const Sqlite = @import("loam_sqlite").Sqlite;
const file_name = @import("loam_sqlite").file_name;
extern "c" fn pause() c_int;

const id: core.StoreId = @fromBackingInt(91);
const capacity = 64 * 1024 * 1024;
const live_rows = 200;
const churn_rows = 2000;

pub fn main(init: std.process.Init) !void {
    const args = init.minimal.args.vector;
    if (args.len != 3) return error.InvalidArguments;
    const mode = std.mem.span(args[1]);
    const path = std.mem.span(args[2]);
    const creating = std.mem.eql(u8, mode, "create");
    var db = try Sqlite.open(path, .{ .capacity_bytes = capacity, .mode = if (creating) .{ .create = id } else .{ .open = id } });
    defer db.close() catch unreachable;
    if (creating) return fill(&db);
    if (std.mem.startsWith(u8, mode, "verify-")) return verify(&db, std.mem.eql(u8, mode, "verify-new"), init.io, path);
    const before = std.mem.eql(u8, mode, "before");
    if (!before and !std.mem.eql(u8, mode, "after")) return error.InvalidArguments;
    // Before: the parent kills while the vacuum runs. After: once it is done.
    if (before) std.debug.print("READY\n", .{});
    try db.compact();
    if (!before) std.debug.print("READY\n", .{});
    while (true) _ = pause();
}

fn key(buffer: *[16]u8, prefix: []const u8, index: usize) []const u8 {
    return std.fmt.bufPrint(buffer, "{s}/{d:0>5}", .{ prefix, index }) catch unreachable;
}

fn value(buffer: *[1024]u8, index: usize) []const u8 {
    @memset(buffer, @truncate(index));
    return buffer;
}

fn fill(db: *Sqlite) !void {
    var k: [16]u8 = undefined;
    var v: [1024]u8 = undefined;
    var write = try db.beginWrite();
    defer write.abort();
    for (0..live_rows) |i| try write.put(key(&k, "live", i), value(&v, i));
    for (0..churn_rows) |i| for (0..4) |part| try write.put(key(&k, "churn", i * 4 + part), value(&v, i));
    if (try write.commit() != .committed) return error.CommitNotConfirmed;
    var drop = try db.beginWrite();
    defer drop.abort();
    for (0..churn_rows * 4) |i| try drop.remove(key(&k, "churn", i));
    if (try drop.commit() != .committed) return error.CommitNotConfirmed;
}

fn verify(db: *Sqlite, compacted: bool, io: std.Io, path: []const u8) !void {
    var k: [16]u8 = undefined;
    var v: [1024]u8 = undefined;
    {
        var read = try db.beginRead();
        defer read.end();
        for (0..live_rows) |i| {
            const found = (try read.get(key(&k, "live", i))) orelse return error.LiveRowLost;
            if (!std.mem.eql(u8, value(&v, i), found)) return error.LiveRowChanged;
        }
        if (try read.next("churn/", null) != null) return error.RemovedRowReturned;
    }
    const stats = try db.inspect();
    if (compacted) {
        if (stats.free_bytes != 0) return error.CompactionLost;
        var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
        defer dir.close(io);
        const file = try dir.statFile(io, file_name, .{});
        if (file.size >= 2 * 1024 * 1024) return error.FileDidNotShrink;
    }
    // The store takes a write after the interruption.
    var write = try db.beginWrite();
    defer write.abort();
    try write.put("after", "crash");
    if (try write.commit() != .committed) return error.CommitNotConfirmed;
}
