//! Progressive CapTP surface for the pancake CLI (everyday tier).
const std = @import("std");
const pancake = @import("pancake");
const Ctx = @import("../ctx.zig").Ctx;
const argv = @import("../argv.zig");
const exit_codes = @import("../exit_codes.zig");
const signals = @import("../operability/signals.zig");
const Parsed = @import("../cmd/types.zig").Parsed;

const driver = pancake.driver;
const model = pancake.ocapn.model;
const actors = pancake.actors;

/// Built-in demo actors (`greeter`, `echo`) live in `builtins.zig`; the public
/// entry point stays on this flat `ocapn` surface.
pub const publishBuiltin = @import("builtins.zig").publishBuiltin;
pub const builtin_names = @import("builtins.zig").names;

const SessionRef = union(enum) {
    borrow: *driver.Session,
    owned: *driver.Session,

    fn ptr(self: SessionRef) *driver.Session {
        return switch (self) {
            .borrow => |s| s,
            .owned => |s| s,
        };
    }

    fn deinit(self: SessionRef) void {
        switch (self) {
            .borrow => {},
            .owned => |s| s.deinit(),
        }
    }
};

pub fn mapDialErr(err: anyerror) u8 {
    return switch (err) {
        error.IdentityMissing, error.IdentityCorrupt => exit_codes.identity,
        error.Usage => exit_codes.usage,
        error.HandshakeTimedOut, error.WaitTimedOut => exit_codes.timeout,
        error.Busy => exit_codes.busy,
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

/// Product CapTP deadlines (ADR-0081). Zero would park forever on a silent peer.
pub const default_handshake_timeout_ms: i32 = 10_000;
pub const default_settle_timeout_ms: i32 = 30_000;

pub fn sessionOpts() driver.SessionOptions {
    return .{
        .handshake = .{ .ms = default_handshake_timeout_ms },
        .settle = .{ .ms = default_settle_timeout_ms },
    };
}

/// Dial with explicit session options (tests pass a short handshake budget).
/// `PANCAKE_RENDEZVOUS` (a `ws://host:port/path` relay URL) joins a
/// keyed-relay resident to the dial set, so a `keyed-relay` locator cold-dials
/// a registered peer through that relay — the deployment-configured mapping
/// ADR-0088 keeps out of locator bytes.
pub fn dialUriWithOpts(ctx: *Ctx, uri: []const u8, opts: driver.SessionOptions) !*driver.Session {
    ctx.dial_resident = .{ .io = ctx.io };
    ctx.dial_netlayers[0] = ctx.dial_resident.netlayer();
    var netlayer_count: usize = 1;
    if (ctx.environ.get("PANCAKE_RENDEZVOUS")) |url| {
        ctx.rendezvous_resident = pancake.net.keyed_relay.Resident.init(ctx.io, url) catch {
            ctx.logErr("PANCAKE_RENDEZVOUS is not a ws://host:port/path relay URL: {s}", .{url});
            return error.InvalidRendezvousUrl;
        };
        ctx.dial_netlayers[1] = ctx.rendezvous_resident.netlayer();
        netlayer_count = 2;
    }
    const identity = try ctx.dialIdentity();
    return driver.connectUriOwned(ctx.gpa, ctx.dial_netlayers[0..netlayer_count], uri, identity, opts) catch |err| {
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
/// I/O). Named targets need a bootstrap fetch first (`beginFetch` / `fetch`);
/// this helper does not start one.
pub fn parseImportTarget(name_or_import: []const u8) !?u64 {
    if (name_or_import.len >= 2 and name_or_import[0] == '#') {
        return std.fmt.parseInt(u64, name_or_import[1..], 10) catch return error.Usage;
    }
    return null;
}

/// `#N` → re-scope the raw capability id to this session's host (a stale or
/// foreign id fails closed at the call); otherwise bootstrap-fetch by
/// published name.
pub fn resolveTarget(session: *driver.Session, name_or_import: []const u8) !driver.Capability {
    if (try parseImportTarget(name_or_import)) |raw| return session.host.core.capabilityFromRaw(raw);
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
        if (retainSessionAfterDial(ctx) and ctx.session == null) {
            ctx.session = s;
            return .{ .{ .borrow = s }, 1 };
        }
        return .{ .{ .owned = s }, 1 };
    }
    const held = ctx.session orelse return error.Usage;
    if (pos.len < min_after_uri) return error.Usage;
    return .{ .{ .borrow = held }, 0 };
}

/// Which netlayer a `listen` binds, from its flags. Two ways to be reachable:
/// the default binds a TCP socket and signs its address, while `--rendezvous`
/// registers this identity at a relay and holds an inbound socket there
/// (ADR-0088) — how a peer behind a NAT, or one that declines to listen at
/// all, still gets dialed.
///
/// The caller supplies both residents' storage because each must outlive the
/// server that borrows its netlayer, and the two fronts keep them in
/// different places: argv on its own frame, the background listener in the
/// handle its thread owns. The policy lives here either way.
///
/// `register_url` is borrowed for the listener's whole life, not just this
/// call: `RelayUrl` holds subslices of it, and the resident re-reads them on
/// every re-registration. Argv passes its `Parsed` flag, which outlives the
/// accept loop; a front whose flags die with the request duplicates the bytes
/// first. The dial override comes from the environment, which lives as long
/// as the process.
pub fn listenNetlayer(
    ctx: *Ctx,
    register_url_opt: ?[]const u8,
    tcp: *pancake.net.tcp.Resident,
    relay: *pancake.net.keyed_relay.Resident,
) !pancake.net.netlayer.Netlayer {
    tcp.* = .{ .io = ctx.io };
    const register_url = register_url_opt orelse return tcp.netlayer();
    const register = pancake.net.keyed_relay.RelayUrl.parse(register_url) catch {
        ctx.logErr("--rendezvous wants a ws://host:port/path relay URL, got {s}", .{register_url});
        return error.Usage;
    };
    // The dial half is the deployment's own mapping. A listener that also
    // dials keyed-relay peers names it with PANCAKE_RENDEZVOUS; with none
    // set, this host registers but never dials one, so the register endpoint
    // stands in and no dial can reach it.
    const dial_url = ctx.environ.get("PANCAKE_RENDEZVOUS") orelse register_url;
    const dial = pancake.net.keyed_relay.RelayUrl.parse(dial_url) catch {
        ctx.logErr("PANCAKE_RENDEZVOUS is not a ws://host:port/path relay URL: {s}", .{dial_url});
        return error.Usage;
    };
    relay.* = .{
        .io = ctx.io,
        .relay_url = dial,
        .register_url = register,
        .public_key = (try ctx.ensureSecret()).publicKey(),
    };
    return relay.netlayer();
}

pub fn cmdListen(ctx: *Ctx, parsed: *Parsed) !u8 {
    // An accept loop would starve the MCP stdio (or REPL prompt) loop, so the
    // non-argv fronts listen in the background: bind and answer now, accept
    // and serve on the listener's own thread.
    if (ctx.front != .argv) {
        return @import("listen_background.zig").start(ctx, parsed);
    }
    const bind = parsed.flagString("bind") orelse "127.0.0.1:0";
    const publish_name = parsed.flagString("publish");
    const once = parsed.flagBool("once");
    const accept_id = try ctx.acceptIdentity();

    var tcp = pancake.net.tcp.Resident{ .io = ctx.io };
    var relay: pancake.net.keyed_relay.Resident = undefined;
    // Argv's `Parsed` outlives the accept loop below, so its flag bytes are
    // already durable enough for the borrows `RelayUrl` keeps.
    const netlayer = try listenNetlayer(ctx, parsed.flagString("rendezvous"), &tcp, &relay);

    var server = driver.listen(ctx.gpa, netlayer, .{ .designator = bind }, accept_id, sessionOpts()) catch |err| {
        ctx.logErr("listen: {s}", .{@errorName(err)});
        return exit_codes.dial;
    };
    defer server.close() catch {};

    var addr_buf: [128]u8 = undefined;
    const designator = server.localDesignator(&addr_buf) catch {
        ctx.logErr("listen: no dialable local designator", .{});
        return exit_codes.internal;
    };

    const uri = try model.uri.writePeer(ctx.gpa, .{
        .transport = server.listener.transportName(),
        .designator = designator,
        .hints = model.Hints.emptyFalse(),
    });
    defer ctx.gpa.free(uri);
    const locator_copy = try ctx.gpa.dupe(u8, uri);
    if (ctx.last_locator) |old| ctx.gpa.free(old);
    ctx.last_locator = locator_copy;

    if (ctx.json == .json) {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(ctx.gpa);
        try out.appendSlice(ctx.gpa, "{\"ok\":true,\"locator\":");
        try argv.writeJsonString(&out, ctx.gpa, uri);
        try out.appendSlice(ctx.gpa, "}\n");
        try ctx.writeResult(out.items);
    } else {
        try printOut(ctx, "{s}\n", .{uri});
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

    while (!signals.stopRequested()) {
        const ready = server.waitAcceptable(signals.poll_ms) catch |err| {
            if (signals.stopRequested()) return exit_codes.ok;
            ctx.logErr("listen wait: {s}", .{@errorName(err)});
            return exit_codes.internal;
        };
        if (!ready) continue;
        if (signals.stopRequested()) return exit_codes.ok;
        var conn = server.accept() catch |err| {
            if (signals.stopRequested()) return exit_codes.ok;
            ctx.logErr("listen accept: {s}", .{@errorName(err)});
            return exit_codes.internal;
        };
        defer conn.deinit();
        if (publish_name) |name| {
            publishBuiltin(conn, name) catch |err| switch (err) {
                error.UnknownBuiltin => {
                    ctx.logErr("unknown --publish {s} (want greeter or echo)", .{name});
                    return exit_codes.usage;
                },
                else => return err,
            };
            ctx.logInfo("published {s}", .{name});
        }
        try serveUntilStop(conn);
        if (signals.stopRequested()) return exit_codes.ok;
        if (once or publish_name != null) break;
    }
    return exit_codes.ok;
}

/// Serve until the partner leaves or SIGINT/SIGTERM sets the stop latch.
/// `Session.serve` parks in an unbounded read; chunked `stepReadable` lets the
/// latch end a published peer without closing the socket from another thread.
fn serveUntilStop(conn: *driver.Session) !void {
    while (!signals.stopRequested()) {
        const progress = conn.stepReadable(signals.poll_ms) catch |err| switch (err) {
            error.ConnectionLost, error.TruncatedFrame => return,
            else => return err,
        };
        if (progress) |p| if (p == .closed) return;
    }
}

pub fn cmdDial(ctx: *Ctx, parsed: *Parsed) !u8 {
    const want_repl = parsed.flagBool("repl");
    if (want_repl and ctx.front == .mcp) {
        ctx.logErr("dial --repl is argv-only (use `pancake repl` or `pancake ocapn dial --repl`)", .{});
        return exit_codes.usage;
    }
    const pos = parsed.positionals;
    if (pos.len == 0) {
        ctx.logErr("dial needs an ocapn:// locator", .{});
        return exit_codes.usage;
    }
    const target = pos[0];
    const session = dialUri(ctx, target) catch |err| return mapDialErr(err);
    ctx.closeSession();
    ctx.session = session;
    if (ctx.json == .json) {
        try ctx.writeResult("{\"ok\":true,\"dialed\":true}\n");
    } else {
        ctx.logInfo("dialed {s}", .{target});
    }
    if (want_repl) {
        ctx.front = .repl;
        return @import("../repl/mod.zig").runAttached(ctx);
    }
    if (!retainSessionAfterDial(ctx)) ctx.closeSession();
    return exit_codes.ok;
}

/// Whether `cmdDial` should keep `ctx.session` open after a successful dial.
/// REPL and MCP fronts need it; bare argv dial does not.
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
    defer session.deinit();
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
    defer ref.deinit();
    const name_i = resolved[1];
    const target_tok = pos[name_i];
    const verb = pos[name_i + 1];
    const call_args = try parseArgsList(ctx.gpa, pos[name_i + 2 ..]);
    defer ctx.gpa.free(call_args);

    const session = ref.ptr();
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
    defer ref.deinit();
    const name_i = resolved[1];
    const call_args = try parseArgsList(ctx.gpa, pos[name_i + 2 ..]);
    defer ctx.gpa.free(call_args);
    const session = ref.ptr();
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
/// opaque capability id (never a wire position, ADR-0096); `#N` feeds it back
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
    defer ref.deinit();
    const name_i = resolved[1];
    const name = pos[name_i];
    const session = ref.ptr();
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
    const session = ctx.session orelse {
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
    ctx.closeSession();
    ctx.closeBackgroundListener();
    if (ctx.json == .json) try ctx.writeResult("{\"ok\":true}\n");
    return exit_codes.ok;
}

pub fn cmdInfo(ctx: *Ctx, parsed: *Parsed) !u8 {
    _ = parsed;
    const secret = ctx.ensureSecret() catch |err|
        return @import("../operability/identity.zig").refuseSecret(ctx.io, err, ctx.identity_path);
    const designator = secret.publicKey().toDesignator();
    const abort = if (ctx.session) |s| s.partnerAbort() else null;
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
        try out.print(ctx.gpa, ",\"session\":{s}", .{if (ctx.session != null) "true" else "false"});
        try out.appendSlice(ctx.gpa, ",\"front\":");
        try argv.writeJsonString(&out, ctx.gpa, front);
        if (ctx.identity_path.len > 0) {
            try out.appendSlice(ctx.gpa, ",\"path\":");
            try argv.writeJsonString(&out, ctx.gpa, ctx.identity_path);
        }
        if (ctx.last_locator) |loc| {
            try out.appendSlice(ctx.gpa, ",\"locator\":");
            try argv.writeJsonString(&out, ctx.gpa, loc);
        }
        if (ctx.background_listener) |listener| {
            // A listener that stopped accepting — a fault, or a one-partner
            // listener that served its partner — reports why rather than
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
        try printOut(ctx, "session:  {s}\n", .{if (ctx.session != null) "open" else "none"});
        try printOut(ctx, "front:    {s}\n", .{front});
        if (ctx.last_locator) |loc| try printOut(ctx, "locator:  {s}\n", .{loc});
        if (abort) |info| {
            try printOut(ctx, "abort:    {s}: {s}\n", .{ info.kind.wireName(), info.message });
        }
        if (ctx.identity_path.len > 0) try printOut(ctx, "path:     {s}\n", .{ctx.identity_path});
    }
    return exit_codes.ok;
}

pub fn cmdLocator(ctx: *Ctx, parsed: *Parsed) !u8 {
    _ = parsed;
    const loc = ctx.last_locator orelse {
        ctx.logErr("no listen locator in this process", .{});
        return exit_codes.usage;
    };
    try printOut(ctx, "{s}\n", .{loc});
    return exit_codes.ok;
}
