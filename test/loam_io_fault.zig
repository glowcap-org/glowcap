//! The storage failure probe behind loam-io-fault-test, built once per disk
//! engine. It writes two records that point at each other through the real
//! Store, fails one write or sync, and exits without cleanup. A fresh process
//! then checks the whole graph. The read modes load that graph while a read
//! fails or the data file is cut short under the open engine. Each must return
//! the exact graph or an error, and the process must survive, even when the
//! file is cut after a value was returned.
const std = @import("std");
// Let a SIGBUS reach the runner as itself. Zig's debug handler would print a
// stack trace and turn it into SIGABRT.
pub const std_options: std.Options = .{ .enable_segfault_handler = false };
comptime {
    if (@import("builtin").os.tag != .linux) @compileError("loam-io-fault-test requires Linux");
}
const core = @import("loam_core");
const fixture = @import("engine_fixture");
const f = @import("loam/core/fixture.zig");
extern "c" fn loam_fault_arm(kind: c_int, target: c_uint, action: c_int, code: c_int) void;
extern "c" fn loam_fault_stop() void;
extern "c" fn loam_fault_writes() c_uint;
extern "c" fn loam_fault_syncs() c_uint;
extern "c" fn loam_fault_reads() c_uint;
extern "c" fn truncate(path: [*:0]const u8, length: c_long) c_int;
extern "c" fn loam_fault_fired() c_int;
const schemas = [_]core.Schema{.{ .id = 7, .version = 1, .max_payload = 8192, .max_edges = 8 }};
const limits: core.Store.Limits = .{ .records = .{ .max_record_bytes = 16384, .max_edges = 8 }, .cache_slots = 2, .max_leases = 2, .resident_bytes = 32768, .max_changes = 8, .staging_bytes = 65536 };
const old: [8192]u8 = @splat('A');
const new: [8192]u8 = @splat('B');

const Mode = enum { create, run, verify, read, shrink, borrow };

pub fn main(init: std.process.Init) !void {
    const args = init.minimal.args.vector;
    if (args.len < 3) return error.InvalidArguments;
    const mode = std.meta.stringToEnum(Mode, std.mem.span(args[1])) orelse return error.InvalidArguments;
    if (args.len != @as(usize, switch (mode) {
        .create => 3,
        .verify, .shrink, .borrow => 4,
        .read => 6,
        .run => 7,
    })) return error.InvalidArguments;
    const create = mode == .create;
    const verify = mode == .verify;
    const directory = std.mem.span(args[2]);
    var db = try fixture.open(directory, if (create) .create else .open, f.id);
    defer db.close() catch unreachable;
    var store = try core.Store.init(init.gpa, db.metadata, &schemas, limits);
    defer store.deinit() catch unreachable;
    const a: core.ObjectId = .{ .store = f.id, .incarnation = 1, .sequence = 1 };
    const b: core.ObjectId = .{ .store = f.id, .incarnation = 1, .sequence = 2 };
    if (verify) return verifyGraph(&store, &db, a, b, std.mem.span(args[3]));
    if (mode == .borrow) {
        var txn = try db.beginRead();
        defer txn.end();
        const bytes = (try txn.get(&a.key())) orelse return error.MissingRecord;
        var expected: [16384]u8 = undefined;
        if (bytes.len > expected.len) return error.RecordTooLarge;
        @memcpy(expected[0..bytes.len], bytes);
        try shrinkData(directory, try std.fmt.parseInt(c_long, std.mem.span(args[3]), 10));
        if (!std.mem.eql(u8, expected[0..bytes.len], bytes)) return error.WrongData;
        std.debug.print("intact 0 0\n", .{});
        return;
    }
    if (mode == .read or mode == .shrink) {
        if (mode == .read) {
            const target = try std.fmt.parseInt(c_uint, std.mem.span(args[3]), 10);
            const action = try std.fmt.parseInt(c_int, std.mem.span(args[4]), 10);
            const code = try std.fmt.parseInt(c_int, std.mem.span(args[5]), 10);
            if (action < 0 or action > 5 or code < 0) return error.InvalidArguments;
            loam_fault_arm(3, target, action, code);
        } else try shrinkData(directory, try std.fmt.parseInt(c_long, std.mem.span(args[3]), 10));
        const outcome = try readGraph(&store, &db, a, b);
        loam_fault_stop();
        std.debug.print("{s} {d} {d}\n", .{ @tagName(outcome), loam_fault_reads(), loam_fault_fired() });
        std.process.exit(0);
    }
    try store.begin();
    if (create) {
        if (!(try store.allocateId()).eql(a) or !(try store.allocateId()).eql(b)) return error.InvalidIdentity;
    }
    var first = f.record(a, if (create) &old else &new);
    first.rooted = true;
    first.edges = &.{.{ .target = b }};
    try store.putCopying(first, if (create) null else 1);
    var second = f.record(b, if (create) &old else &new);
    second.edges = &.{.{ .target = a }};
    try store.putCopying(second, if (create) null else 1);
    if (create) return f.commit(&store, &db);
    const ticket = try store.prepare();
    const batch = try store.beginWrite(ticket);
    const kind = try std.fmt.parseInt(c_int, std.mem.span(args[3]), 10);
    const target = try std.fmt.parseInt(c_uint, std.mem.span(args[4]), 10);
    const action = try std.fmt.parseInt(c_int, std.mem.span(args[5]), 10);
    const code = try std.fmt.parseInt(c_int, std.mem.span(args[6]), 10);
    if (kind < 0 or kind > 2 or action < 0 or action > 5 or code < 0) return error.InvalidArguments;
    loam_fault_arm(kind, target, action, code);
    const outcome = db.commit(batch);
    loam_fault_stop();
    if (outcome == .unknown) try requireFenced(&db);
    std.debug.print("{s} {d} {d} {d}\n", .{ @tagName(outcome), loam_fault_writes(), loam_fault_syncs(), loam_fault_fired() });
    // No Store completion, SQLite checkpoint, or LMDB close may rescue the
    // state. The supervisor opens it in another process after this exit.
    std.process.exit(0);
}

