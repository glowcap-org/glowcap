//! Background listen for the non-argv fronts (MCP and the REPL): bind, reply
//! with the `ocapn://` locator at once, and accept and serve partners on one
//! background thread. An accept loop must never park the stdio or prompt
//! loop that carried the command. The thread owns the bound server and every
//! accepted session. The fronts share only the stop latch, the accepted
//! counter, and byte copies written before the thread starts. The process
//! `gpa` and `Io` are documented threadsafe. Without that the thread could
//! not use them at all.
//!
//! One listener per process context. A second `listen` refuses while one is
//! held. `close` (which also drops the held session) and process teardown
//! stop the thread through the latch, which the accept wait polls on the
//! same cadence the argv front polls its signal latch.

const std = @import("std");
const zig_builtin = @import("builtin");
const glowcap = @import("glowcap");
const ctx_mod = @import("../ctx.zig");
const cmd_types = @import("../cmd/types.zig");
const argv = @import("../argv.zig");
const exit_codes = @import("../exit_codes.zig");
const ocapn = @import("mod.zig");
const relay_runtime = @import("relay_runtime.zig");
const signals = @import("../operability/signals.zig");

const driver = glowcap.driver;
const model = glowcap.ocapn.model;
const Ctx = ctx_mod.Ctx;
const FailureChain = glowcap.foundation.FailureChain;
const session_opts = @import("session_opts.zig");
const listen_close = @import("listen_close.zig");

const TestControl = if (zig_builtin.is_test) struct {
    request_terminal_failure: std.atomic.Value(bool) = .init(false),
    terminal_failure_published: std.atomic.Value(bool) = .init(false),
} else struct {};

/// One live background listener: the bound server, its accept thread, and
/// the two atomics the fronts read. Freed only through `shutdown`.
pub const Handle = struct {
    gpa: std.mem.Allocator,
    /// The listening transport's residents. They live here rather than on
    /// `start`'s frame because the server borrows one for the accept thread's
    /// whole life. Which one is chosen is `ocapn.listenTarget`'s decision.
    relay: ?relay_runtime.Provider = null,
    server: *driver.Server,
    thread: std.Thread = undefined,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    accepted: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Owned copy of the `--publish` builtin name, or null.
    publish: ?[]u8,
    once: bool,
    /// Owned copy of the bound locator, for `info` and refusal messages.
    locator: []u8,
    /// Why the accept loop stopped, when it stopped by itself: a fault's
    /// error name, or `served_stop` after a `--once`/`--publish` listener
    /// answered its one partner. Read by the fronts so a listener that is no
    /// longer accepting, for either reason, cannot keep reporting itself as
    /// listening. The bound socket stays held either way, so the locator in
    /// `info` stays accurate.
    stop_reason: std.atomic.Value(?[*:0]const u8) = std.atomic.Value(?[*:0]const u8).init(null),
    /// First failure owned by the accept thread. It is read after `join` and
    /// becomes the close operation's primary cause, rather than an info-only
    /// status that disappears when the thread exits.
    terminal_failure: ?FailureChain = null,
    thread_joined: bool = false,
    server_closed: bool = false,
    test_control: TestControl = .{},

    /// The benign stop: the one-partner listener served its partner and went
    /// quiet.
    pub const served_stop: [*:0]const u8 = "served its one partner";

    /// Test-only control for producing a listener failure on the accept
    /// thread. The acknowledgement is the synchronization point. Tests must
    /// still use `shutdown`/`cmdClose` before observing the failure itself.
    pub const testing = if (zig_builtin.is_test) struct {
        pub fn requestTerminalFailure(handle: *Handle) void {
            handle.test_control.request_terminal_failure.store(true, .release);
            while (!handle.test_control.terminal_failure_published.load(.acquire)) {
                // tolerant: a refused yield only spins this test wait hotter.
                std.Thread.yield() catch {};
            }
        }
    } else struct {};

    pub const Shutdown = struct {
        failure: ?FailureChain,
        /// False when the relay provider refused deinit: this handle is still
        /// the retry owner and must stay in the process context.
        consumed: bool,
    };

    /// Stop the accept thread through the latch, join it, and close the
    /// Server through its explicit barrier. Callable from the front's own
    /// thread only.
    ///
    /// The join can outlast the latch's poll cadence: the thread may be
    /// inside an accept, whose keyed handshake runs under the session
    /// handshake budget and does not consult the latch. A partner that
    /// connects and then says nothing therefore delays a `close` by that
    /// budget rather than by a poll interval.
    pub fn shutdown(handle: *Handle, ctx: *Ctx) Shutdown {
        handle.stop.store(true, .release);
        if (!handle.thread_joined) {
            handle.thread.join();
            handle.thread_joined = true;
        }
        var failure: ?FailureChain = null;
        if (handle.terminal_failure) |thread_failure| failure = thread_failure;
        if (!handle.server_closed) {
            if (listen_close.closeServer(ctx, handle.server)) |chain| {
                ctx.retainCleanup(&failure, chain);
            }
            handle.server_closed = true;
        }
        if (handle.relay) |*provider| {
            if (relay_runtime.deinitAndReport(ctx, provider)) |cleanup| {
                ctx.retainCleanup(&failure, cleanup);
                return .{ .failure = failure, .consumed = false };
            }
            handle.relay = null;
        }
        if (handle.publish) |name| handle.gpa.free(name);
        handle.gpa.free(handle.locator);
        handle.gpa.destroy(handle);
        return .{ .failure = failure, .consumed = true };
    }
};

