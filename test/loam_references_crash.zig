//! SIGKILL around a checked foreign field and payload's ordinary transaction.
//! Fresh processes reopen both vats. No live session or export position persists.
const std = @import("std");
const f = @import("loam/access/reference_fixture.zig");
const h = f.h;
const sharing = @import("loam/access/sharing_fixture.zig");
const Lmdb = @import("loam_lmdb").Lmdb;
const core = h.loam.core;
const manifest_schema: core.Schema = .{ .id = 0x52454650524f4245, .version = 1, .max_payload = 16, .max_edges = 2, .name_offset = 0 };
const schemas = f.schemas ++ [_]core.Schema{manifest_schema};
const Role = enum { original, use, control };
const Boundary = enum { before, after, installed };
extern "c" fn pause() c_int;

fn stop() noreturn {
    std.debug.print("READY\n", .{});
    while (true) _ = pause();
}

const Manifest = struct { use: core.ObjectId, control: core.ObjectId };
fn stageManifest(store: *core.Store, db: *Lmdb, data: h.Data) !void {
    try store.begin();
    try store.putCopying(.{ .id = try store.allocateId(), .revision = 0, .schema = manifest_schema.id, .rooted = true, .payload = &@as([16]u8, @splat(0)), .edges = &.{ .{ .target = data.use }, .{ .target = data.control } } }, null);
    try h.f.commit(store, db);
}
fn manifest(store: *core.Store, db: *Lmdb) !Manifest {
    const lookup = db.lookup(.{ .ticket = .{ .store = store.metadata.store, .incarnation = store.metadata.incarnation, .sequence = 0, .revision = store.metadata.revision }, .name = .{ .schema = manifest_schema.id, .bytes = @splat(0) } });
    const id = switch (lookup) {
        .found => |id| id,
        .missing => return error.MissingManifest,
        .failed => |err| return err,
    };
    const lease = try h.c.load(store, db, id);
    defer store.release(lease) catch unreachable;
    const view = try store.currentView(lease);
    if (view.schema != manifest_schema.id or view.edge_count != 2) return error.InvalidManifest;
    var edges = view.edges();
    return .{ .use = edges.next().?.target, .control = edges.next().?.target };
}
fn entropy(context: ?*anyopaque, bytes: *h.driver.Host.DurableSwiss.Entropy) !void {
    const counter: *u64 = @ptrCast(@alignCast(context.?));
    counter.* += 1;
    @memset(bytes, 0);
    std.mem.writeInt(u64, bytes[0..8], counter.*, .big);
}
fn name(role: Role) h.driver.Host.DurableSwiss {
    if (role == .use) {
        var bytes: h.driver.Host.DurableSwiss.Entropy = @splat(0);
        std.mem.writeInt(u64, bytes[0..8], 101, .big);
        return .fromEntropy(bytes);
    }
    return .fromEntropy(@splat(if (role == .original) 0x74 else 0x75));
}

