//! Progressive CapTP surface for the glowcap CLI (everyday tier).
const std = @import("std");
const glowcap = @import("glowcap");
const Ctx = @import("../ctx.zig").Ctx;
const argv = @import("../argv.zig");
const exit_codes = @import("../exit_codes.zig");
const Parsed = @import("../cmd/types.zig").Parsed;
const relay_runtime = @import("relay_runtime.zig");
const listen_target = @import("listen_target.zig");
const session_opts = @import("session_opts.zig");
const SessionRef = @import("session_ref.zig").SessionRef;

const driver = glowcap.driver;
const model = glowcap.ocapn.model;

/// Built-in demo actors (`greeter`, `echo`) live in `builtins.zig`. The public
/// entry point stays on this flat `ocapn` surface.
pub const publishBuiltin = @import("builtins.zig").publishBuiltin;
pub const builtin_names = @import("builtins.zig").names;

pub fn mapDialErr(err: anyerror) u8 {
    return switch (err) {
        error.IdentityMissing, error.IdentityCorrupt => exit_codes.identity,
        error.Usage => exit_codes.usage,
        error.HandshakeTimedOut, error.WaitTimedOut, error.CloseTimedOut => exit_codes.timeout,
        error.Busy => exit_codes.busy,
        error.CleanupPending => exit_codes.busy,
        error.OutOfMemory => exit_codes.internal,
        else => exit_codes.dial,
    };
}

/// CapTP act failures (call/tell/fetch): settle/handshake timeouts are exit 6.
pub fn mapActErr(err: anyerror) u8 {
    return switch (err) {
        error.HandshakeTimedOut, error.WaitTimedOut => exit_codes.timeout,
        error.OutOfMemory => exit_codes.internal,
        else => exit_codes.protocol_abort,
    };
}

fn failCapTp(ctx: *Ctx, session: ?*driver.Session, err: anyerror, comptime what: []const u8) u8 {
    // Bootstrap fetch of an unpublished name is the common agent miss; name it.
    if (err == error.FetchBroken) {
        ctx.logErr("{s}: peer has no capability published under that name", .{what});
        return mapActErr(err);
    }
    if (session) |s| {
        if (s.abortReason()) |reason| {
            ctx.logErr("{s}: {s} (abort: {s})", .{ what, @errorName(err), reason });
        } else {
            ctx.logErr("{s}: {s}", .{ what, @errorName(err) });
        }
    } else {
        ctx.logErr("{s}: {s}", .{ what, @errorName(err) });
    }
    return mapActErr(err);
}

fn printOut(ctx: *Ctx, comptime fmt: []const u8, args: anytype) !void {
    var buf: [8192]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, fmt, args);
    try ctx.writeResult(msg);
}

pub const default_handshake_timeout_ms = session_opts.default_handshake_timeout_ms;
pub const default_settle_timeout_ms = session_opts.default_settle_timeout_ms;
pub const sessionOptsReporting = session_opts.sessionOptsReporting;

pub fn sessionOpts() driver.SessionOptions {
    return session_opts.sessionOpts();
}

