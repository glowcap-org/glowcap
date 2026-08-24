//! Argv `listen`: bind, print the locator, and accept on this thread until
//! stop, `--once`, or `--publish`. Teardown uses the same explicit Server
//! close barrier the background front joins, so a cleanup failure is the
//! command's outcome rather than an implicit `deinit`.

const std = @import("std");
const pancake = @import("pancake");
const Ctx = @import("../ctx.zig").Ctx;
const argv = @import("../argv.zig");
const exit_codes = @import("../exit_codes.zig");
const signals = @import("../operability/signals.zig");
const Parsed = @import("../cmd/types.zig").Parsed;
const relay_runtime = @import("relay_runtime.zig");
const listen_target = @import("listen_target.zig");
const session_opts = @import("session_opts.zig");
const listen_close = @import("listen_close.zig");
const builtins = @import("builtins.zig");

const driver = pancake.driver;
const model = pancake.ocapn.model;
const FailureChain = pancake.foundation.FailureChain;

pub fn run(ctx: *Ctx, parsed: *Parsed) !u8 {
    const bind = parsed.flagString("bind") orelse "127.0.0.1:0";
    const publish_name = parsed.flagString("publish");
    const once = parsed.flagBool("once");
    const accept_id = try ctx.acceptIdentity();

    var tcp = pancake.net.tcp.Resident{ .io = ctx.io };
    var relay: ?relay_runtime.Provider = null;
    const target = listen_target.select(
        ctx,
        bind,
        parsed.flagString("rendezvous"),
        parsed.flagString("rendezvous-relay"),
        &tcp,
        &relay,
    ) catch |err| switch (err) {
        error.Usage => return exit_codes.usage,
        error.OutOfMemory => return err,
        else => return exit_codes.dial,
    };

    var server = driver.listen(
        ctx.gpa,
        target.netlayer,
        .{ .designator = target.designator },
        accept_id,
        session_opts.sessionOptsReporting(ctx),
    ) catch |err| {
        ctx.logErr("listen: {s}", .{@errorName(err)});
        return finishListen(ctx, null, &relay, exit_codes.dial);
    };
    var server_open = true;
    errdefer if (server_open) {
        _ = finishListen(ctx, server, &relay, exit_codes.internal);
    };

    const uri = try model.uri.writePeer(ctx.gpa, (try server.advertisedLocator()));
    defer ctx.gpa.free(uri);
    const locator_copy = try ctx.gpa.dupe(u8, uri);
    ctx.publishLocator(locator_copy);

    if (ctx.json == .json) {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(ctx.gpa);
        try out.appendSlice(ctx.gpa, "{\"ok\":true,\"locator\":");
        try argv.writeJsonString(&out, ctx.gpa, uri);
        try out.appendSlice(ctx.gpa, "}\n");
        try ctx.writeResult(out.items);
    } else {
        var buf: [512]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "{s}\n", .{uri});
        try ctx.writeResult(line);
    }

    // Poll the listen seat so SIGINT/SIGTERM can exit without closing the
    // listen FD from another thread (Zig Threaded Io panics on that BADF).
    signals.install();

    // `--publish` / `--once` accept one partner then exit; until then this
    // process is intentionally idle on accept. Say so on stderr so a quiet
    // wait is not mistaken for a hang (stdout already carried the locator).
    if (publish_name) |name| {
        ctx.logInfo("listening; will publish {s} when a partner connects (Ctrl-C to stop)", .{name});
    } else if (once) {
        ctx.logInfo("listening; accepting one partner (Ctrl-C to stop)", .{});
    } else {
        ctx.logInfo("listening; Ctrl-C to stop", .{});
    }

    const loop_code = try acceptLoop(ctx, server, publish_name, once);
    server_open = false;
    return finishListen(ctx, server, &relay, loop_code);
}

fn acceptLoop(ctx: *Ctx, server: *driver.Server, publish_name: ?[]const u8, once: bool) !u8 {
    while (!signals.stopRequested()) {
        const ready = server.waitAcceptable(signals.poll_ms) catch |err| {
            if (signals.stopRequested()) return exit_codes.ok;
            ctx.logErr("listen wait: {s}", .{@errorName(err)});
            return exit_codes.internal;
        };
        if (!ready) continue;
        if (signals.stopRequested()) return exit_codes.ok;
        var session = server.accept() catch |err| {
            if (signals.stopRequested()) return exit_codes.ok;
            ctx.logErr("listen accept: {s}", .{@errorName(err)});
            return exit_codes.internal;
        };
        defer session.deinit();
        if (publish_name) |name| {
            builtins.publishBuiltin(session, name) catch |err| switch (err) {
                error.UnknownBuiltin => {
                    ctx.logErr("unknown --publish {s} (want greeter or echo)", .{name});
                    return exit_codes.usage;
                },
                else => return err,
            };
            ctx.logInfo("published {s}", .{name});
        }
        try serveUntilStop(session);
        if (signals.stopRequested()) return exit_codes.ok;
        if (once or publish_name != null) break;
    }
    return exit_codes.ok;
}

/// Serve until the partner leaves or SIGINT/SIGTERM sets the stop latch.
/// `Session.serve` parks in an unbounded read; chunked `stepReadable` lets the
/// latch end a published peer without closing the socket from another thread.
fn serveUntilStop(session: *driver.Session) !void {
    while (!signals.stopRequested()) {
        const progress = session.stepReadable(signals.poll_ms) catch |err| switch (err) {
            error.ConnectionLost, error.TruncatedFrame => return,
            else => return err,
        };
        if (progress) |p| if (p == .closed) return;
    }
}

fn finishListen(
    ctx: *Ctx,
    server: ?*driver.Server,
    relay: *?relay_runtime.Provider,
    code: u8,
) u8 {
    var failure: ?FailureChain = null;
    if (server) |s| {
        if (listen_close.closeServer(ctx, s)) |chain| failure = chain;
    }
    if (relay.*) |*provider| {
        if (relay_runtime.deinitAndReport(ctx, provider)) |cleanup| {
            ctx.retainCleanup(&failure, cleanup);
        } else {
            relay.* = null;
        }
    }
    if (failure) |chain| {
        if (code == exit_codes.ok) {
            ctx.logCloseFailure("listen close", chain);
            return ctx.mapCloseErr(chain.cause);
        }
        ctx.logCloseFailure("listen cleanup", chain);
    }
    return code;
}
