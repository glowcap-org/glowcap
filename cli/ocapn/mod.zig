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

/// Built-in actors for `--publish` / `ocapn publish`. Names match the Zig
/// examples (`greeter`) and the identity-echo helper (`echo`).
const Greeter = struct {
    pub fn handle(self: *Greeter, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        if (msg.args.len != 1 or msg.args[0] != .string) return error.BadInvocation;
        const who = msg.args[0].string;
        if (std.mem.eql(u8, msg.verb, "greet")) {
            return .{ .string = try std.fmt.allocPrint(turn.arena, "Hello, {s}", .{who}) };
        }
        if (std.mem.eql(u8, msg.verb, "cowsay")) {
            return .{ .string = try formatCowsay(turn.arena, who) };
        }
        if (std.mem.eql(u8, msg.verb, "pancakesay")) {
            return .{ .string = try formatPancakesay(turn.arena, who) };
        }
        if (std.mem.eql(u8, msg.verb, "goblinsay")) {
            return .{ .string = try formatGoblinsay(turn.arena, who) };
        }
        return error.NoSuchMethod;
    }
};

/// Classic one-line cowsay balloon (CLI demo only — not a system cowsay).
fn formatCowsay(arena: std.mem.Allocator, msg: []const u8) ![]const u8 {
    return try formatSay(arena, msg,
        \\
        \\        \   ^__^
        \\         \  (oo)\_______
        \\            (__)\       )\/\
        \\                ||----w |
        \\                ||     ||
    );
}

/// Stack-of-pancakes speech balloon (CLI demo — the product's own joke).
/// Middle cake wears a little face.
fn formatPancakesay(arena: std.mem.Allocator, msg: []const u8) ![]const u8 {
    return try formatSay(arena, msg,
        \\
        \\       \
        \\        \    .------.
        \\         \  (_|___|__)
        \\            (_|^_^|__)
        \\            (_____|__)
        \\             ~~syrup~~
    );
}

/// Friendly goblin speech balloon (CLI demo doodle — not Spritely's mascot art).
/// Trailing spaces after `\` keep Zig from treating `\` as a line continue.
fn formatGoblinsay(arena: std.mem.Allocator, msg: []const u8) ![]const u8 {
    return try formatSay(arena, msg,
        \\
        \\       \
        \\        \      ,^,
        \\         \   ( o.o )
        \\             \  =  /
        \\            /|     |\ 
        \\             U     U
    );
}

fn formatSay(arena: std.mem.Allocator, msg: []const u8, figure: []const u8) ![]const u8 {
    const w = msg.len;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    try out.append(arena, ' ');
    try out.appendNTimes(arena, '_', w + 2);
    try out.append(arena, '\n');
    try out.print(arena, "< {s} >\n", .{msg});
    try out.append(arena, ' ');
    try out.appendNTimes(arena, '-', w + 2);
    try out.appendSlice(arena, figure);
    return try out.toOwnedSlice(arena);
}

const Echo = struct {
    pub fn handle(self: *Echo, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "echo")) return error.NoSuchMethod;
        if (msg.args.len != 1) return error.BadInvocation;
        return msg.args[0];
    }
};

/// Publish a named built-in on `session` (`greeter` or `echo`).
pub fn publishBuiltin(session: anytype, name: []const u8) !void {
    if (std.mem.eql(u8, name, "greeter")) {
        _ = try session.publish(name, Greeter, .{});
    } else if (std.mem.eql(u8, name, "echo")) {
        _ = try session.publish(name, Echo, .{});
    } else {
        return error.UnknownBuiltin;
    }
}

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
        else => exit_codes.dial,
    };
}

/// CapTP act failures (call/tell/fetch): settle/handshake timeouts are exit 6.
pub fn mapActErr(err: anyerror) u8 {
    return switch (err) {
        error.HandshakeTimedOut, error.WaitTimedOut => exit_codes.timeout,
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
        .handshake_timeout_ms = default_handshake_timeout_ms,
        .settle_timeout_ms = default_settle_timeout_ms,
    };
}