/// Dial with explicit session options (tests pass a short handshake budget).
/// `GLOWCAP_RENDEZVOUS` (a `ws://` or `wss://` relay URL) joins a
/// relay provider to the dial set, so `keyed-relay` and `noise-relay` locators
/// cold-dial through the same deployment-configured mapping ADR-0088 keeps out
/// of locator bytes.
pub fn dialUriWithOpts(ctx: *Ctx, uri: []const u8, opts: driver.SessionOptions) !*driver.Session {
    try ctx.ensureDialAllowed();
    const locator = try model.uri.parsePeer(ctx.gpa, uri);
    defer model.freePeerLocator(ctx.gpa, locator);
    var created_relay = false;
    if (ctx.environ.get("GLOWCAP_RENDEZVOUS")) |url| {
        if (ctx.rendezvous_provider == null) {
            ctx.rendezvous_provider = @as(relay_runtime.Provider, undefined);
            relay_runtime.init(ctx, &ctx.rendezvous_provider.?, url, null) catch |err| {
                ctx.rendezvous_provider = null;
                return err;
            };
            created_relay = true;
        }
    }
    // Undo only a provider this dial created; a refused deinit keeps the slot
    // as its own retry owner. Declared at function scope so it covers the
    // fallible identity load and dial below.
    errdefer if (created_relay) {
        const failure = relay_runtime.deinitAndReport(ctx, &ctx.rendezvous_provider.?);
        if (failure == null) ctx.rendezvous_provider = null;
    };
    const symbols: []const model.transport.Known = if (ctx.rendezvous_provider != null)
        &.{ .tcp, .keyed_relay, .noise_relay }
    else
        &.{.tcp};
    for (symbols) |symbol| {
        if (std.mem.eql(u8, symbol.metadata().symbol, locator.transport)) break;
    } else {
        var named: [64]u8 = undefined;
        var list: std.Io.Writer = .fixed(&named);
        // tolerant: the longest list is under 32 bytes, so a full buffer only shortens the hint.
        for (symbols, 0..) |symbol, i| list.print("{s}{s}", .{ if (i == 0) "" else ", ", symbol.metadata().symbol }) catch break;
        const hint = if (ctx.rendezvous_provider == null) " Set GLOWCAP_RENDEZVOUS to add the relay transports." else "";
        ctx.logErr("transport '{s}' is not available here. This CLI dials {s}.{s}", .{ locator.transport, list.buffered(), hint });
        return error.UnknownTransport;
    }
    const transports: driver.Transports = .{
        .symbols = symbols,
        .relay = if (ctx.rendezvous_provider) |*provider| try provider.options(ctx.io) else null,
    };
    const identity = try ctx.dialIdentity();
    return driver.connect(ctx.gpa, ctx.io, transports, locator, identity, session_opts.withRecipient(ctx, opts)) catch |err| {
        ctx.logErr("dial failed: {s}", .{@errorName(err)});
        return err;
    };
}

fn dialUri(ctx: *Ctx, uri: []const u8) !*driver.Session {
    return dialUriWithOpts(ctx, uri, sessionOpts());
}

pub fn printSettled(ctx: *Ctx, settled: driver.Reply) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(ctx.gpa);
    switch (ctx.json) {
        .json => switch (settled) {
            .fulfilled => |value| try appendValueJson(&out, ctx.gpa, value),
            .broken => |reason| {
                try out.appendSlice(ctx.gpa, "{\"ok\":false,\"broken\":");
                try argv.writeJsonString(&out, ctx.gpa, reason);
                try out.appendSlice(ctx.gpa, "}\n");
            },
        },
        .human => switch (settled) {
            .fulfilled => |value| try appendValueHuman(&out, ctx.gpa, value),
            .broken => |reason| try out.print(ctx.gpa, "broken: {s}\n", .{reason}),
        },
    }
    try ctx.writeResult(out.items);
}

fn appendValueHuman(out: *std.ArrayList(u8), gpa: std.mem.Allocator, value: driver.Value) !void {
    switch (value) {
        .string => |s| try out.print(gpa, "{s}\n", .{s}),
        .integer => |n| try out.print(gpa, "{d}\n", .{n}),
        .boolean => |b| try out.print(gpa, "{s}\n", .{if (b) "true" else "false"}),
        .void => try out.appendSlice(gpa, "void\n"),
        .capability => |cap| try out.print(gpa, "cap {d}\n", .{cap.raw()}),
        else => try out.print(gpa, "{s}\n", .{@tagName(value)}),
    }
}

fn appendValueJson(out: *std.ArrayList(u8), gpa: std.mem.Allocator, value: driver.Value) !void {
    switch (value) {
        .string => |s| {
            try out.appendSlice(gpa, "{\"ok\":true,\"value\":");
            try argv.writeJsonString(out, gpa, s);
            try out.appendSlice(gpa, "}\n");
        },
        .integer => |n| try out.print(gpa, "{{\"ok\":true,\"value\":{d}}}\n", .{n}),
        .boolean => |b| try out.print(gpa, "{{\"ok\":true,\"value\":{s}}}\n", .{if (b) "true" else "false"}),
        .void => try out.appendSlice(gpa, "{\"ok\":true,\"value\":null}\n"),
        .capability => |cap| try out.print(gpa, "{{\"ok\":true,\"cap\":{d}}}\n", .{cap.raw()}),
        else => try out.print(gpa, "{{\"ok\":true,\"value_kind\":\"{s}\"}}\n", .{@tagName(value)}),
    }
}