pub fn main(init: std.process.Init) !void {
    const args = init.minimal.args.vector;
    if (args.len != 4) return error.InvalidArguments;
    const mode = std.mem.span(args[1]);
    const role = std.meta.stringToEnum(Role, std.mem.span(args[3])) orelse return error.InvalidArguments;
    const creating = std.mem.eql(u8, mode, "create");
    const verifying = std.mem.startsWith(u8, mode, "verify-");
    const boundary = if (creating or verifying) null else std.meta.stringToEnum(Boundary, mode) orelse return error.InvalidArguments;
    const target_path = try std.fmt.allocPrintSentinel(init.gpa, "{s}/target", .{std.mem.span(args[2])}, 0);
    defer init.gpa.free(target_path);
    if (creating) try std.Io.Dir.cwd().createDirPath(init.io, target_path);
    var source_db = try Lmdb.open(std.mem.span(args[2]), .{ .mode = if (creating) .{ .create = h.f.store_id } else .{ .open = h.f.store_id } });
    defer source_db.close() catch unreachable;
    var target_db = try Lmdb.open(target_path, .{ .mode = if (creating) .{ .create = @fromBackingInt(95) } else .{ .open = @fromBackingInt(95) } });
    defer target_db.close() catch unreachable;
    var source_store = try core.Store.init(init.gpa, source_db.metadata, &schemas, h.limits);
    defer source_store.deinit() catch unreachable;
    var target_store = try core.Store.init(init.gpa, target_db.metadata, &schemas, h.limits);
    defer target_store.deinit() catch unreachable;
    if (creating) {
        const source_data = try h.seed(&source_store, &source_db);
        const target_data = try h.seedDepth(&target_store, &target_db, 1);
        try stageManifest(&source_store, &source_db, source_data);
        try stageManifest(&target_store, &target_db, target_data);
        var source: h.Hosted = undefined;
        try source.initIdentity(&source_store, &source_db, source_data, .{}, @splat(0x61));
        defer source.deinit();
        var target: h.Hosted = undefined;
        try target.initIdentity(&target_store, &target_db, target_data, .{}, @splat(0x65));
        defer target.deinit();
        _ = try f.publication(&target, &target_db, target_data.use, @splat(0x74));
        _ = try f.publication(&target, &target_db, target_data.control, @splat(0x75));
        if (role == .use) {
            const pair = try f.pairs.openPair(&source.host, &target.host, "127.0.0.1:9791");
            const original = try f.fetch(&source, &source_db, &target, &target_db, pair, name(.original));
            defer source.host.releaseCapabilityTerminal(original, null);
            var counter: u64 = 100;
            target.service.decode_derive = sharing.decode;
            target.service.entropy = .{ .context = &counter, .fill = entropy };
            const derived = try f.send(&source, &source_db, &target, &target_db, pair, original, "derive", &.{ .{ .integer = 1 }, .{ .integer = 0 }, .{ .integer = 0 } });
            defer derived.deinit();
            if (derived.result() != .ready) return error.DerivationFailed;
        }
        return;
    }
    const source_names = try manifest(&source_store, &source_db);
    const target_names = try manifest(&target_store, &target_db);
    var source: h.Hosted = undefined;
    try source.open(&source_store, &source_db, source_names.use, source_names.control, .{}, @splat(0x61));
    defer source.deinit();
    source.service.contents = &f.contents;
    var target: h.Hosted = undefined;
    try target.open(&target_store, &target_db, target_names.use, target_names.control, .{}, @splat(0x65));
    defer target.deinit();
    try h.loam.hosting.publication.listen(target.attached, .{});
    const pair = try f.pairs.openPair(&source.host, &target.host, "127.0.0.1:9791");
    if (verifying) {
        const read = try f.send(&source, &source_db, &target, &target_db, pair, source.use, "get", &.{});
        defer read.deinit();
        if (read.result() != .ready or read.result().ready.integer != (if (std.mem.eql(u8, mode, "verify-new")) @as(i64, 17) else 0)) return error.PartialContentWrite;
        const restored = try f.send(&source, &source_db, &target, &target_db, pair, source.use, "ref", &.{.{ .integer = 0 }});
        defer restored.deinit();
        if (restored.result() != .ready) return error.RestorationFailed;
        if (std.mem.eql(u8, mode, "verify-old")) return;
        const cap = restored.result().ready.capability;
        const acted = try f.send(&source, &source_db, &target, &target_db, pair, cap, if (role == .control) "pause" else "mutate", if (role == .control) &.{} else &.{ .{ .integer = 1 }, .{ .string = "add" }, .{ .integer = 3 } });
        defer acted.deinit();
        if (role == .use) {
            if (acted.result() != .failed) return error.RoleEscalation;
        } else if (acted.result() != .ready) return error.AuthorityLost;
        return;
    }
    const cap = try f.fetch(&source, &source_db, &target, &target_db, pair, name(role));
    defer source.host.releaseCapabilityTerminal(cap, null);
    const uri = try f.uri(init.gpa, name(role));
    defer init.gpa.free(uri);
    const write = try source.host.callCapability(init.gpa, pair.a, source.use, "put", &.{ .{ .integer = 0 }, .{ .capability = cap }, .{ .string = uri } }, 4096);
    defer write.deinit();
    const batch = blk: {
        for (0..512) |_| {
            try source.host.flushSession(pair.a);
            try target.host.flushSession(pair.b);
            try f.pairs.pumpToQuiescence(&.{pair});
            try source.attached.advance();
            if (try source.reads(&source_db)) |batch| break :blk batch;
            try target.attached.advance();
            if (try target.reads(&target_db)) |batch| try target.attached.completeWrite(batch.ticket, target_db.commit(batch));
        }
        return error.DidNotWrite;
    };
    if (boundary.? == .before) stop();
    const outcome = source_db.commit(batch);
    if (outcome != .committed) return error.CommitFailed;
    if (boundary.? == .after) stop();
    try source.attached.completeWrite(batch.ticket, outcome);
    if (write.result() != .pending) return error.ReplyBeforeSettlement;
    stop();
}
