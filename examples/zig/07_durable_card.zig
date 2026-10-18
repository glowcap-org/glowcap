//! 07: A card that survives a restart.
//!
//! Loam keeps an object and its state across a restart. This chapter stores
//! one task card in SQLite and moves it. Then it shuts everything down (the
//! Host, the Loam attachment, the store, and the database) and opens the same
//! directory again in a fresh Host. The card comes back with the move it made.
//!
//! The card is a sleepy actor. Its state is one record, and its behavior is a
//! plain function from that record and a call to a reply. Loam decides what to
//! read and write, `call` below plays the storage worker that does it, and the
//! reply arrives only after the write commits. The
//! [Loam page](https://jimisaacs.github.io/glowcap/loam/) explains the model.
//!
//! Run: `zig build examples` (it also runs under `zig build check`).

const std = @import("std");
const glowcap = @import("glowcap");
const Sqlite = @import("glowcap_loam_sqlite").Sqlite;
const core = glowcap.loam.core;
const hosting = glowcap.loam.hosting;
const driver = glowcap.driver.core;
const actors = glowcap.actors;

/// One schema: a card whose payload is how many times it has moved.
const card_schema = 1;
const schemas = [_]core.Schema{.{ .id = card_schema, .version = 1, .max_payload = 8, .max_edges = 1 }};
const limits: core.Store.Limits = .{
    .records = .{ .max_record_bytes = 256, .max_edges = 1 },
    .cache_slots = 2,
    .max_leases = 2,
    .resident_bytes = 1024,
    .max_changes = 4,
    .staging_bytes = 2048,
};
/// A real application draws a fresh identity when it creates the store and
/// keeps it, because reopening checks it.
const store_id: core.StoreId = @fromBackingInt(7);
const behaviors = [_]hosting.Behavior{.{ .schema = card_schema, .invoke = card }};

/// The card's whole behavior. `move` proposes new state. It counts only once
/// Loam commits it, so the code does no I/O of its own.
fn card(call_state: *hosting.Call, state: core.RecordView, verb: []const u8, args: []const driver.Value) !driver.Value {
    if (args.len != 0) return error.InvalidArguments;
    if (state.payload.len != 8) return error.InvalidCard;
    const moves = std.mem.readInt(i64, state.payload[0..8], .little);
    if (std.mem.eql(u8, verb, "moves")) return .{ .integer = moves };
    if (std.mem.eql(u8, verb, "move")) {
        const next = try call_state.arena().alloc(u8, 8);
        std.mem.writeInt(i64, next[0..8], moves + 1, .little);
        call_state.replace(next);
        return .{ .integer = moves + 1 };
    }
    return error.NoSuchMethod;
}

pub fn main(init: std.process.Init) !void {
    const args = init.minimal.args.vector;
    if (args.len != 2) return error.UsageStoreDirectory;
    const path: [:0]const u8 = std.mem.span(args[1]);
    try std.Io.Dir.cwd().createDirPath(init.io, path);

    // The first run creates the card and moves it. A real application keeps
    // the card's id, or publishes it under a durable name, to find it later.
    const id = try firstRun(init.gpa, init.io, path);
    // Everything the first run built is gone now. Open the same directory.
    try secondRun(init.gpa, init.io, path, id);
}

fn firstRun(allocator: std.mem.Allocator, io: std.Io, path: [:0]const u8) !core.ObjectId {
    var db = try Sqlite.open(path, .{ .opening = .{ .id = store_id, .mode = .create } });
    defer db.close() catch |err| std.log.err("closing SQLite: {s}", .{@errorName(err)});
    var store = try core.Store.init(allocator, db.metadata, &schemas, limits);
    defer store.deinit() catch |err| std.log.err("closing the store: {s}", .{@errorName(err)});

    // A rooted record, so collection always keeps it.
    try store.begin();
    const id = try store.allocateId();
    try store.putCopying(.{ .id = id, .revision = 0, .schema = card_schema, .payload = &@as([8]u8, @splat(0)), .rooted = true }, null);
    try commit(&store, &db);

    var host = try newHost(allocator, io);
    defer host.deinit();
    const attachment = try hosting.Attachment.create(allocator, &host, &store, &behaviors, .{});
    defer attachment.destroy() catch |err| std.log.err("closing the attachment: {s}", .{@errorName(err)});
    const card_cap = try restore(attachment, &db, id);
    defer host.releaseCapability(card_cap, 1) catch |err| std.log.err("releasing the card: {s}", .{@errorName(err)});

    const moved = try call(&host, attachment, &db, card_cap, "move");
    std.debug.print("first run: moved the card, {d} move so far\n", .{moved});
    return id;
}