fn isSessionFailure(err: anyerror) bool {
    // Once accept has yielded a session, transport, protocol, and timeout
    // failures belong to that partner. Reuse the driver's classification so
    // a new pump error cannot silently become listener-fatal here.
    return switch (driver.OperationFailure.classify(err)) {
        .timeout, .closed, .session, .malformed, .frame_too_large, .io => true,
        .invalid_argument, .would_block, .internal => false,
    };
}

fn isAcceptedPeerFailure(err: anyerror) bool {
    return switch (err) {
        // These are failures of the listener's own socket/runtime machinery,
        // not bytes supplied by the connection being accepted.
        error.SocketConfigurationFailed,
        error.WakeNudgeFailed,
        error.WakeDrainFailed,
        => false,
        else => isSessionFailure(err),
    };
}

const ServeOutcome = enum { peer_ended, terminal, stopped };

fn continueAfterServe(outcome: ServeOutcome, one_shot: bool) bool {
    return outcome == .peer_ended and !one_shot;
}

fn consumeTestTerminalFailure(handle: *Handle) bool {
    if (comptime zig_builtin.is_test) {
        if (!handle.test_control.request_terminal_failure.swap(false, .acq_rel)) return false;
        handle.stop_reason.store(@errorName(error.SocketConfigurationFailed), .release);
        handle.terminal_failure = .init(error.SocketConfigurationFailed);
        handle.test_control.terminal_failure_published.store(true, .release);
        return true;
    }
    return false;
}

/// The non-argv `listen`: bind now, answer with the locator now, accept in
/// the background until `close` or teardown. `--once` / `--publish` serve
/// one partner and then go quiet (the bound socket stays held until the
/// listener is closed, so the locator in `info` stays accurate).
pub fn start(ctx: *Ctx, parsed: *cmd_types.Parsed) !u8 {
    if (ctx.background_listener != null) {
        ctx.logErr("a listener is already running (see `info`). `close` it first", .{});
        return exit_codes.usage;
    }
    const bind = parsed.flagString("bind") orelse "127.0.0.1:0";
    const publish_name = parsed.flagString("publish");
    const once = parsed.flagBool("once");
    if (publish_name) |name| {
        var known = false;
        for (ocapn.builtin_names) |builtin_name| {
            if (std.mem.eql(u8, builtin_name, name)) known = true;
        }
        if (!known) {
            ctx.logErr("unknown --publish {s} (want greeter or echo)", .{name});
            return exit_codes.usage;
        }
    }

    const accept_id = try ctx.acceptIdentity();

    // The handle is allocated before the server because it owns the relay
    // TLS runtime the server's relay backend leases.
    const handle = try ctx.gpa.create(Handle);
    handle.relay = null;
    // `errdefer` fires only on an error return, and this verb reports its
    // refusals as exit codes (a plain `return`). So ownership is tracked with
    // a flag and released by `defer`, which covers every exit.
    var handed_over = false;
    defer if (!handed_over) {
        if (handle.relay) |*provider| {
            _ = relay_runtime.deinitAndReport(ctx, provider);
        }
        ctx.gpa.destroy(handle);
    };
    const target = ocapn.listenTarget(
        ctx,
        bind,
        parsed.flagString("rendezvous"),
        parsed.flagString("rendezvous-relay"),
        &handle.relay,
    ) catch |err| switch (err) {
        error.Usage => return exit_codes.usage,
        error.OutOfMemory => return err,
        else => return exit_codes.dial,
    };
    var server = driver.listen(ctx.gpa, ctx.io, target.transports, target.transport, .{ .designator = target.designator }, accept_id, session_opts.sessionOptsReporting(ctx)) catch |err| {
        ctx.logErr("listen: {s}", .{@errorName(err)});
        return exit_codes.dial;
    };
    var server_owned = true;
    defer if (server_owned) server.deinit();

    const uri = try model.uri.writePeer(ctx.gpa, (try server.advertisedLocator()));
    defer ctx.gpa.free(uri);

    // Flag-guarded like the handle: once the thread is live these belong to
    // it, and an `errdefer` firing afterwards would free memory the thread is
    // still reading and `shutdown` will free again.
    const locator_copy = try ctx.gpa.dupe(u8, uri);
    defer if (!handed_over) ctx.gpa.free(locator_copy);
    const publish_copy: ?[]u8 = if (publish_name) |name| try ctx.gpa.dupe(u8, name) else null;
    defer if (!handed_over) if (publish_copy) |name| ctx.gpa.free(name);
    // Field-wise: `relay` already holds the TLS runtime the server leases,
    // so the whole struct must not be overwritten.
    handle.gpa = ctx.gpa;
    handle.server = server;
    handle.stop = .init(false);
    handle.accepted = .init(0);
    handle.publish = publish_copy;
    handle.once = once;
    handle.locator = locator_copy;
    handle.stop_reason = .init(null);
    handle.terminal_failure = null;
    handle.thread_joined = false;
    handle.server_closed = false;
    handle.thread = try std.Thread.spawn(.{}, acceptLoop, .{handle});
    // The handle owns the server and itself; the accept thread is live.
    server_owned = false;
    handed_over = true;
    ctx.background_listener = handle;

    // From here nothing may fail into a cleanup the live thread owns; the
    // flags above are already flipped, so the defers are inert.
    const last_copy = try ctx.gpa.dupe(u8, uri);
    ctx.publishLocator(last_copy);

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
    ctx.logInfo("listening in the background. `close` stops it", .{});
    return exit_codes.ok;
}

