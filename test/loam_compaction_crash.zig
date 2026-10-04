//! Process probe for the public offline replacement phases and real file limits.
const std = @import("std");
const core = @import("loam_core");
const Lmdb = @import("loam_lmdb").Lmdb;
const f = @import("loam/lmdb/compaction_fixture.zig");
extern "c" fn pause() c_int;
extern "c" fn chdir([*:0]const u8) c_int;
extern "c" fn signal(c_int, *const fn (c_int) callconv(.c) void) ?*const fn (c_int) callconv(.c) void;
extern "c" fn setrlimit(c_int, *const extern struct { current: usize, maximum: usize }) c_int;
fn ignore(_: c_int) callconv(.c) void {}

pub fn main(init: std.process.Init) !void {
    const args = init.minimal.args.vector;
    if (args.len != 3) return error.InvalidArguments;
    const mode = std.mem.span(args[1]);
    const path = std.mem.span(args[2]);
    if (std.mem.eql(u8, mode, "compete")) {
        if (Lmdb.open(path, .{ .mode = .{ .open = f.id } })) |opened| {
            var unexpected = opened;
            try unexpected.close();
            return error.DuplicateOwner;
        } else |err| {
            if (err != error.CustodyUnavailable) return err;
        }
        return;
    }
    const creating = std.mem.eql(u8, mode, "create");
    const changed_cwd = std.mem.eql(u8, mode, "changed-cwd");
    var db = try Lmdb.open(if (changed_cwd) "." else path, .{ .mode = if (creating) .{ .create = f.id } else .{ .open = f.id }, .max_readers = 1 });
    defer db.close() catch unreachable;
    if (creating) {
        _ = try f.seed(init.gpa, &db);
        return;
    }
    if (std.mem.eql(u8, mode, "verify")) return f.verify(init.gpa, &db);
    if (changed_cwd and chdir("/") != 0) return error.DirectoryChangeFailed;
    if (changed_cwd) return db.compact();
    var compaction = try db.beginCompaction();
    defer compaction.deinit();
    if (std.mem.eql(u8, mode, "capacity")) {
        // RLIMIT_FSIZE makes the native copy encounter a real storage limit.
        // Set it after opening so source metadata claiming has already finished.
        _ = signal(@intCast(@backingInt(std.posix.SIG.XFSZ)), ignore);
        if (setrlimit(1, &.{ .current = 8192, .maximum = 8192 }) != 0) return error.LimitUnavailable;
        if (compaction.prepare()) |_| return error.ExpectedCapacityRefusal else |err| {
            if (err != error.StorageCapacity) return err;
        }
        return;
    }
    if (std.mem.eql(u8, mode, "before")) return ready();
    try compaction.prepare();
    if (std.mem.eql(u8, mode, "prepared")) return ready();
    try compaction.install();
    if (std.mem.eql(u8, mode, "installed")) return ready();
    try compaction.finish();
    if (std.mem.eql(u8, mode, "synced")) return ready();
    if (!std.mem.eql(u8, mode, "complete")) return error.InvalidArguments;
}

fn ready() noreturn {
    std.debug.print("READY\n", .{});
    while (true) _ = pause();
}