fn secondRun(allocator: std.mem.Allocator, io: std.Io, path: [:0]const u8, id: core.ObjectId) !void {
    var db = try Sqlite.open(path, .{ .opening = .{ .id = store_id, .mode = .open } });
    defer db.close() catch |err| std.log.err("closing SQLite: {s}", .{@errorName(err)});
    var store = try core.Store.init(allocator, db.metadata, &schemas, limits);
    defer store.deinit() catch |err| std.log.err("closing the store: {s}", .{@errorName(err)});

    var host = try newHost(allocator, io);
    defer host.deinit();
    const attachment = try hosting.Attachment.create(allocator, &host, &store, &behaviors, .{});
    defer attachment.destroy() catch |err| std.log.err("closing the attachment: {s}", .{@errorName(err)});
    const card_cap = try restore(attachment, &db, id);
    defer host.releaseCapability(card_cap, 1) catch |err| std.log.err("releasing the card: {s}", .{@errorName(err)});

    const moves = try call(&host, attachment, &db, card_cap, "moves");
    if (moves != 1) return error.LostTheMove;
    std.debug.print("second run: after the restart the card remembers {d} move\n", .{moves});
}

fn newHost(allocator: std.mem.Allocator, io: std.Io) !driver.Host {
    var durable_seed: [32]u8 = undefined;
    try io.randomSecure(&durable_seed);
    var session_root: [32]u8 = undefined;
    try io.randomSecure(&session_root);
    return driver.Host.init(allocator, durable_seed, session_root, driver.Host.Options.withFrameCap(4096));
}

/// Commit the staged transaction. The backend does the write, Loam decides
/// what it contains and installs the result.
fn commit(store: *core.Store, db: *Sqlite) !void {
    const ticket = try store.prepare();
    const outcome = db.commit(try store.beginWrite(ticket));
    try store.completeWrite(ticket, outcome);
    if (outcome != .committed) return error.CommitFailed;
}

/// Turn the card's record back into a live capability.
fn restore(attachment: *hosting.Attachment, db: *Sqlite, id: core.ObjectId) !driver.Capability {
    const store = attachment.store;
    const lease = switch (try store.acquire(id)) {
        .ready => |lease| lease,
        .read => |read| blk: {
            try store.completeRead(read.ticket, db.read(read));
            break :blk (try store.acquire(id)).ready;
        },
    };
    defer store.release(lease) catch |err| std.log.err("releasing the lease: {s}", .{@errorName(err)});
    return attachment.restore(lease);
}

const Answer = struct {
    value: ?i64 = null,

    fn record(ctx: ?*anyopaque, result: actors.Resolution) void {
        const self: *Answer = @ptrCast(@alignCast(ctx.?));
        self.value = switch (result) {
            .fulfilled => |value| if (value == .integer) value.integer else null,
            else => null,
        };
    }
};

/// Call the card and run the storage work the call needs: the read that wakes
/// it, and the write that saves its new state before the reply is released.
fn call(host: *driver.Host, attachment: *hosting.Attachment, db: *Sqlite, card_cap: driver.Capability, verb: []const u8) !i64 {
    var answer: Answer = .{};
    const target = host.localActorFor(card_cap) orelse return error.NotLocal;
    _ = try host.vat.sendObservedFromIngress(.local, target, .{ .verb = verb, .args = &.{} }, .{ .ctx = &answer, .func = Answer.record });
    var slot: [1]hosting.Worker.Slot = undefined;
    var worker: hosting.Worker = .init(&slot, db.readerCapacity());
    for (0..64) |_| {
        _ = try host.vat.driveIngressBudgeted(.local, 64);
        try attachment.advance();
        try worker.drive(attachment, db);
        if (!attachment.hasPendingWork()) break;
    } else return error.DidNotSettle;
    return answer.value orelse error.NoReply;
}
