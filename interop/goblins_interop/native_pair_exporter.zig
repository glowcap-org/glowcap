//! The pancake exporter half of `native_pair_gift_driver.zig`, as its own
//! process.
//!
//! It is a separate process for the same reason every Goblins peer in this
//! tree is: one completion loop per process. The driver already runs a loop
//! for the gifter and polls from its main task, and adding a second loop
//! beside them made the run's outcome depend on how three schedulable things
//! interleaved. Two processes have no such question, and the peers are talking
//! over a real socket either way.
//!
//! Publishes a giftable greeter, prints `EXPORTER LISTENING <host:port>`, and
//! serves until killed. It prefers `pancake-next` over Cap'n Proto, which it
//! gets on the gifter's dial and does not get on the Goblins redeem — the
//! split the driver asserts.

const std = @import("std");
const pancake = @import("pancake");
const harness = @import("interop_harness");

const model = pancake.ocapn.model;
const actors = pancake.actors;
const crypto = pancake.foundation.crypto;
const driver = pancake.driver;
const net = pancake.net;
const tcp = pancake.net.tcp;

const Host = driver.core.Host;
const HostSession = driver.core.HostSession;
const TcpBridge = driver.Bridge(net.TcpLoop);

const host_addr = "127.0.0.1";
const frame_cap: usize = 1 << 16;
pub const greeter_swiss = "pancakeNativePairGreeterSwiss001";
pub const listening_prefix = "EXPORTER LISTENING ";

/// Answers with the name it was called with, so the driver can tell a reply
/// from this actor apart from a reply from anything the gifter stood in with.
const Greeter = struct {
    pub fn handle(_: *Greeter, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        // A plain Goblins `(<- greeter "name")` arrives with an empty verb and
        // the caller's name as the one argument.
        if (msg.args.len != 1 or msg.args[0] != .string) return error.BadInvocation;
        return .{ .string = try std.fmt.allocPrint(
            turn.arena,
            "Hello {s}, I'm the pancake exporter reached across the profile split!",
            .{msg.args[0].string},
        ) };
    }
};

const State = struct {
    host: *Host,
    published: bool = false,
};

/// Publish host-wide on the first session, because a give names a capability
/// the redeeming connection has never seen: the name has to exist on a
/// connection nobody has opened yet. From this hook rather than from `main`
/// because a Host belongs to the thread driving its loop.
fn publishGreeter(ctx: ?*anyopaque, served: *driver.Served, vat: *actors.Vat) anyerror!void {
    _ = served;
    _ = vat;
    const state: *State = @ptrCast(@alignCast(ctx.?));
    if (state.published) return;
    state.published = true;
    _ = try state.host.publishGiftable(greeter_swiss, Greeter, .{});
}

/// Report each session's settled profile on stdout, so the driver asserts what
/// this process actually negotiated rather than what it asked for.
fn onOpen(ctx: ?*anyopaque, bridge: *TcpBridge, conn: *TcpBridge.Slot) anyerror!void {
    _ = ctx;
    _ = bridge;
    // `std.debug.print`, not an `io` write: this runs inside a loop callback,
    // and an `io` write here needs the very loop it is running under to make
    // progress, which wedges the process with no error anywhere.
    const state = &conn.session.served.port.peer.session_state;
    std.debug.print("EXPORTER SESSION codec={s} captp={s}\n", .{
        @tagName(state.codec),
        @tagName(state.captp_version),
    });
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var seed: [crypto.SEED_BYTES]u8 = undefined;
    io.randomSecure(&seed) catch return error.HandshakeEntropyFailed;
    var session_root: [crypto.SEED_BYTES]u8 = undefined;
    io.randomSecure(&session_root) catch return error.HandshakeEntropyFailed;
    var host = try Host.init(allocator, seed, session_root, blk: {
        var o = Host.Options.withFrameCap(frame_cap);
        o.local_turn_budget = 64;
        o.codec = .capnp;
        o.captp_version = .next;
        break :blk o;
    });
    defer host.deinit();

    var state = State{ .host = &host };
    var loop: net.TcpLoop = undefined;
    var bridge = TcpBridge.init(allocator, &host, io, &loop, .{
        .publish = publishGreeter,
        .publish_ctx = &state,
        .on_open = onOpen,
        .on_open_ctx = &state,
    });
    defer bridge.deinit();

    loop = try net.TcpLoop.init(allocator, TcpBridge.makePeer, @ptrCast(&bridge), TcpBridge.hookOptions(.{
        .max_conns = 8,
        .listen = 0,
    }));
    defer loop.deinit();

    const port = loop.port().?;
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const addr = try tcp.parseHostPort(host_addr, port);
    const bound = tcp.locatorFromAddress(&designator_buf, addr).designator;
    try bridge.attach(model.transport.Known.tcp.metadata(), bound, &.{});

    // Both announce lines go to stderr so the driver reads one stream.
    std.debug.print(listening_prefix ++ "{s}\n", .{bound});

    // Serve until the driver kills us; it owns the run's lifetime.
    var never = std.atomic.Value(bool).init(false);
    var err: ?anyerror = null;
    harness.LoopRunner(net.TcpLoop).runUntilFlag(&loop, &never, &err);
    if (err) |e| return e;
}