pub fn parseArgsList(gpa: std.mem.Allocator, raw: []const []const u8) ![]driver.Value {
    var list: std.ArrayList(driver.Value) = .empty;
    errdefer list.deinit(gpa);
    for (raw) |tok| {
        if (std.mem.eql(u8, tok, "true")) {
            try list.append(gpa, .{ .boolean = true });
        } else if (std.mem.eql(u8, tok, "false")) {
            try list.append(gpa, .{ .boolean = false });
        } else if (std.mem.eql(u8, tok, "null") or std.mem.eql(u8, tok, "void")) {
            try list.append(gpa, .void);
        } else if (std.fmt.parseInt(i64, tok, 10)) |n| {
            try list.append(gpa, .{ .integer = n });
        } else |_| {
            try list.append(gpa, .{ .string = tok });
        }
    }
    return try list.toOwnedSlice(gpa);
}

/// `#N` → the raw opaque capability id a prior fetch or reply printed (no
/// I/O). Named targets need a bootstrap fetch first (`beginFetch` / `fetch`).
/// This helper does not start one.
pub fn parseImportTarget(name_or_import: []const u8) !?u64 {
    if (name_or_import.len >= 2 and name_or_import[0] == '#') {
        return std.fmt.parseInt(u64, name_or_import[1..], 10) catch return error.Usage;
    }
    return null;
}

/// `#N` → re-scope the raw capability id to this session's host (a stale or
/// foreign id fails closed at the call). Otherwise bootstrap-fetch by
/// published name.
pub fn resolveTarget(session: *driver.Session, name_or_import: []const u8) !driver.Capability {
    if (try parseImportTarget(name_or_import)) |raw| return session.runtime.core.capabilityFromRaw(raw);
    return session.fetch(name_or_import);
}

/// Resolve a leading `ocapn://` dial or the held session. `name_i` indexes the
/// first non-uri positional (capability name).
///
/// On MCP/REPL, a locator when no session is held opens the retained peer (same
/// as `dial`). A locator while a session is already held is a one-shot sidecar
/// so the open peer stays put. Argv always one-shots the locator dial.
fn resolveSession(ctx: *Ctx, pos: []const []const u8, min_after_uri: usize) !struct { SessionRef, usize } {
    if (pos.len > 0 and std.mem.startsWith(u8, pos[0], "ocapn://")) {
        if (pos.len < 1 + min_after_uri) return error.Usage;
        const s = dialUri(ctx, pos[0]) catch |err| return err;
        if (retainSessionAfterDial(ctx) and ctx.activeSession() == null) {
            ctx.holdSession(s);
            return .{ .{ .borrow = s }, 1 };
        }
        return .{ .{ .owned = s }, 1 };
    }
    const held = ctx.activeSession() orelse return error.Usage;
    if (pos.len < min_after_uri) return error.Usage;
    return .{ .{ .borrow = held }, 0 };
}

pub const ListenTarget = listen_target.ListenTarget;
pub const listenTarget = listen_target.select;

pub fn cmdListen(ctx: *Ctx, parsed: *Parsed) !u8 {
    // An accept loop would starve the MCP stdio (or REPL prompt) loop, so the
    // non-argv fronts listen in the background: bind and answer now, accept
    // and serve on the listener's own thread.
    if (ctx.front != .argv) {
        return @import("listen_background.zig").start(ctx, parsed);
    }
    return @import("listen_foreground.zig").run(ctx, parsed);
}

