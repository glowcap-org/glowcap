//! An agent, written on pancake actors in native Zig, on the connection driver.
//! It connects to the tools coordinator (which may be written in any language)
//! and proves the three capability properties — delegation, attenuation,
//! revocation — over the wire.
//!
//!   pancake-tools-agent <port> <nick>
//!
//! `callSync` is the request-response helper: send, then `step` the connection
//! until the reply settles, summarizing it as a `Settled`. Allocation, ownership,
//! and I/O stay visible — each `step` is one explicit pump.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.model;
const engine = pancake.engine;
const actors = pancake.actors;
const driver = pancake.driver;
const tcp = pancake.net_adapter.tcp;

const host = "127.0.0.1";
const frame_cap: usize = 1 << 16;

/// A summary of how a call settled — enough for the agent's checks, copied out of
/// the borrowed resolution inside the listener (a far ref and an integer are POD).
const Settled = union(enum) {
    integer: i64,
    string_ok,
    capability: model.FarRef,
    other,
    broken,
};

const CallState = struct {
    done: bool = false,
    settled: Settled = .other,
};

fn onCall(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const st: *CallState = @ptrCast(@alignCast(ctx.?));
    st.done = true;
    switch (resolution) {
        .fulfilled => |arg| switch (arg) {
            .integer => |n| st.settled = .{ .integer = n },
            .string => st.settled = .string_ok,
            .reference => |reference| switch (reference) {
                .far => |far_ref| st.settled = .{ .capability = far_ref },
                else => st.settled = .other,
            },
            else => st.settled = .other,
        },
        .broken => st.settled = .broken,
    }
}

/// Send `msg` to `target` and drive the connection until the reply settles.
fn callSync(conn: *driver.ConnectedVat, target: actors.Ref, msg: actors.Message) !Settled {
    var st = CallState{};
    const promise = try conn.send(target, msg);
    try conn.on(promise, .{ .ctx = &st, .func = onCall });
    var rounds: usize = 0;
    while (!st.done and rounds < 200) : (rounds += 1) {
        const progress = try conn.step();
        if (progress == .closed) return error.ConnectionClosed;
    }
    if (!st.done) return error.Timeout;
    return st.settled;
}

fn check(nick: []const u8, label: []const u8, passed: bool) bool {
    std.debug.print("{s}: {s} — {s}\n", .{ nick, if (passed) "ok" else "FAIL", label });
    return passed;
}

/// Grant a tool and return a far reference to it, or fail if the grant did not
/// return a capability.
fn grant(conn: *driver.ConnectedVat, tools: actors.Ref, verb: []const u8, which: []const u8) !actors.Ref {
    const settled = try callSync(conn, tools, .{ .verb = verb, .args = &.{.{ .string = which }} });
    return switch (settled) {
        .capability => |far_ref| .{ .far = far_ref },
        else => error.NotACapability,
    };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const port_str = args.next() orelse return fail("missing <port>");
    const nick = args.next() orelse return fail("missing <nick>");
    const port = try std.fmt.parseInt(u16, port_str, 10);

    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    const address = try tcp.parseHostPort(host, port);
    var conn = try driver.connectTcp(io, allocator, &peer, address, read_buf, write_buf);
    defer conn.deinit();

    const tools = try conn.fetch("tools");
    var ok = true;

    // 1. Delegation: get a clock capability and call it.
    const clock = try grant(&conn, tools, "grant", "clock");
    const now = try callSync(&conn, clock, .{ .verb = "now", .args = &.{} });
    ok = check(nick, "delegation: was handed a clock and called it", now == .integer) and ok;

    // 2. Attenuation: a read-only file capability reads but refuses writes.
    const files = try grant(&conn, tools, "grant", "files-readonly");
    const read = try callSync(&conn, files, .{ .verb = "read", .args = &.{.{ .string = "report.txt" }} });
    ok = check(nick, "attenuation: read through the read-only view", read == .string_ok) and ok;
    const write = try callSync(&conn, files, .{ .verb = "write", .args = &.{ .{ .string = "report.txt" }, .{ .string = "tampered" } } });
    ok = check(nick, "attenuation: write is refused", write == .broken) and ok;

    // 3. Revocation: a revocable handle works, then breaks after revoke.
    const revocable = try grant(&conn, tools, "grant-revocable", "clock");
    const before = try callSync(&conn, revocable, .{ .verb = "now", .args = &.{} });
    ok = check(nick, "revocation: the handle works before revoke", before == .integer) and ok;
    _ = try callSync(&conn, tools, .{ .verb = "revoke-last", .args = &.{} });
    const after = try callSync(&conn, revocable, .{ .verb = "now", .args = &.{} });
    ok = check(nick, "revocation: the handle breaks after revoke", after == .broken) and ok;

    if (ok) {
        std.debug.print("{s}: all capability properties held\n", .{nick});
    } else {
        std.process.exit(1);
    }
}

fn fail(message: []const u8) error{Usage} {
    std.debug.print("usage: pancake-tools-agent <port> <nick>\n  ({s})\n", .{message});
    return error.Usage;
}