/// Cuts the open engine's data file to `length` bytes.
fn shrinkData(directory: []const u8, length: c_long) !void {
    var buffer: [std.fs.max_path_bytes:0]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&buffer, "{s}/{s}", .{ directory, fixture.data_file }, 0);
    if (truncate(path, length) != 0) return error.TruncateFailed;
}

/// Loads the created graph cold. A refusal is an acceptable outcome. Bytes
/// that differ from what was committed are not.
fn readGraph(store: *core.Store, db: *fixture.Engine, a: core.ObjectId, b: core.ObjectId) !enum { intact, refused } {
    for ([_]core.ObjectId{ a, b }) |id| {
        const lease = f.load(store, db, id) catch return .refused;
        const view = try store.view(lease);
        if (!std.mem.eql(u8, &old, view.payload) or view.edge_count != 1) return error.WrongData;
        var edges = view.edges();
        if (!edges.next().?.target.eql(if (id.eql(a)) b else a)) return error.WrongData;
    }
    return .intact;
}

fn requireFenced(db: *fixture.Engine) !void {
    if (db.beginRead()) |value| {
        var read = value;
        read.end();
        return error.UncertainReadAdmitted;
    } else |err| if (err != error.Closed and err != error.ReopenRequired) return err;
    if (db.beginWrite()) |value| {
        var write = value;
        write.abort();
        return error.UncertainWriteAdmitted;
    } else |err| if (err != error.Closed and err != error.ReopenRequired) return err;
}

fn verifyGraph(store: *core.Store, db: *fixture.Engine, a: core.ObjectId, b: core.ObjectId, outcome: []const u8) !void {
    const revision = store.metadata.revision;
    if (revision != 1 and revision != 2) return error.InvalidRevision;
    if (std.mem.eql(u8, outcome, "committed")) {
        if (revision != 2) return error.LostAcknowledgedCommit;
    } else if (std.mem.eql(u8, outcome, "unchanged")) {
        if (revision != 1) return error.FalseRefusal;
    } else if (!std.mem.eql(u8, outcome, "unknown")) return error.InvalidArguments;
    const expected = if (revision == 1) &old else &new;
    for ([_]core.ObjectId{ a, b }) |id| {
        const lease = try f.load(store, db, id);
        defer store.release(lease) catch unreachable;
        const view = try store.view(lease);
        if (!std.mem.eql(u8, expected, view.payload) or view.edge_count != 1) return error.PartialGraph;
        var edges = view.edges();
        if (!edges.next().?.target.eql(if (id.eql(a)) b else a)) return error.InvalidEdge;
    }
    if (store.metadata.objects != 2 or store.metadata.roots != 1) return error.InvalidTotals;
}
