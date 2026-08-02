//! Background listen for the non-argv fronts (MCP and the REPL): bind, reply
//! with the `ocapn://` locator at once, and accept and serve partners on one
//! background thread — an accept loop must never park the stdio or prompt
//! loop that carried the command. The thread owns the bound server and every
//! accepted session; the fronts share only the stop latch, the accepted
//! counter, and byte copies written before the thread starts. The process
//! `gpa` and `Io` are documented threadsafe, which is what lets the thread
//! use them at all.
//!
//! One listener per process context. A second `listen` refuses while one is
//! held; `close` (which also drops the held session) and process teardown
//! stop the thread through the latch, which the accept wait polls on the
//! same cadence the argv front polls its signal latch.

const std = @import("std");
const pancake = @import("pancake");
const ctx_mod = @import("../ctx.zig");
const cmd_types = @import("../cmd/types.zig");
const argv = @import("../argv.zig");
const exit_codes = @import("../exit_codes.zig");
const ocapn = @import("mod.zig");
const signals = @import("../operability/signals.zig");

const driver = pancake.driver;
const model = pancake.ocapn.model;
const Ctx = ctx_mod.Ctx;

/// One live background listener: the bound server, its accept thread, and
/// the two atomics the fronts read. Freed only through `shutdown`.
pub const Handle = struct {
    gpa: std.mem.Allocator,
    server: driver.Server,
    thread: std.Thread = undefined,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    accepted: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Owned copy of the `--publish` builtin name, or null.
    publish: ?[]u8,
    once: bool,
    /// Owned copy of the bound locator, for `info` and refusal messages.
    locator: []u8,

    /// Stop the accept thread through the latch, join it, and free
    /// everything. Callable from the front's own thread only.
    pub fn shutdown(handle: *Handle) void {
        handle.stop.store(true, .release);
        handle.thread.join();
        handle.server.close() catch {};
        if (handle.publish) |name| handle.gpa.free(name);
        handle.gpa.free(handle.locator);
        handle.gpa.destroy(handle);
    }
};

/// The non-argv `listen`: bind now, answer with the locator now, accept in
/// the background until `close` or teardown. `--once` / `--publish` serve
/// one partner and then go quiet (the bound socket stays held until the
/// listener is closed, so the locator in `info` stays honest).
pub fn start(ctx: *Ctx, parsed: *cmd_types.Parsed) !u8 {
    if (ctx.background_listener != null) {
        ctx.logErr("a listener is already running (see `info`); `close` it first", .{});
        return exit_codes.usage;
    }
    const bind = parsed.flagString("bind") orelse "127.0.0.1:0";
    const publish_name = parsed.flagString("publish");
    const once = parsed.flagBool("once");
    if (publish_name) |name| {
        var known = false;
        for (ocapn.builtin_names) |builtin| {
            if (std.mem.eql(u8, builtin, name)) known = true;
        }
        if (!known) {
            ctx.logErr("unknown --publish {s} (want greeter or echo)", .{name});
            return exit_codes.usage;
        }
    }

    var tcp = pancake.net.tcp.Resident{ .io = ctx.io };
    const accept_id = try ctx.acceptIdentity();
    var server = try driver.listen(ctx.gpa, tcp.netlayer(), .{ .designator = bind }, accept_id, ocapn.sessionOpts());
    errdefer server.close() catch {};

    var addr_buf: [128]u8 = undefined;
    const designator = server.localDesignator(&addr_buf) catch {
        ctx.logErr("listen: no dialable local designator", .{});
        return exit_codes.internal;
    };
    const uri = try model.uri.writePeer(ctx.gpa, .{
        .transport = "tcp",
        .designator = designator,
        .hints = model.Hints.emptyFalse(),
    });
    defer ctx.gpa.free(uri);

    const handle = try ctx.gpa.create(Handle);
    errdefer ctx.gpa.destroy(handle);
    const locator_copy = try ctx.gpa.dupe(u8, uri);
    errdefer ctx.gpa.free(locator_copy);
    const publish_copy: ?[]u8 = if (publish_name) |name| try ctx.gpa.dupe(u8, name) else null;
    errdefer if (publish_copy) |name| ctx.gpa.free(name);
    handle.* = .{
        .gpa = ctx.gpa,
        .server = server,
        .publish = publish_copy,
        .once = once,
        .locator = locator_copy,
    };
    handle.thread = try std.Thread.spawn(.{}, acceptLoop, .{handle});
    ctx.background_listener = handle;

    // `last_locator` is what `info` reports and what the argv front sets too.
    const last_copy = try ctx.gpa.dupe(u8, uri);
    if (ctx.last_locator) |old| ctx.gpa.free(old);
    ctx.last_locator = last_copy;

    if (ctx.json == .json) {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(ctx.gpa);
        try out.appendSlice(ctx.gpa, "{\"ok\":true,\"locator\":");
        try argv.writeJsonString(&out, ctx.gpa, uri);
        try out.appendSlice(ctx.gpa, ",\"listening\":true}\n");
        try ctx.writeResult(out.items);
    } else {
        var buf: [512]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "{s}\n", .{uri});
        try ctx.writeResult(line);
    }
    ctx.logInfo("listening in the background; `close` stops it", .{});
    return exit_codes.ok;
}

/// The background accept loop: the thread-owned mirror of the argv front's
/// signal-latched loop, latched on the handle's stop flag instead.
fn acceptLoop(handle: *Handle) void {
    while (!handle.stop.load(.acquire)) {
        const ready = handle.server.waitAcceptable(signals.poll_ms) catch return;
        if (!ready) continue;
        if (handle.stop.load(.acquire)) return;
        var conn = handle.server.accept() catch continue;
        defer conn.deinit();
        if (handle.publish) |name| {
            // The name was validated at `start`; a publish that still fails
            // (a torn connection) just ends this partner.
            ocapn.publishBuiltin(conn, name) catch {};
        }
        _ = handle.accepted.fetchAdd(1, .monotonic);
        serveUntilStop(conn, &handle.stop);
        if (handle.once or handle.publish != null) return;
    }
}

/// Serve until the partner leaves or the stop latch fires — the background
/// twin of the argv front's signal-latched serve.
fn serveUntilStop(conn: *driver.Session, stop: *const std.atomic.Value(bool)) void {
    while (!stop.load(.acquire)) {
        const progress = conn.stepReadable(signals.poll_ms) catch return;
        if (progress) |p| if (p == .closed) return;
    }
}