pub fn cmdDial(ctx: *Ctx, parsed: *Parsed) !u8 {
    const want_repl = parsed.flagBool("repl");
    if (want_repl and ctx.front == .mcp) {
        ctx.logErr("dial --repl is argv-only (use `glowcap repl` or `glowcap ocapn dial --repl`)", .{});
        return exit_codes.usage;
    }
    const pos = parsed.positionals;
    if (pos.len == 0) {
        ctx.logErr("dial needs an ocapn:// locator", .{});
        return exit_codes.usage;
    }
    const target = pos[0];
    const session = dialUri(ctx, target) catch |err| return mapDialErr(err);
    if (!want_repl and !retainSessionAfterDial(ctx)) {
        const ref: SessionRef = .{ .owned = session };
        return ref.finish(ctx, reportDial(ctx, target));
    }
    if (ctx.closeHeldSession(.cancel)) |close_failure| {
        var failure = close_failure;
        if (session.close(.cancel)) |_| {
            session.deinit();
        } else |cleanup| {
            failure.note(cleanup);
            ctx.retainPendingSession(session);
        }
        if (ctx.takeCallerless()) |cleanup| failure.noteChain(cleanup);
        ctx.logErr(
            "replace session: {s} (and {d} later failure(s))",
            .{ failure.primaryName(), failure.secondary_count },
        );
        return mapDialErr(failure.cause);
    }
    ctx.holdSession(session);
    _ = try reportDial(ctx, target);
    if (want_repl) {
        ctx.front = .repl;
        return @import("../repl/mod.zig").runAttached(ctx);
    }
    return exit_codes.ok;
}

fn reportDial(ctx: *Ctx, target: []const u8) !u8 {
    if (ctx.json == .json) {
        try ctx.writeResult("{\"ok\":true,\"dialed\":true}\n");
    } else {
        ctx.logInfo("dialed {s}", .{target});
    }
    return exit_codes.ok;
}

/// Whether `cmdDial` should keep `ctx.session` open after a successful dial.
/// REPL and MCP fronts need it. Bare argv dial does not.
pub fn retainSessionAfterDial(ctx: *const Ctx) bool {
    return ctx.front == .mcp or ctx.front == .repl;
}

pub fn cmdProbe(ctx: *Ctx, parsed: *Parsed) !u8 {
    const pos = parsed.positionals;
    if (pos.len == 0) {
        ctx.logErr("probe needs an ocapn:// locator", .{});
        return exit_codes.usage;
    }
    const session = dialUri(ctx, pos[0]) catch |err| return mapDialErr(err);
    const ref: SessionRef = .{ .owned = session };
    return ref.finish(ctx, reportProbe(ctx));
}

fn reportProbe(ctx: *Ctx) !u8 {
    if (ctx.json == .json) {
        try ctx.writeResult("{\"ok\":true}\n");
    } else {
        try ctx.writeResult("ok\n");
    }
    return exit_codes.ok;
}

pub fn cmdCall(ctx: *Ctx, parsed: *Parsed) !u8 {
    const pos = parsed.positionals;
    const resolved = resolveSession(ctx, pos, 2) catch |err| switch (err) {
        error.Usage => {
            ctx.logErr("call needs <name|#N> <verb> [args…] (and a session or leading locator)", .{});
            return exit_codes.usage;
        },
        else => return mapDialErr(err),
    };
    const ref = resolved[0];
    return ref.finish(ctx, cmdCallResolved(ctx, pos, ref.ptr(), resolved[1]));
}

fn cmdCallResolved(ctx: *Ctx, pos: []const []const u8, session: *driver.Session, name_i: usize) !u8 {
    const target_tok = pos[name_i];
    const verb = pos[name_i + 1];
    const call_args = try parseArgsList(ctx.gpa, pos[name_i + 2 ..]);
    defer ctx.gpa.free(call_args);

    const target = resolveTarget(session, target_tok) catch |err| switch (err) {
        error.Usage => {
            ctx.logErr("call target must be a published name or #<cap>", .{});
            return exit_codes.usage;
        },
        else => return failCapTp(ctx, session, err, "fetch"),
    };
    var arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena.deinit();
    const settled = session.call(target, verb, call_args, arena.allocator()) catch |err| {
        return failCapTp(ctx, session, err, "call");
    };
    try printSettled(ctx, settled);
    return exit_codes.ok;
}

pub fn cmdTell(ctx: *Ctx, parsed: *Parsed) !u8 {
    const pos = parsed.positionals;
    const resolved = resolveSession(ctx, pos, 2) catch |err| switch (err) {
        error.Usage => {
            ctx.logErr("tell needs <name|#N> <verb> [args…]", .{});
            return exit_codes.usage;
        },
        else => return mapDialErr(err),
    };
    const ref = resolved[0];
    return ref.finish(ctx, cmdTellResolved(ctx, pos, ref.ptr(), resolved[1]));
}

