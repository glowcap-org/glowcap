//! Live three-party handoff, with pancake as the recipient (Carol), driven
//! through `driver.core.Host` + `driver.Bridge` + `net.TcpLoop` (ADR-0068,
//! ADR-0076).
//!
//! pancake dials a Goblins introducer (Alice) through one Host, enlivens the
//! introducer, and calls `get-greeter`. A three-party introduction hands the
//! greeter over as a `desc:handoff-give` naming the exporter (Bob), and the
//! host redeems it inside the settle: it claims the give, dials Bob under the
//! host's own identity, presents the signed `desc:handoff-receive`, and
//! withdraws the gift — so the call settles directly with the greeter as an
//! ordinary routable reference. Calling that reference routes through the
//! host to Bob's connection, and the greeter replies directly.
//!
//! Needs `racket` + the `goblins` collection on PATH; runs as the sibling step
//! `zig build goblins-handoff`, not in the hermetic gate.

const std = @import("std");
const pancake = @import("pancake");
const goblins_child = @import("goblins_child.zig");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const actors = pancake.actors;
const crypto = pancake.foundation.crypto;
const driver = pancake.driver;
const net = pancake.net;
const tcp = pancake.net.tcp;

const Host = driver.core.Host;
const HostSession = driver.core.HostSession;
const TcpBridge = driver.Bridge(net.TcpLoop);

const host_addr = "127.0.0.1";
const default_alice_port: u16 = 22110;
const frame_cap: usize = 1 << 16;
const host_script = "conformance/goblins-peer/racket/handoff-introducer-host.rkt";
const deadline_ms: u64 = 60_000;

fn deadlineAfter(io: std.Io) std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.fromNow(io, .{
        .raw = std.Io.Duration.fromMilliseconds(deadline_ms),
        .clock = .real,
    });
}

fn expired(io: std.Io, deadline: std.Io.Clock.Timestamp) bool {
    return std.Io.Clock.Timestamp.now(io, .real).compare(.gte, deadline);
}

fn waitFlag(io: std.Io, flag: *const std.atomic.Value(bool)) !void {
    const deadline = deadlineAfter(io);
    while (!flag.load(.acquire)) {
        if (expired(io, deadline)) return error.WaitTimedOut;
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(2), .real) catch {};
    }
}

fn runLoop(loop: *net.TcpLoop, done: *const std.atomic.Value(bool), out_err: *?anyerror) void {
    loop.runUntil(done, 0) catch |err| {
        out_err.* = err;
        return;
    };
    loop.closeAndDrain() catch |err| {
        out_err.* = err;
    };
}

const RecipientState = struct {
    host: *Host,
    bridge: *TcpBridge,
    alice_conn: ?*HostSession = null,
    swiss: []const u8,
    greeter_done: *std.atomic.Value(bool),
    ok: *std.atomic.Value(bool),

    fn onEnlivened(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *RecipientState = @ptrCast(@alignCast(ctx.?));
        const conn = self.alice_conn orelse return;
        switch (resolution) {
            .fulfilled => |value| {
                if (value != .reference) return;
                std.debug.print("goblins-handoff: enlivened alice's introducer\n", .{});
                const vow = self.host.send(conn, value.reference, .{ .verb = "get-greeter", .args = &.{} }) catch |err| {
                    std.debug.print("goblins-handoff: get-greeter send: {s}\n", .{@errorName(err)});
                    return;
                };
                self.host.vowOn(vow, .{ .ctx = self, .func = onGreeter }) catch |err| {
                    std.debug.print("goblins-handoff: get-greeter vowOn: {s}\n", .{@errorName(err)});
                    return;
                };
                self.bridge.drainActions() catch {};
            },
            .broken => |reason| std.debug.print("goblins-handoff: enliven broke: {s}\n", .{reason}),
            .give => {},
        }
    }

    fn onGreeter(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *RecipientState = @ptrCast(@alignCast(ctx.?));
        const conn = self.alice_conn orelse return;
        switch (resolution) {
            .fulfilled => |value| {
                const greeter = switch (value) {
                    .reference => |r| r,
                    else => {
                        std.debug.print("goblins-handoff: expected a greeter reference\n", .{});
                        self.greeter_done.store(true, .release);
                        return;
                    },
                };
                std.debug.print("goblins-handoff: redeemed greeter; calling it directly\n", .{});
                const vow = self.host.send(conn, greeter, .{ .verb = "", .args = &.{.{ .string = "pancake-carol" }} }) catch |err| {
                    std.debug.print("goblins-handoff: greet send: {s}\n", .{@errorName(err)});
                    self.greeter_done.store(true, .release);
                    return;
                };
                self.host.vowOn(vow, .{ .ctx = self, .func = onGreeted }) catch |err| {
                    std.debug.print("goblins-handoff: greet vowOn: {s}\n", .{@errorName(err)});
                    self.greeter_done.store(true, .release);
                    return;
                };
                self.bridge.drainActions() catch {};
            },
            .broken => |reason| {
                std.debug.print("goblins-handoff: get-greeter broke: {s}\n", .{reason});
                self.greeter_done.store(true, .release);
            },
            .give => {},
        }
    }

    fn onGreeted(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *RecipientState = @ptrCast(@alignCast(ctx.?));
        switch (resolution) {
            .fulfilled => |value| {
                if (value == .string) {
                    std.debug.print("goblins-handoff: greeter replied: {s}\n", .{value.string});
                    self.ok.store(true, .release);
                }
                self.greeter_done.store(true, .release);
            },
            .broken => |reason| {
                std.debug.print("goblins-handoff: greet broke: {s}\n", .{reason});
                self.greeter_done.store(true, .release);
            },
            .give => self.greeter_done.store(true, .release),
        }
    }
};

