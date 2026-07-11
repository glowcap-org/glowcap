//! An agent, written on pancake actors in native Zig, on the connection driver.
//! It connects to the tools coordinator (which may be written in any language)
//! and proves the three capability properties — delegation, attenuation,
//! revocation — over the wire.
//!
//!   pancake-tools-agent <port> <nick>
//!
//! One owning `driver.connect` is the whole setup. Each request is one
//! `conn.call`, which blocks until the reply settles and returns the outcome
//! as a `driver.Settled` materialized into the agent's arena — allocation,
//! ownership, and I/O stay visible without a callback in sight.

const std = @import("std");
const pancake = @import("pancake");

const demo_check = @import("demo_tools_check");
const demo_usage = @import("demo_usage");

const actors = pancake.actors;
const driver = pancake.driver;
const tcp = pancake.net.tcp;

const host = "127.0.0.1";
const frame_cap: usize = 1 << 16;

/// True when the call fulfilled with an integer, the shape a clock answers.
fn fulfilledInteger(settled: driver.Settled) bool {
    return settled == .fulfilled and settled.fulfilled == .integer;
}

/// True when the call fulfilled with a string, the shape a file read answers.
fn fulfilledString(settled: driver.Settled) bool {
    return settled == .fulfilled and settled.fulfilled == .string;
}

/// Grant a tool and return a far reference to it, or fail if the grant did not
/// return a capability.
fn grant(conn: *driver.Connection, tools: actors.Ref, verb: []const u8, which: []const u8, arena: std.mem.Allocator) !actors.Ref {
    const settled = try conn.call(tools, .{ .verb = verb, .args = &.{.{ .string = which }} }, arena);
    return switch (settled) {
        .fulfilled => |arg| switch (arg) {
            .reference => |reference| switch (reference) {
                .far => |far_ref| .{ .far = far_ref },
                else => error.NotACapability,
            },
            else => error.NotACapability,
        },
        .broken, .give => error.NotACapability,
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

    var tcp_resident = tcp.Resident{ .io = io };
    var designator_buf: [64]u8 = undefined;
    const designator = try std.fmt.bufPrint(&designator_buf, "{s}:{d}", .{ host, port });
    var conn = try driver.connect(allocator, &.{tcp_resident.netlayer()}, tcp.at(designator), .ephemeral, .{ .frame_cap = frame_cap });
    defer conn.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tools = try conn.fetch("tools");
    var ok = true;

    const clock = try grant(conn, tools, "grant", "clock", arena);
    const now = try conn.call(clock, .{ .verb = "now", .args = &.{} }, arena);
    ok = demo_check.check(nick, "delegation: was handed a clock and called it", fulfilledInteger(now)) and ok;

    const files = try grant(conn, tools, "grant", "files-readonly", arena);
    const read = try conn.call(files, .{ .verb = "read", .args = &.{.{ .string = "report.txt" }} }, arena);
    ok = demo_check.check(nick, "attenuation: read through the read-only view", fulfilledString(read)) and ok;
    const write = try conn.call(files, .{ .verb = "write", .args = &.{ .{ .string = "report.txt" }, .{ .string = "tampered" } } }, arena);
    ok = demo_check.check(nick, "attenuation: write is refused", write == .broken) and ok;

    const revocable = try grant(conn, tools, "grant-revocable", "clock", arena);
    const before = try conn.call(revocable, .{ .verb = "now", .args = &.{} }, arena);
    ok = demo_check.check(nick, "revocation: the handle works before revoke", fulfilledInteger(before)) and ok;
    _ = try conn.call(tools, .{ .verb = "revoke-last", .args = &.{} }, arena);
    const after = try conn.call(revocable, .{ .verb = "now", .args = &.{} }, arena);
    ok = demo_check.check(nick, "revocation: the handle breaks after revoke", after == .broken) and ok;

    if (ok) {
        std.debug.print("{s}: all capability properties held\n", .{nick});
    } else {
        std.process.exit(1);
    }
}

fn fail(message: []const u8) error{Usage} {
    return demo_usage.usage("usage: pancake-tools-agent <port> <nick>", message);
}