/// Dial with explicit session options (tests pass a short handshake budget).
pub fn dialUriWithOpts(ctx: *Ctx, uri: []const u8, opts: driver.SessionOptions) !*driver.Session {
    var tcp = pancake.net.tcp.Resident{ .io = ctx.io };
    const netlayers = [_]pancake.net.netlayer.Netlayer{tcp.netlayer()};
    const identity = try ctx.dialIdentity();
    return driver.connectUriOwned(ctx.gpa, &netlayers, uri, identity, opts) catch |err| {
        ctx.logErr("dial failed: {s}", .{@errorName(err)});
        return err;
    };
}

fn dialUri(ctx: *Ctx, uri: []const u8) !*driver.Session {
    return dialUriWithOpts(ctx, uri, sessionOpts());
}

pub fn printSettled(ctx: *Ctx, settled: driver.Settled) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(ctx.gpa);
    switch (ctx.json) {
        .json => switch (settled) {
            .fulfilled => |arg| try appendArgJson(&out, ctx.gpa, arg),
            .broken => |reason| {
                try out.appendSlice(ctx.gpa, "{\"ok\":false,\"broken\":");
                try argv.writeJsonString(&out, ctx.gpa, reason);
                try out.appendSlice(ctx.gpa, "}\n");
            },
            .give => try out.appendSlice(ctx.gpa, "{\"ok\":true,\"give\":true}\n"),
        },
        .human => switch (settled) {
            .fulfilled => |arg| try appendArgHuman(&out, ctx.gpa, arg),
            .broken => |reason| try out.print(ctx.gpa, "broken: {s}\n", .{reason}),
            .give => try out.appendSlice(ctx.gpa, "give\n"),
        },
    }
    try ctx.writeResult(out.items);
}

fn appendArgHuman(out: *std.ArrayList(u8), gpa: std.mem.Allocator, arg: model.Argument) !void {
    switch (arg) {
        .string => |s| try out.print(gpa, "{s}\n", .{s}),
        .integer => |n| try out.print(gpa, "{d}\n", .{n}),
        .boolean => |b| try out.print(gpa, "{s}\n", .{if (b) "true" else "false"}),
        .void => try out.appendSlice(gpa, "void\n"),
        else => try out.print(gpa, "{s}\n", .{@tagName(arg)}),
    }
}

fn appendArgJson(out: *std.ArrayList(u8), gpa: std.mem.Allocator, arg: model.Argument) !void {
    switch (arg) {
        .string => |s| {
            try out.appendSlice(gpa, "{\"ok\":true,\"value\":");
            try argv.writeJsonString(out, gpa, s);
            try out.appendSlice(gpa, "}\n");
        },
        .integer => |n| try out.print(gpa, "{{\"ok\":true,\"value\":{d}}}\n", .{n}),
        .boolean => |b| try out.print(gpa, "{{\"ok\":true,\"value\":{s}}}\n", .{if (b) "true" else "false"}),
        .void => try out.appendSlice(gpa, "{\"ok\":true,\"value\":null}\n"),
        else => try out.print(gpa, "{{\"ok\":true,\"value_kind\":\"{s}\"}}\n", .{@tagName(arg)}),
    }
}