fn cmdTellResolved(ctx: *Ctx, pos: []const []const u8, session: *driver.Session, name_i: usize) !u8 {
    const call_args = try parseArgsList(ctx.gpa, pos[name_i + 2 ..]);
    defer ctx.gpa.free(call_args);
    const target = resolveTarget(session, pos[name_i]) catch |err| switch (err) {
        error.Usage => {
            ctx.logErr("tell target must be a published name or #<cap>", .{});
            return exit_codes.usage;
        },
        else => return failCapTp(ctx, session, err, "fetch"),
    };
    session.tell(target, pos[name_i + 1], call_args) catch |err| {
        return failCapTp(ctx, session, err, "tell");
    };
    if (ctx.json == .json) try ctx.writeResult("{\"ok\":true}\n");
    return exit_codes.ok;
}

/// Fetch-success UX, shared by the blocking front here and the REPL's
/// cooperative queue, so two renderers keep one spelling. The number is the
/// opaque capability id (never a wire position, ADR-0096). `#N` feeds it back
/// to `call` / `tell`.
pub const fetched_fmt = "fetched {s} → cap {d}";
pub const fetch_next_fmt = "next: call {s} <verb> [args…]   or   call #{d} <verb> [args…]";

pub fn cmdFetch(ctx: *Ctx, parsed: *Parsed) !u8 {
    const pos = parsed.positionals;
    const resolved = resolveSession(ctx, pos, 1) catch |err| switch (err) {
        error.Usage => {
            ctx.logErr("fetch needs a published name (and a session or leading locator)", .{});
            return exit_codes.usage;
        },
        else => return mapDialErr(err),
    };
    const ref = resolved[0];
    return ref.finish(ctx, cmdFetchResolved(ctx, pos, ref.ptr(), resolved[1]));
}

fn cmdFetchResolved(ctx: *Ctx, pos: []const []const u8, session: *driver.Session, name_i: usize) !u8 {
    const name = pos[name_i];
    const target = session.fetch(name) catch |err| {
        return failCapTp(ctx, session, err, "fetch");
    };
    const cap_id = target.raw();
    if (ctx.json == .json) {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(ctx.gpa);
        try out.appendSlice(ctx.gpa, "{\"ok\":true,\"name\":");
        try argv.writeJsonString(&out, ctx.gpa, name);
        try out.print(ctx.gpa, ",\"cap\":{d}}}\n", .{cap_id});
        try ctx.writeResult(out.items);
    } else {
        try printOut(ctx, fetched_fmt ++ "\n", .{ name, cap_id });
        try printOut(ctx, fetch_next_fmt ++ "\n", .{ name, cap_id });
    }
    return exit_codes.ok;
}

pub fn cmdPublish(ctx: *Ctx, parsed: *Parsed) !u8 {
    const session = ctx.activeSession() orelse {
        ctx.logErr("publish needs an open session (dial --repl or mcp dial)", .{});
        return exit_codes.usage;
    };
    const name = if (parsed.positionals.len > 0) parsed.positionals[0] else "greeter";
    publishBuiltin(session, name) catch |err| switch (err) {
        error.UnknownBuiltin => {
            ctx.logErr("unknown publish {s} (want greeter or echo)", .{name});
            return exit_codes.usage;
        },
        else => return err,
    };
    if (ctx.json == .json) {
        try ctx.writeResult("{\"ok\":true}\n");
    } else {
        try printOut(ctx, "published {s}\n", .{name});
    }
    return exit_codes.ok;
}

pub fn cmdClose(ctx: *Ctx, parsed: *Parsed) !u8 {
    _ = parsed;
    if (ctx.closeOwned(.cancel)) |failure| {
        ctx.logCloseFailure("close", failure);
        return ctx.mapCloseErr(failure.cause);
    }
    if (ctx.json == .json) try ctx.writeResult("{\"ok\":true}\n");
    return exit_codes.ok;
}

