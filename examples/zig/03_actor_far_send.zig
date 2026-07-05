//! 02 — Actor far-send with a promise.
//!
//! A caller's `Vat` eventual-sends to a host's published actor over a paired
//! session and observes the promise. One vat publishes an object, the other
//! imports it and calls it, and the answer comes back as a settled promise —
//! the same exchange chapter 01's `call` drives over a real socket.
//!
//! One layer down from chapter 01, the `actors.Vat` is what runs that
//! exchange: `send` queues the `op:deliver` with a fresh answer, `serve`
//! dispatches the inbound deliver and resolves it, and `on` fires the listener
//! when the resolution arrives. The Goblins V1.0 resolver-callback translation
//! (no wire `op:resolve`) is invisible; chapter 05 shows the raw `Peer`-level
//! deliver/resolve underneath all of it.
//!
//! Run: `zig build examples` (it also runs under `zig build check`).

const std = @import("std");
const pancake = @import("pancake");
const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const actors = pancake.actors;

const Greeter = struct {
    greeting: []const u8,

    pub fn handle(self: *Greeter, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        if (!std.mem.eql(u8, msg.verb, "hello")) return error.NoSuchMethod;
        const name = switch (msg.args[0]) {
            .string => |s| s,
            else => return error.BadArgument,
        };
        return .{ .string = try std.fmt.allocPrint(turn.arena, "{s}, {s}!", .{ self.greeting, name }) };
    }
};

const Result = struct {
    done: bool = false,
    text: [128]u8 = undefined,
    text_len: usize = 0,
};

fn onResolve(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const result: *Result = @ptrCast(@alignCast(ctx.?));
    result.done = true;
    switch (resolution) {
        .fulfilled => |arg| {
            const s = switch (arg) {
                .string => |str| str,
                else => "(unexpected)",
            };
            const n = @min(s.len, result.text.len);
            @memcpy(result.text[0..n], s[0..n]);
            result.text_len = n;
        },
        .broken => |reason| {
            const n = @min(reason.len, result.text.len);
            @memcpy(result.text[0..n], reason[0..n]);
            result.text_len = n;
        },
        .give => {},
    }
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer if (gpa.deinit() == .leak) @panic("leaked memory");
    const allocator = gpa.allocator();

    var pair = try engine.pairing.paired(allocator);
    defer pair.deinit();
    const host_peer = &pair.p1;
    const caller_peer = &pair.p2;

    // `pancake.Vat` is the front-door alias for `actors.Vat`.
    var host_vat = pancake.Vat.initOver(allocator, host_peer);
    defer host_vat.deinit();
    const greeter = try host_vat.spawn(Greeter, .{ .greeting = "Howdy" });
    try host_vat.bindExport(greeter, 5);

    try caller_peer.importObject(5);
    var caller_vat = actors.Vat.initOver(allocator, caller_peer);
    defer caller_vat.deinit();

    const ref: actors.Ref = .{ .far = model.FarRef.object(5) };
    var result = Result{};
    const promise = try caller_vat.send(ref, .{
        .verb = "hello",
        .args = &.{.{ .string = "world" }},
    });
    try caller_vat.on(promise, .{ .ctx = &result, .func = onResolve });

    _ = try caller_peer.step();
    while (caller_peer.takeOutbound()) |frame| try host_peer.feedInbound(frame);
    _ = try host_peer.step();
    while (host_peer.pollEvent()) |ev| {
        var e = ev;
        defer e.deinit();
        _ = try host_vat.serve(&e);
    }
    _ = try host_peer.step();
    while (host_peer.takeOutbound()) |frame| try caller_peer.feedInbound(frame);
    _ = try caller_peer.step();
    while (caller_peer.pollEvent()) |ev| {
        var e = ev;
        defer e.deinit();
        _ = try caller_vat.serve(&e);
    }

    if (result.done) {
        std.debug.print("far-send resolved: {s}\n", .{result.text[0..result.text_len]});
    } else {
        std.debug.print("far-send did not resolve\n", .{});
        std.process.exit(1);
    }
}
