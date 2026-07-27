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
    var session = try server.accept();
    defer session.deinit();
    _ = try session.publish("greeter", Greeter, .{});
    try session.serve();
}

/// The client half, the README's Quick Start snippet, verbatim.
fn client(io: std.Io, allocator: std.mem.Allocator, designator: []const u8) !void {
    // tcp: the peer is a place. Its name, a cleartext `host:port`, is called the
    // "designator", and `tcp.at` wraps that name as a dialable locator. The slice
    // names the transports this client can reach.
    var tcp_resident = pancake.net.tcp.Resident{ .io = io };
    const partner = pancake.net.tcp.at(designator);

    const session = try pancake.driver.connect(
        allocator,
        &.{tcp_resident.netlayer()},
        partner,
        .ephemeral,
        // Both budgets default to 0, which means "wait forever". A silent or
        // unreachable peer would park this program with no way out, so a
        // client always passes finite ones.
        .{ .handshake_timeout_ms = 10_000, .settle_timeout_ms = 10_000 },
    );
    defer session.deinit();

    const greeter = try session.fetch("greeter"); // a capability, by name
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const settled = try session.call(greeter, .{
        .verb = "greet",
        .args = &.{.{ .string = "world" }},
    }, arena.allocator());
    switch (settled) {
        .fulfilled => |arg| std.debug.print("{s}\n", .{arg.string}),
        .broken => |reason| std.debug.print("the greeter refused: {s}\n", .{reason}),
        // The third outcome: an introduction to a capability on another peer.
        // A Host presents it there and hands you the live result. This greeter never sends one.
        .give => {},
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tcp_resident = pancake.net.tcp.Resident{ .io = io };
    var server = try driver.listen(allocator, tcp_resident.netlayer(), .{ .designator = "127.0.0.1:0" }, .ephemeral, .{
        .handshake_timeout_ms = 10_000,
        .settle_timeout_ms = 10_000,
    });
    defer server.close();

    var addr_buf: [64]u8 = undefined;
    // `try`: a bound listener that cannot report a dialable designator is a
    // defect, and signing an empty one publishes an address nobody can dial.
    const designator = try server.localDesignator(&addr_buf);

    var hosting = try io.concurrent(host, .{&server});
    try client(io, allocator, designator);
    try hosting.await(io);
}
