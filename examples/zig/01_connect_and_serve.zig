//! 01: Connect, listen, fetch, call, and serve over encrypted TCP.
//!
//! One process hosts a greeter. Another dials it, fetches that greeter by the
//! name the host published, and calls `greet`. Both sides use `driver.Session`
//! over Noise-sealed TCP. The client dials the listener's key, so the channel
//! proves which peer answered. The Host owns protocol bookkeeping and I/O.
//!
//! This is the application surface. Chapter 02 adds a third peer and a
//! three-party introduction. Later chapters open the layers underneath.
//! The buffer-explicit form of this same surface is
//! `connect_explicit_buffers.zig`.
//!
//! Run: `zig build examples` (it also runs under `zig build check`).

const std = @import("std");
const glowcap = @import("glowcap");

const driver = glowcap.driver;
const model = glowcap.ocapn.model;

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
/// accept (the Noise and CapTP handshakes complete inside) and serve until they leave.
fn host(server: *driver.Server) !void {
    try server.publish("greeter", Greeter, .{});
    var session = try server.accept();
    defer session.deinit();
    try session.serve();
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // The listener's name is its key. Its direct-address hint carries the
    // bound socket, with port 0 letting the OS choose an available port.
    const secret = try driver.drawSessionSecret(io);
    var server = try driver.listen(allocator, io, .{ .symbols = &.{.noise_tcp} }, model.transport.noise_tcp, .{ .designator = "127.0.0.1:0" }, .{ .keyed = secret }, .{
        .handshake = driver.default_handshake_budget,
        .settle = driver.default_settle_budget,
    });
    defer server.deinit();

    // Own the advertised route before the server starts on another thread.
    const partner = try model.clonePeerLocator(allocator, try server.advertisedLocator());
    defer model.freePeerLocator(allocator, partner);

    var hosting = try io.concurrent(host, .{server});

    {
        // `glowcap.Session` is the front-door alias for the owning
        // `driver.Session` this call hands back.
        // Finite budgets, named: the compiler requires a choice here,
        // and writing `.unbounded` would park this program with no way out
        // against a peer that never answers.
        var session: *glowcap.Session = try driver.connect(
            allocator,
            io,
            .{ .symbols = &.{.noise_tcp} },
            partner,
            .ephemeral,
            .{
                .handshake = driver.default_handshake_budget,
                .settle = driver.default_settle_budget,
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
    std.debug.print("01: greeter fetched by name and called over an authenticated, encrypted OCapN session\n", .{});
}
