//! 01 — The application surface: connect, listen, fetch, call, serve, close.
//!
//! This chapter is the surface an application actually rides — the same nine
//! verbs every binding exposes (connect, listen, fetch, publish, spawn, send,
//! tell, serve, close), in native Zig, plus `call`: the blocking
//! send-and-await this chapter's client uses. Chapter 02 shows several
//! sessions under one identity; chapters 03–05 then go one layer
//! deeper apiece underneath, down to the raw engine. Each side holds one owning
//! `driver.Session` over a real TCP socket with the keyed, authenticated
//! `op:start-session`
//! handshake on both ends. The host listens, accepts a partner, publishes an
//! actor by name, and `serve`s until the partner leaves. The client connects,
//! fetches the actor by name, `call`s it, and switches on the settled outcome.
//! There are no export positions, no manual flush, and no hand-rolled receive
//! loop. `frame_cap` bounds protocol admission independently of the wire
//! buffers retained by each session; the buffer-explicit form of the same
//! surface lives in `connect_explicit_buffers.zig`.
//!
//! Run: `zig build examples` (it also runs under `zig build check`).

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const actors = pancake.actors;
const driver = pancake.driver;

/// The published actor: answers `greet(name)` with a greeting built in the
/// turn's arena, which outlives the reply encode and nothing more.
const Greeter = struct {
    pub fn handle(self: *Greeter, ht: *driver.HostTurn, verb: []const u8, args: []const driver.Value) !driver.Value {
        _ = self;
        if (!std.mem.eql(u8, verb, "greet")) return error.NoSuchMethod;
        if (args.len != 1) return error.BadInvocation;
        const name = switch (args[0]) {
            .string => |s| s,
            else => return error.BadInvocation,
        };
        return .{ .string = try std.fmt.allocPrint(ht.turn.arena, "Hello, {s}", .{name}) };
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

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tcp_resident = pancake.net.tcp.Resident{ .io = io };
    // Listen on a designator, the peer's name on its transport: for tcp a
    // `host:port`, with port 0 letting the OS pick one.
    var server = try driver.listen(allocator, tcp_resident.netlayer(), .{ .designator = "127.0.0.1:0" }, .ephemeral, .{
        .handshake = .{ .ms = 10_000 },
        .settle = .{ .ms = 10_000 },
    });
    defer server.close() catch {};

    var addr_buf: [64]u8 = undefined;
    // `try`: a bound listener that cannot report a dialable designator is a
    // defect, and signing an empty one publishes an address nobody can dial.
    const designator = try server.localDesignator(&addr_buf);

    var hosting = try io.concurrent(host, .{&server});

    // `pancake.Session` is the front-door alias for the owning
    // `driver.Session` this call hands back.
    // Finite budgets, named on purpose: the compiler requires a choice here,
    // and writing `.unbounded` would park this program with no way out
    // against a peer that never answers.
    var session: *pancake.Session = try driver.connect(allocator, &.{tcp_resident.netlayer()}, pancake.net.tcp.at(designator), .ephemeral, .{
        .handshake = .{ .ms = 10_000 },
        .settle = .{ .ms = 10_000 },
    });
    const greeter = try session.fetch("greeter");

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const settled = try session.call(greeter, "greet", &.{.{ .string = "world" }}, arena_state.allocator());

    session.deinit();
    try hosting.await(io);

    const ok = switch (settled) {
        .fulfilled => |value| value == .string and std.mem.eql(u8, value.string, "Hello, world"),
        .broken => false,
    };
    if (!ok) return error.UnexpectedReply;
    std.debug.print("01: greeter fetched by name and called over an OCapN session on the `tcp` netlayer\n", .{});
}
