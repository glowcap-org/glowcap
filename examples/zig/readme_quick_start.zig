//! The README's Quick Start snippet, runnable.
//!
//! The `client` function below is the exact code the README shows under
//! Quick Start, so the snippet stays machine-checked; if either side changes,
//! change both in the same diff. The host half is the minimum the snippet
//! needs to run: a greeter published by name that answers `greet` with a
//! greeting, the same greeter chapter 01 hosts.
//!
//! Run: `zig build examples` (it also runs under `zig build check`).

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const actors = pancake.actors;
const driver = pancake.driver;

/// The published greeter: answers `greet(name)` with a greeting built in the
/// turn's arena, which outlives the reply encode and nothing more.
const Greeter = struct {
    pub fn handle(self: *Greeter, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        if (!std.mem.eql(u8, msg.verb, "greet")) return error.NoSuchMethod;
        if (msg.args.len != 1 or msg.args[0] != .string) return error.BadInvocation;
        return .{ .string = try std.fmt.allocPrint(turn.arena, "Hello, {s}", .{msg.args[0].string}) };
    }
};

/// The hosting half: accept one partner (the keyed handshake completes inside
/// `accept`), publish the greeter by name, and serve until the partner leaves.
fn host(server: *driver.Server) !void {
    var conn = try server.accept();
    defer conn.close();
    _ = try conn.publish("greeter", Greeter, .{});
    try conn.serve();
}

/// The client half — the README's Quick Start snippet, verbatim.
fn client(io: std.Io, allocator: std.mem.Allocator, address: std.Io.net.IpAddress) !void {
    const conn = try pancake.driver.connect(io, allocator, address, .{});
    defer conn.close();

    const greeter = try conn.fetch("greeter"); // a capability, by name
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const settled = try conn.call(greeter, .{
        .verb = "greet",
        .args = &.{.{ .string = "world" }},
    }, arena.allocator());
    switch (settled) {
        .fulfilled => |arg| std.debug.print("{s}\n", .{arg.string}),
        .broken => |reason| std.debug.print("the greeter refused: {s}\n", .{reason}),
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server = try driver.listen(io, allocator, .{ .ip4 = std.Io.net.Ip4Address.loopback(0) }, .{});
    defer server.close();

    // The host serves on a concurrent fiber; the client drives this one.
    var hosting = try io.concurrent(host, .{&server});
    try client(io, allocator, server.localAddress());
    try hosting.await(io);
}
