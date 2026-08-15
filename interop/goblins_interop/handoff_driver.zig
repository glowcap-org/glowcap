//! Live three-party handoff, with pancake as the recipient (Carol), driven
//! through `driver.core.Host` + `driver.Bridge` + `net.TcpLoop` (ADR-0068,
//! ADR-0076).
//!
//! pancake dials a Goblins introducer (Alice) through one Host, enlivens the
//! introducer, and calls `get-greeter`. A three-party introduction hands the
//! greeter over as a `desc:handoff-give` naming the exporter (Bob), and the
//! host redeems it inside the settle: it claims the give, dials Bob under the
//! host's own identity, presents the signed `desc:handoff-receive`, and
//! withdraws the gift, so the call settles directly with the greeter as an
//! ordinary routable reference. Calling that reference routes through the
//! host to Bob's connection, and the greeter replies directly.
//!
//! Needs `racket` + the `goblins` collection on PATH; runs as the sibling step
//! `zig build goblins-handoff`, not in the in-tree check.

const std = @import("std");
const pancake = @import("pancake");
const goblins_child = @import("goblins_child.zig");
const harness = @import("interop_harness");

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
const runLoop = harness.LoopRunner(net.TcpLoop).runUntilFlag;

const host_addr = "127.0.0.1";
const default_alice_port: u16 = 22110;
const frame_cap: usize = 1 << 16;
const host_script = "conformance/goblins-peer/racket/handoff-introducer-host.rkt";
const deadline_ms: u64 = 60_000;

const RecipientState = struct {
    host: *Host,
    bridge: *TcpBridge,
    alice_conn: ?*HostSession = null,
    sturdyref: model.SturdyRef,
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
    const vow = try state.host.enliven(conn.session, state.sturdyref);
    try state.host.vowOn(vow, .{ .ctx = state, .func = RecipientState.onEnlivened });
    try bridge.drainActions();
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    const alice_port = try harness.parsePortFlag(init.minimal.args, "goblins-handoff", default_alice_port, .{
        .max = 65534,
        .note = " (bob listens on port+1)",
    });
    var alice_port_buf: [8]u8 = undefined;
    const alice_port_str = try std.fmt.bufPrint(&alice_port_buf, "{d}", .{alice_port});
    var bob_port_buf: [8]u8 = undefined;
    const bob_port_str = try std.fmt.bufPrint(&bob_port_buf, "{d}", .{alice_port + 1});

    const hosted = try goblins_child.spawnHostAwaitSwiss(io, allocator, init.environ_map, "goblins-handoff", "introducer", &.{ host_script, alice_port_str, bob_port_str });
    var child = hosted.child;
    var reaped = false;
    defer if (!reaped) child.kill(io);

    const swiss = hosted.swiss;
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
    var session_root: [crypto.SEED_BYTES]u8 = undefined;
    io.randomSecure(&session_root) catch return error.HandshakeEntropyFailed;

    var host = try Host.init(allocator, seed, session_root, blk: {
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
    loop = try net.TcpLoop.init(allocator, TcpBridge.makePeer, @ptrCast(&bridge), TcpBridge.hookOptions(.{
        .max_conns = 8,
        .listen = 0,
    }));
    defer loop.deinit();
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const bound_addr = try tcp.parseHostPort("127.0.0.1", loop.port().?);
    const bound = tcp.locatorFromAddress(&designator_buf, bound_addr).designator;
    try bridge.attach(model.transport.Known.tcp.metadata(), bound, &.{});

    const alice_port = try std.fmt.parseInt(u16, alice_port_str, 10);
    var alice_designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const alice_addr = try tcp.parseHostPort(host_addr, alice_port);
    const alice_locator = tcp.locatorFromAddress(&alice_designator_buf, alice_addr);
    state = .{
        .host = &host,
        .bridge = &bridge,
        .sturdyref = .{ .peer = alice_locator, .swissnum = swiss },
        .greeter_done = &greeter_done,
        .ok = &ok,
    };
    try bridge.dialOutbound(alice_locator);

    var loop_err: ?anyerror = null;
    var loop_future = try io.concurrent(runLoop, .{ &loop, &greeter_done, &loop_err });
    try harness.untilFlag(io, deadline_ms, &greeter_done);
    loop_future.await(io);
    if (loop_err) |err| return err;
    if (!ok.load(.acquire)) return error.HandoffFailed;
}
