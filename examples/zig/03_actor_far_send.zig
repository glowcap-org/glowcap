//! 03: Actor far-send with a vow.
//!
//! A caller's Port eventual-sends to a host's published actor over a paired
//! session and observes the vow. One vat publishes an object, the other
//! imports it and calls it, and the answer comes back as a settled vow,
//! the same exchange chapter 01's `call` drives over a real socket.
//!
//! One layer down from chapter 01, the vat runs the local turn loop and a
//! Port owns the wire names: `Port.send` queues the deliver with a fresh
//! answer, `serve` dispatches the inbound deliver and resolves it, and `on`
//! fires the listener when the resolution arrives. Sessions open already
//! authenticated on CapTP 1.0 over Syrup.
//!
//! Run: `zig build examples` (it also runs under `zig build check`).

const std = @import("std");
const glowcap = @import("glowcap");
const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const actors = glowcap.actors;

const Greeter = struct {
    greeting: []const u8,

    pub fn handle(self: *Greeter, turn: *actors.Turn, msg: actors.Delivery) !model.Argument {
        if (!msg.is("greet")) return error.NoSuchMethod;
        // A partner chooses the arity, so read the argument through the
        // accessor: a `greet` with no argument breaks its own answer instead of
        // indexing past the slice.
        const name = try msg.argString(0);
        return .{ .string = try std.fmt.allocPrint(turn.arena, "{s}, {s}!", .{ self.greeting, name }) };
    }
};

const Result = struct {
    outcome: enum { pending, fulfilled, broken, give } = .pending,
    text: [128]u8 = undefined,
    text_len: usize = 0,

    fn copyText(self: *Result, s: []const u8) void {
        const n = @min(s.len, self.text.len);
        @memcpy(self.text[0..n], s[0..n]);
        self.text_len = n;
    }
};

fn onResolve(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const result: *Result = @ptrCast(@alignCast(ctx.?));
    switch (resolution) {
        .fulfilled => |arg| {
            const s = switch (arg) {
                .string => |str| str,
                else => {
                    result.outcome = .broken;
                    result.copyText("unexpected payload");
                    return;
                },
            };
            result.copyText(s);
            result.outcome = .fulfilled;
        },
        .broken => |reason| {
            result.copyText(reason);
            result.outcome = .broken;
        },
        .give => result.outcome = .give,
    }
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer if (gpa.deinit() == .leak) @panic("leaked memory");
    const allocator = gpa.allocator();

    var pair = try engine.pairing.pairedV1_0Syrup(allocator);
    defer pair.deinit();
    const host_peer = &pair.p1;
    const caller_peer = &pair.p2;

    // The Vat owns actors and turns. The Port owns this session's wire names.
    var host_vat = actors.Vat.init(allocator);
    defer host_vat.deinit();
    var host_port = actors.Port.init(allocator, host_peer);
    defer host_port.deinit(&host_vat);
    const greeter = try host_vat.spawn(Greeter, .{ .greeting = "Howdy" });
    try host_port.bindExport(&host_vat, greeter, 5);
    // This example wires both peers by hand, so the caller learns position 5
    // out-of-band rather than from a marshaled reference. An explicit grant
    // makes the hand-picked position addressable; a capability introduced on
    // the wire is granted by that first marshal instead.
    try host_peer.exportObject(5);

    try caller_peer.importObject(5);
    var caller_vat = actors.Vat.init(allocator);
    defer caller_vat.deinit();
    var caller_port = actors.Port.init(allocator, caller_peer);
    defer caller_port.deinit(&caller_vat);

    const ref: actors.Ref = .{ .far = model.FarRef.object(5) };
    var result = Result{};
    const vow = try caller_port.send(&caller_vat, ref, .{
        .verb = "greet",
        .args = &.{.{ .string = "world" }},
    });
    try caller_port.on(&caller_vat, vow, .{ .ctx = &result, .func = onResolve });

    _ = try caller_peer.step();
    while (caller_peer.takeOutbound()) |frame| try host_peer.feedOwned(frame);
    _ = try host_peer.step();
    while (host_peer.pollEvent()) |ev| {
        var e = ev;
        defer e.deinit();
        _ = try host_port.serve(&host_vat, &e);
    }
    _ = try host_peer.step();
    while (host_peer.takeOutbound()) |frame| try caller_peer.feedOwned(frame);
    _ = try caller_peer.step();
    while (caller_peer.pollEvent()) |ev| {
        var e = ev;
        defer e.deinit();
        _ = try caller_port.serve(&caller_vat, &e);
    }

    switch (result.outcome) {
        .pending => {
            std.debug.print("far-send did not resolve\n", .{});
            return error.FarSendDidNotResolve;
        },
        .fulfilled => std.debug.print("far-send resolved: {s}\n", .{result.text[0..result.text_len]}),
        .broken => {
            std.debug.print("far-send broke: {s}\n", .{result.text[0..result.text_len]});
            return error.FarSendBroke;
        },
        .give => {
            std.debug.print("far-send fulfilled with a give this example does not redeem\n", .{});
            return error.UnexpectedGive;
        },
    }
}
