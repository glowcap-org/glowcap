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

const driver = pancake.driver;

/// The published greeter: answers `greet(name)` with a greeting built in the
/// turn's arena, which outlives the reply encode and nothing more.
const Greeter = struct {
    pub fn handle(_: *Greeter, ht: *driver.HostTurn, verb: []const u8, args: []const driver.Value) !driver.Value {
        if (!std.mem.eql(u8, verb, "greet")) return error.NoSuchMethod;
        if (args.len != 1 or args[0] != .string) return error.BadInvocation;
        return .{ .string = try std.fmt.allocPrint(ht.turn.arena, "Hello, {s}", .{args[0].string}) };
    }
};

/// The hosting half: publish the greeter on the server before accept, so a
/// partner that fetches as soon as the session opens cannot miss it.
fn host(server: *driver.Server) !void {
    try server.publishGiftable("greeter", Greeter, .{});
    var session = try server.accept();
    defer session.deinit();
    try session.serve();
}

/// The client half, the README's Quick Start snippet, verbatim.
fn client(io: std.Io, allocator: std.mem.Allocator, designator: []const u8) !void {
    // Plain TCP uses a cleartext `host:port` locator.
    var tcp_resident = pancake.net.tcp.Resident{ .io = io };
    const netlayers = [_]pancake.net.netlayer.Netlayer{tcp_resident.netlayer()};
    const partner = pancake.net.tcp.locator(designator);

    const session = try pancake.driver.connect(
        allocator,
        &netlayers,
        partner,
        .ephemeral,
        // Never leave a network wait unbounded.
        .{ .handshake = .{ .ms = 10_000 }, .settle = .{ .ms = 10_000 } },
    );
    defer session.deinit();

    const greeter = try session.fetch("greeter"); // a capability this peer published
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const settled = try session.call(greeter, "greet", &.{.{ .string = "world" }}, arena.allocator());
    switch (settled) {
        .fulfilled => |value| std.debug.print("{s}\n", .{value.string}),
        .broken => |reason| std.debug.print("the greeter refused: {s}\n", .{reason}),
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tcp_resident = pancake.net.tcp.Resident{ .io = io };
    var server = try driver.listen(allocator, tcp_resident.netlayer(), .{ .designator = "127.0.0.1:0" }, .ephemeral, .{
        .handshake = .{ .ms = 10_000 },
        .settle = .{ .ms = 10_000 },
    });
    defer server.deinit();

    var addr_buf: [64]u8 = undefined;
    // `try`: a bound listener that cannot report a dialable designator is a
    // defect, and signing an empty one publishes an address nobody can dial.
    const designator = try server.localDesignator(&addr_buf);

    var hosting = try io.concurrent(host, .{server});
    try client(io, allocator, designator);
    try hosting.await(io);
}