pub fn cmdInfo(ctx: *Ctx, parsed: *Parsed) !u8 {
    _ = parsed;
    const secret = ctx.ensureSecret() catch |err|
        return @import("../operability/identity.zig").refuseSecret(ctx.io, err, ctx.identity_path);
    const designator = secret.publicKey().toDesignator();
    const active_session = ctx.activeSession();
    const abort = if (active_session) |s| s.partnerAbort() else null;
    const front = switch (ctx.front) {
        .argv => "argv",
        .repl => "repl",
        .mcp => "mcp",
    };
    if (ctx.json == .json) {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(ctx.gpa);
        try out.appendSlice(ctx.gpa, "{\"ok\":true,\"identity\":");
        try argv.writeJsonString(&out, ctx.gpa, designator[0..]);
        try out.print(ctx.gpa, ",\"session\":{s}", .{if (active_session != null) "true" else "false"});
        if (ctx.sessionCleanupPending()) try out.appendSlice(ctx.gpa, ",\"session_cleanup_pending\":true");
        try out.appendSlice(ctx.gpa, ",\"front\":");
        try argv.writeJsonString(&out, ctx.gpa, front);
        if (ctx.identity_path.len > 0) {
            try out.appendSlice(ctx.gpa, ",\"path\":");
            try argv.writeJsonString(&out, ctx.gpa, ctx.identity_path);
        }
        if (ctx.publishedLocator()) |loc| {
            try out.appendSlice(ctx.gpa, ",\"locator\":");
            try argv.writeJsonString(&out, ctx.gpa, loc);
        }
        if (ctx.background_listener) |listener| {
            // A listener that stopped accepting (a fault, or a one-partner
            // listener that served its partner) reports why rather than
            // claiming to be listening: the handle outlives the thread, so
            // its presence alone is not evidence of life.
            const stopped = listener.stop_reason.load(.acquire);
            try out.print(ctx.gpa, ",\"listening\":{s},\"accepted\":{d}", .{
                if (stopped == null) "true" else "false",
                listener.accepted.load(.acquire),
            });
            if (stopped) |reason| {
                try out.appendSlice(ctx.gpa, ",\"listener_stopped\":");
                try argv.writeJsonString(&out, ctx.gpa, std.mem.span(reason));
            }
        }
        if (abort) |info| {
            try out.appendSlice(ctx.gpa, ",\"abort_kind\":");
            try argv.writeJsonString(&out, ctx.gpa, info.kind.wireName());
            try out.appendSlice(ctx.gpa, ",\"abort\":");
            try argv.writeJsonString(&out, ctx.gpa, info.message);
        }
        try out.appendSlice(ctx.gpa, "}\n");
        try ctx.writeResult(out.items);
    } else {
        try printOut(ctx, "identity: {s}\n", .{designator[0..]});
        const session_status: []const u8 = if (active_session != null)
            "open"
        else if (ctx.sessionCleanupPending())
            "cleanup pending"
        else
            "none";
        try printOut(ctx, "session:  {s}\n", .{session_status});
        try printOut(ctx, "front:    {s}\n", .{front});
        if (ctx.publishedLocator()) |loc| try printOut(ctx, "locator:  {s}\n", .{loc});
        if (ctx.background_listener) |listener| {
            const stopped = listener.stop_reason.load(.acquire);
            try printOut(ctx, "listening: {s}\n", .{if (stopped == null) "true" else "false"});
            try printOut(ctx, "accepted:  {d}\n", .{listener.accepted.load(.acquire)});
            if (stopped) |reason| try printOut(ctx, "listener_stopped: {s}\n", .{std.mem.span(reason)});
        }
        if (abort) |info| {
            try printOut(ctx, "abort:    {s}: {s}\n", .{ info.kind.wireName(), info.message });
        }
        if (ctx.identity_path.len > 0) try printOut(ctx, "path:     {s}\n", .{ctx.identity_path});
    }
    return exit_codes.ok;
}

pub fn cmdLocator(ctx: *Ctx, parsed: *Parsed) !u8 {
    _ = parsed;
    const loc = ctx.publishedLocator() orelse {
        ctx.logErr("no listen locator in this process", .{});
        return exit_codes.usage;
    };
    try printOut(ctx, "{s}\n", .{loc});
    return exit_codes.ok;
}