fn recipientOnOpen(ctx: ?*anyopaque, bridge: *TcpBridge, conn: *TcpBridge.Slot) anyerror!void {
    const state: *RecipientState = @ptrCast(@alignCast(ctx.?));
    if (conn.leg != .app_dial or conn.session.role != .dialed) return;
    if (state.alice_conn != null) return;
    state.alice_conn = conn.session;
    std.debug.print("goblins-handoff: session open (pancake as recipient -> alice)\n", .{});
    const vow = try state.host.enliven(conn.session, state.swiss);
    try state.host.vowOn(vow, .{ .ctx = state, .func = RecipientState.onEnlivened });
    try bridge.drainActions();
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    var alice_port: u16 = default_alice_port;
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--port=")) {
            alice_port = std.fmt.parseInt(u16, arg["--port=".len..], 10) catch 0;
            if (alice_port == 0 or alice_port == 65535) {
                std.debug.print("goblins-handoff: --port must be an integer in 1..65534 (bob listens on port+1)\n", .{});
                return error.BadPort;
            }
        } else {
            std.debug.print("goblins-handoff: unknown argument '{s}'\n", .{arg});
            return error.BadArgument;
        }
    }
    var alice_port_buf: [8]u8 = undefined;
    const alice_port_str = try std.fmt.bufPrint(&alice_port_buf, "{d}", .{alice_port});
    var bob_port_buf: [8]u8 = undefined;
    const bob_port_str = try std.fmt.bufPrint(&bob_port_buf, "{d}", .{alice_port + 1});

    var child = try std.process.spawn(io, .{
        .argv = &.{ goblins_child.racket_path, host_script, alice_port_str, bob_port_str },
        .environ_map = init.environ_map,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var reaped = false;
    defer if (!reaped) child.kill(io);

    const swiss = goblins_child.readPublishedSwiss(io, allocator, &child) catch |err| {
        std.debug.print("goblins-handoff: never saw the introducer readiness line: {s}\n", .{@errorName(err)});
        goblins_child.dumpChildStderr(io, "goblins-handoff", &child);
        return err;
    };
    defer allocator.free(swiss);
    std.debug.print("goblins-handoff: alice published introducer swiss={s} on {s}:{s}\n", .{ swiss, host_addr, alice_port_str });

    recipientStep(io, allocator, swiss, alice_port_str) catch |err| {
        goblins_child.dumpChildStderr(io, "goblins-handoff", &child);
        return err;
    };

    child.kill(io);
    reaped = true;
}

fn recipientStep(io: std.Io, allocator: std.mem.Allocator, swiss: []const u8, alice_port_str: []const u8) !void {
    var seed: [crypto.SEED_BYTES]u8 = undefined;
    io.randomSecure(&seed) catch return error.HandshakeEntropyFailed;

    var host = Host.init(allocator, seed, blk: {
        var o = Host.Options.withFrameCap(frame_cap);
        o.local_turn_budget = 64;
        break :blk o;
    });
    defer host.deinit();

    var greeter_done = std.atomic.Value(bool).init(false);
    var ok = std.atomic.Value(bool).init(false);
    var state: RecipientState = undefined;
    var loop: net.TcpLoop = undefined;
    var bridge = TcpBridge.init(allocator, &host, io, &loop, .{
        .on_open = recipientOnOpen,
        .on_open_ctx = &state,
    });
    defer bridge.deinit();
    state = .{
        .host = &host,
        .bridge = &bridge,
        .swiss = swiss,
        .greeter_done = &greeter_done,
        .ok = &ok,
    };

    loop = try net.TcpLoop.init(allocator, TcpBridge.makePeer, @ptrCast(&bridge), .{
        .frame_cap = frame_cap,
        .max_conns = 8,
        .listen = 0,
        .make_conn_ctx = TcpBridge.makeConnCtx,
        .serve = TcpBridge.serve,
        .free_conn_ctx = TcpBridge.freeConnCtx,
        .on_close = TcpBridge.onClose,
    });
    defer loop.deinit();
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const bound_addr = try tcp.parseHostPort("127.0.0.1", loop.port.?);
    const bound = tcp.locator(&designator_buf, bound_addr).designator;
    try bridge.attach(tcp.transport_name, bound, &.{});

    const alice_port = try std.fmt.parseInt(u16, alice_port_str, 10);
    var alice_designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const alice_addr = try tcp.parseHostPort(host_addr, alice_port);
    const alice_designator = tcp.locator(&alice_designator_buf, alice_addr).designator;
    try bridge.dialOutbound(tcp.transport_name, alice_designator, "");

    var loop_err: ?anyerror = null;
    var loop_future = try io.concurrent(runLoop, .{ &loop, &greeter_done, &loop_err });
    try waitFlag(io, &greeter_done);
    loop_future.await(io);
    if (loop_err) |err| return err;
    if (!ok.load(.acquire)) return error.HandoffFailed;
}
