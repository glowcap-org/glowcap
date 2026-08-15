//! 01 — Connect, listen, fetch, call, and serve over TCP.
//!
//! One process hosts a greeter; another dials it, fetches that greeter by the
//! name the host published, and calls `greet`. Both sides use `driver.Session`
//! over a real TCP socket. There is no export-position bookkeeping and no
//! hand-rolled receive loop.
//!
//! This is the application surface. Chapter 02 adds a third peer and a
//! three-party introduction. Later chapters open the layers underneath.
//! The buffer-explicit form of this same surface is
//! `connect_explicit_buffers.zig`.
//!
//! Run: `zig build examples` (it also runs under `zig build check`).

const std = @import("std");
const pancake = @import("pancake");

const driver = pancake.driver;

/// The published actor: answers `greet(name)` with a greeting built in the
/// turn's arena, which outlives the reply encode and nothing more.
const Greeter = struct {
    pub fn handle(_: *Greeter, ht: *driver.HostTurn, verb: []const u8, args: []const driver.Value) !driver.Value {
        if (!std.mem.eql(u8, verb, "greet")) return error.NoSuchMethod;
        if (args.len != 1 or args[0] != .string) return error.BadInvocation;
        return .{ .string = try std.fmt.allocPrint(ht.turn.arena, "Hello, {s}", .{args[0].string}) };
    }
};

/// The hosting half: publish the greeter on the server before accept, so a
/// partner that fetches as soon as the session opens cannot miss it. Then
/// accept (the keyed handshake completes inside) and serve until they leave.
fn host(server: *driver.Server) !void {
    try server.publishGiftable("greeter", Greeter, .{});
    var session = try server.accept();
    defer session.deinit();
    try session.serve();
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tcp_resident = pancake.net.tcp.Resident{ .io = io };
    const netlayers = [_]pancake.net.netlayer.Netlayer{tcp_resident.netlayer()};
    // Listen on a designator, the peer's name on its transport: for tcp a
    // `host:port`, with port 0 letting the OS pick one.
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

    {
        // `pancake.Session` is the front-door alias for the owning
        // `driver.Session` this call hands back.
        // Finite budgets, named on purpose: the compiler requires a choice here,
        // and writing `.unbounded` would park this program with no way out
        // against a peer that never answers.
        var session: *pancake.Session = try driver.connect(
            allocator,
            &netlayers,
            pancake.net.tcp.locator(designator),
            .ephemeral,
            .{
                .handshake = .{ .ms = 10_000 },
                .settle = .{ .ms = 10_000 },
            },
        );
        defer session.deinit();
        const greeter = try session.fetch("greeter");

        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const settled = try session.call(greeter, "greet", &.{.{ .string = "world" }}, arena_state.allocator());

        const ok = switch (settled) {
            .fulfilled => |value| value == .string and std.mem.eql(u8, value.string, "Hello, world"),
            .broken => false,
        };
        if (!ok) return error.UnexpectedReply;
    }

    try hosting.await(io);
    std.debug.print("01: greeter fetched by name and called over an OCapN session on the `tcp` netlayer\n", .{});
}