pub fn parseArgsList(gpa: std.mem.Allocator, raw: []const []const u8) ![]model.Argument {
    var list: std.ArrayList(model.Argument) = .empty;
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

/// `#N` → far import at wire position N (no I/O). Named targets need a bootstrap
/// fetch first (`beginFetch` / `fetch`); this helper does not start one.
pub fn parseImportTarget(name_or_import: []const u8) !?actors.Ref {
    if (name_or_import.len >= 2 and name_or_import[0] == '#') {
        const n = std.fmt.parseInt(u64, name_or_import[1..], 10) catch return error.Usage;
        return .{ .far = model.FarRef.object(n) };
    }
    return null;
}

/// `#N` → far import at wire position N; otherwise bootstrap-fetch by published name.
fn resolveTarget(session: *driver.Session, name_or_import: []const u8) !actors.Ref {
    if (try parseImportTarget(name_or_import)) |far| return far;
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

pub fn cmdListen(ctx: *Ctx, parsed: *Parsed) !u8 {
    // Accept loops starve MCP/REPL; registry marks listen mcp_never for tools/list.
    if (ctx.front != .argv) {
        ctx.logErr("listen is only available on the CLI argv front (blocking accept loop)", .{});
        return exit_codes.usage;
    }
    const bind = parsed.flagString("bind") orelse "127.0.0.1:0";
    const publish_name = parsed.flagString("publish");
    const once = parsed.flagBool("once");

    var tcp = pancake.net.tcp.Resident{ .io = ctx.io };
    const accept_id = try ctx.acceptIdentity();
    var server = try driver.listen(ctx.gpa, tcp.netlayer(), .{ .designator = bind }, accept_id, sessionOpts());

    var addr_buf: [128]u8 = undefined;
    const designator = server.localDesignator(&addr_buf);
    if (designator.len == 0) {
        server.close();
        ctx.logErr("listen: empty local designator", .{});
        return exit_codes.internal;
    }

    const uri = try model.uri.writePeer(ctx.gpa, .{
        .transport = "tcp",
        .designator = designator,
        .hints = model.Hints.emptyFalse(),
    });
    defer ctx.gpa.free(uri);
    if (ctx.last_locator) |old| ctx.gpa.free(old);
    ctx.last_locator = try ctx.gpa.dupe(u8, uri);

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

    defer server.close();

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
        const ready = server.waitAcceptable(signals.poll_ms) catch {
            if (signals.stopRequested()) return exit_codes.ok;
            return exit_codes.internal;
        };
        if (!ready) continue;
        if (signals.stopRequested()) return exit_codes.ok;
        var conn = server.accept() catch {
            if (signals.stopRequested()) return exit_codes.ok;
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
            ctx.logErr("call target must be a published name or #<import>", .{});
            return exit_codes.usage;
        },
        else => return failCapTp(ctx, session, err, "fetch"),
    };
    var arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena.deinit();
    const settled = session.call(target, .{ .verb = verb, .args = call_args }, arena.allocator()) catch |err| {
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
            ctx.logErr("tell target must be a published name or #<import>", .{});
            return exit_codes.usage;
        },
        else => return failCapTp(ctx, session, err, "fetch"),
    };
    session.tell(target, .{ .verb = pos[name_i + 1], .args = call_args }) catch |err| {
        return failCapTp(ctx, session, err, "tell");
    };
    if (ctx.json == .json) try ctx.writeResult("{\"ok\":true}\n");
    return exit_codes.ok;
}

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
    // Bootstrap fetch always yields a far import (see Session.fetchReference).
    const import_pos: u64 = switch (target) {
        .far => |far| far.import_position.int(),
        .local => return failCapTp(ctx, session, driver.Error.FetchNotACapability, "fetch"),
    };
    if (ctx.json == .json) {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(ctx.gpa);
        try out.appendSlice(ctx.gpa, "{\"ok\":true,\"name\":");
        try argv.writeJsonString(&out, ctx.gpa, name);
        try out.print(ctx.gpa, ",\"import\":{d}}}\n", .{import_pos});
        try ctx.writeResult(out.items);
    } else {
        try printOut(ctx, "fetched {s} → import {d}\n", .{ name, import_pos });
        try printOut(ctx, "next: call {s} <verb> [args…]   or   call #{d} <verb> [args…]\n", .{ name, import_pos });
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
    if (ctx.json == .json) try ctx.writeResult("{\"ok\":true}\n");
    return exit_codes.ok;
}

pub fn cmdInfo(ctx: *Ctx, parsed: *Parsed) !u8 {
    _ = parsed;
    const secret = ctx.ensureSecret() catch |err| return mapDialErr(err);
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
