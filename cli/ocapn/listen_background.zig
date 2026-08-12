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
    /// The listening transport's residents. They live here rather than on
    /// `start`'s frame because the server borrows one for the accept thread's
    /// whole life; which one is chosen is `ocapn.listenTarget`'s decision.
    tcp: pancake.net.tcp.Resident = undefined,
    relay: ?pancake.net.keyed_relay.Resident = null,
    server: driver.Server,
    thread: std.Thread = undefined,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    accepted: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Owned copy of the `--publish` builtin name, or null.
    publish: ?[]u8,
    once: bool,
    /// Owned copy of the bound locator, for `info` and refusal messages.
    locator: []u8,
    /// Why the accept loop stopped, when it stopped by itself — a fault's
    /// error name, or `served_stop` after a `--once`/`--publish` listener
    /// answered its one partner. Read by the fronts so a listener that is no
    /// longer accepting, for either reason, cannot keep reporting itself as
    /// listening. The bound socket stays held either way, so the locator in
    /// `info` stays honest.
    stop_reason: std.atomic.Value(?[*:0]const u8) = std.atomic.Value(?[*:0]const u8).init(null),

    /// The benign stop: the one-partner listener served its partner and went
    /// quiet by design.
    pub const served_stop: [*:0]const u8 = "served its one partner";

    /// Stop the accept thread through the latch, join it, and free
    /// everything. Callable from the front's own thread only.
    ///
    /// The join can outlast the latch's poll cadence: the thread may be
    /// inside an accept, whose keyed handshake runs under the session
    /// handshake budget and does not consult the latch. A partner that
    /// connects and then says nothing therefore delays a `close` by that
    /// budget rather than by a poll interval.
    pub fn shutdown(handle: *Handle) void {
        handle.stop.store(true, .release);
        handle.thread.join();
        handle.server.close() catch {};
        if (handle.relay) |*resident| resident.deinit();
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

    const accept_id = try ctx.acceptIdentity();

    // The handle is allocated before the server because it owns the
    // transport residents the server will borrow, and a resident must not
    // move once a netlayer points at it.
    const handle = try ctx.gpa.create(Handle);
    handle.relay = null;
    // `errdefer` fires only on an error return, and this verb reports its
    // refusals as exit codes — a plain `return`. So ownership is tracked with
    // a flag and released by `defer`, which covers every exit.
    var handed_over = false;
    defer if (!handed_over) {
        if (handle.relay) |*resident| resident.deinit();
        ctx.gpa.destroy(handle);
    };
    const target = ocapn.listenTarget(
        ctx,
        bind,
        parsed.flagString("rendezvous"),
        parsed.flagString("rendezvous-relay"),
        &handle.tcp,
        &handle.relay,
    ) catch |err| switch (err) {
        error.Usage => return exit_codes.usage,
        else => return err,
    };
    var server = driver.listen(ctx.gpa, target.netlayer, .{ .designator = target.designator }, accept_id, ocapn.sessionOpts()) catch |err| {
        ctx.logErr("listen: {s}", .{@errorName(err)});
        return exit_codes.dial;
    };
    var server_owned = true;
    defer if (server_owned) server.close() catch {};

    const uri = try model.uri.writePeer(ctx.gpa, server.advertisedLocator());
    defer ctx.gpa.free(uri);

    // Flag-guarded like the handle: once the thread is live these belong to
    // it, and an `errdefer` firing afterwards would free memory the thread is
    // still reading and `shutdown` will free again.
    const locator_copy = try ctx.gpa.dupe(u8, uri);
    defer if (!handed_over) ctx.gpa.free(locator_copy);
    const publish_copy: ?[]u8 = if (publish_name) |name| try ctx.gpa.dupe(u8, name) else null;
    defer if (!handed_over) if (publish_copy) |name| ctx.gpa.free(name);
    // Field-wise: `tcp`/`relay` already hold the residents the netlayer
    // above points at, so the whole struct must not be overwritten.
    handle.gpa = ctx.gpa;
    handle.server = server;
    handle.stop = .init(false);
    handle.accepted = .init(0);
    handle.publish = publish_copy;
    handle.once = once;
    handle.locator = locator_copy;
    handle.stop_reason = .init(null);
    handle.thread = try std.Thread.spawn(.{}, acceptLoop, .{handle});
    // The handle now owns the server and itself; the accept thread is live.
    server_owned = false;
    handed_over = true;
    ctx.background_listener = handle;

    // From here nothing may fail into a cleanup the live thread owns; the
    // flags above are already flipped, so the defers are inert.
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
        const ready = handle.server.waitAcceptable(signals.poll_ms) catch |err| {
            // The listener is finished and nobody asked it to be. Record why,
            // so `info` reports a dead listener instead of a live one.
            handle.stop_reason.store(@errorName(err), .release);
            return;
        };
        if (!ready) continue;
        if (handle.stop.load(.acquire)) return;
        var session = handle.server.accept() catch continue;
        defer session.deinit();
        if (handle.publish) |name| {
            // The name was validated at `start`, so a failure here is a torn
            // connection. Serving a partner with nothing published would only
            // give it a session that answers no fetch, so drop it instead.
            ocapn.publishBuiltin(session, name) catch continue;
        }
        _ = handle.accepted.fetchAdd(1, .monotonic);
        serveUntilStop(session, &handle.stop);
        if (handle.once or handle.publish != null) {
            handle.stop_reason.store(Handle.served_stop, .release);
            return;
        }
    }
}

/// Serve until the partner leaves or the stop latch fires — the background
/// twin of the argv front's signal-latched serve.
fn serveUntilStop(session: *driver.Session, stop: *const std.atomic.Value(bool)) void {
    while (!stop.load(.acquire)) {
        const progress = session.stepReadable(signals.poll_ms) catch return;
        if (progress) |p| if (p == .closed) return;
    }
}
