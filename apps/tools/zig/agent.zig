//! An agent, written on glowcap actors in native Zig, on the connection driver.
//! It connects to the tools coordinator (which may be written in any language)
//! and proves the three capability properties (delegation, attenuation, and
//! revocation) over the wire.
//!
//!   glowcap-tools-agent <port> <nick>
//!
//! One owning `driver.connect` is the whole setup. Each request is one
//! `session.call`, which blocks until the reply settles and returns the outcome
//! as a `driver.Settled` materialized into the agent's arena. Allocation,
//! ownership, and I/O stay visible without a callback in sight.

const std = @import("std");
const glowcap = @import("glowcap");

const demo_check = @import("demo_tools_check");
const demo_usage = @import("demo_usage");

const actors = glowcap.actors;
const driver = glowcap.driver;
const tcp = glowcap.net.tcp;

const host = "127.0.0.1";
const frame_cap: usize = 1 << 16;

/// True when the call fulfilled with an integer, the shape a clock answers.
fn fulfilledInteger(settled: driver.Reply) bool {
    return settled == .fulfilled and settled.fulfilled == .integer;
}

/// True when the call fulfilled with a string, the shape a file read answers.
fn fulfilledString(settled: driver.Reply) bool {
    return settled == .fulfilled and settled.fulfilled == .string;
}

/// Grant a tool and return its capability, or fail if the grant did not
/// return one.
fn grant(session: *driver.Session, tools: driver.Capability, verb: []const u8, which: []const u8, arena: std.mem.Allocator) !driver.Capability {
    const settled = try session.call(tools, verb, &.{.{ .string = which }}, arena);
    return switch (settled) {
        .fulfilled => |arg| switch (arg) {
            .capability => |cap| cap,
            else => error.NotACapability,
        },
        .broken => error.NotACapability,
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

    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const address = try tcp.parseHostPort(host, port);
    const loc = tcp.locatorFromAddress(&designator_buf, address);
    var session = try driver.connect(allocator, io, .{ .symbols = &.{.tcp} }, loc, .ephemeral, .{ .frame_cap = frame_cap, .handshake = .{ .ms = 10_000 }, .settle = .{ .ms = 10_000 } });
    defer session.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tools = try session.fetch("tools");
    var ok = true;

    const clock = try grant(session, tools, "grant", "clock", arena);
    const now = try session.call(clock, "now", &.{}, arena);
    ok = demo_check.check(nick, "delegation: was handed a clock and called it", fulfilledInteger(now)) and ok;

    const files = try grant(session, tools, "grant", "files-readonly", arena);
    const read = try session.call(files, "read", &.{.{ .string = "report.txt" }}, arena);
    ok = demo_check.check(nick, "attenuation: read through the read-only view", fulfilledString(read)) and ok;
    const write = try session.call(files, "write", &.{ .{ .string = "report.txt" }, .{ .string = "tampered" } }, arena);
    ok = demo_check.check(nick, "attenuation: write is refused", write == .broken) and ok;

    const revocable = try grant(session, tools, "grant-revocable", "clock", arena);
    const before = try session.call(revocable, "now", &.{}, arena);
    ok = demo_check.check(nick, "revocation: the handle works before revoke", fulfilledInteger(before)) and ok;
    _ = try session.call(tools, "revoke-last", &.{}, arena);
    const after = try session.call(revocable, "now", &.{}, arena);
    ok = demo_check.check(nick, "revocation: the handle breaks after revoke", after == .broken) and ok;

    if (ok) {
        std.debug.print("{s}: all capability properties held\n", .{nick});
    } else {
        std.process.exit(1);
    }
}

fn fail(message: []const u8) error{Usage} {
    return demo_usage.usage("usage: glowcap-tools-agent <port> <nick>", message);
}
