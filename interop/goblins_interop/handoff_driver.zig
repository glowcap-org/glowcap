//! Live three-party handoff, with glowcap as the recipient (Carol), on one
//! owning `driver.Session` (ADR-0068).
//!
//! glowcap dials a Goblins introducer (Alice), fetches the introducer, and
//! calls `get-greeter`. A three-party introduction hands the
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
const glowcap = @import("glowcap");
const goblins_child = @import("goblins_child.zig");
const harness = @import("interop_harness");

const driver = glowcap.driver;
const tcp = glowcap.net.tcp;

const host_addr = "127.0.0.1";
const default_alice_port: u16 = 22110;
const frame_cap: usize = 1 << 16;
const host_script = "conformance/goblins-peer/racket/handoff-introducer-host.rkt";

const opts: driver.SessionOptions = .{
    .frame_cap = frame_cap,
    .handshake = .{ .ms = 20_000 },
    .settle = .{ .ms = 60_000 },
};

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
    const alice_port = try std.fmt.parseInt(u16, alice_port_str, 10);
    var alice_designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const alice_locator = tcp.locatorFromAddress(&alice_designator_buf, try tcp.parseHostPort(host_addr, alice_port));

    const alice = try driver.connect(allocator, io, .{ .symbols = &.{.tcp} }, alice_locator, .ephemeral, opts);
    defer alice.deinit();
    std.debug.print("goblins-handoff: session open (glowcap as recipient -> alice)\n", .{});
    const introducer = try alice.fetch(swiss);
    std.debug.print("goblins-handoff: fetched alice's introducer\n", .{});

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The answer is a give naming Bob. The call returns once this runtime has
    // dialed Bob, proved his identity, and withdrawn the gift.
    const greeter = switch (try alice.call(introducer, "get-greeter", &.{}, arena)) {
        .fulfilled => |value| switch (value) {
            .capability => |capability| capability,
            else => return error.HandoffFailed,
        },
        .broken => |reason| {
            std.debug.print("goblins-handoff: get-greeter broke: {s}\n", .{reason});
            return error.HandoffFailed;
        },
    };
    std.debug.print("goblins-handoff: redeemed greeter; calling it directly\n", .{});
    switch (try alice.call(greeter, "", &.{.{ .string = "glowcap-carol" }}, arena)) {
        .fulfilled => |value| switch (value) {
            .string => |reply| std.debug.print("goblins-handoff: greeter replied: {s}\n", .{reply}),
            else => return error.HandoffFailed,
        },
        .broken => |reason| {
            std.debug.print("goblins-handoff: greet broke: {s}\n", .{reason});
            return error.HandoffFailed;
        },
    }
}