/// The background accept loop: the thread-owned mirror of the argv front's
/// signal-latched loop, latched on the handle's stop flag instead.
fn acceptLoop(handle: *Handle) void {
    while (!handle.stop.load(.acquire)) {
        if (consumeTestTerminalFailure(handle)) return;
        const ready = handle.server.waitAcceptable(signals.poll_ms) catch |err| {
            // The listener is finished and nobody asked it to be. Record why,
            // so `info` reports a dead listener instead of a live one.
            handle.stop_reason.store(@errorName(err), .release);
            handle.terminal_failure = .init(err);
            return;
        };
        if (!ready) continue;
        if (handle.stop.load(.acquire)) return;
        var session = handle.server.accept() catch |err| {
            if (isAcceptedPeerFailure(err)) continue;
            handle.stop_reason.store(@errorName(err), .release);
            handle.terminal_failure = .init(err);
            return;
        };
        defer session.deinit();
        if (handle.publish) |name| {
            // The name was validated at `start`, so a failure here is a torn
            // connection. Serving a partner with nothing published would only
            // give it a session that answers no fetch, so drop it instead.
            ocapn.publishBuiltin(session, name) catch |err| {
                handle.stop_reason.store(@errorName(err), .release);
                handle.terminal_failure = .init(err);
                return;
            };
        }
        _ = handle.accepted.fetchAdd(1, .monotonic);
        const outcome = serveUntilStop(session, handle);
        if (!continueAfterServe(outcome, handle.once or handle.publish != null)) {
            if (outcome == .peer_ended and (handle.once or handle.publish != null)) {
                handle.stop_reason.store(Handle.served_stop, .release);
            }
            return;
        }
    }
}

/// Serve until the partner leaves or the stop latch fires. This is the background
/// twin of the argv front's signal-latched serve. A partner drop is quiet. Any
/// other step failure is this loop's primary and is stored for `info`.
fn serveUntilStop(session: *driver.Session, handle: *Handle) ServeOutcome {
    while (!handle.stop.load(.acquire)) {
        const progress = session.stepReadable(signals.poll_ms) catch |err| {
            if (isSessionFailure(err)) return .peer_ended;
            handle.stop_reason.store(@errorName(err), .release);
            handle.terminal_failure = .init(err);
            return .terminal;
        };
        if (progress) |p| if (p == .closed) return .peer_ended;
    }
    return .stopped;
}

test "background listener keeps peer failures local" {
    try std.testing.expect(isAcceptedPeerFailure(error.ConnectionLost));
    try std.testing.expect(isAcceptedPeerFailure(error.HandshakeTimedOut));
    try std.testing.expect(isSessionFailure(error.MalformedFrame));
    try std.testing.expect(isSessionFailure(error.ProtocolAbort));
    try std.testing.expect(isSessionFailure(error.AbortFlushFailed));
    try std.testing.expect(!isSessionFailure(error.OutOfMemory));
    try std.testing.expect(!isAcceptedPeerFailure(error.SocketConfigurationFailed));
    try std.testing.expect(!isAcceptedPeerFailure(error.WakeDrainFailed));
}

test "background listener exits after terminal serving failure" {
    try std.testing.expect(continueAfterServe(.peer_ended, false));
    try std.testing.expect(!continueAfterServe(.peer_ended, true));
    try std.testing.expect(!continueAfterServe(.terminal, false));
    try std.testing.expect(!continueAfterServe(.stopped, false));
}
