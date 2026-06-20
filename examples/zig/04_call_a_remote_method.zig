//! 04 — Call a remote method on the raw engine.
//!
//! A phone calls `speaker.queue("Hot Knife")` on the kitchen speaker. This is
//! the basic CapTP move — invoke a method on a remote object and read the
//! answer back — made one layer below everything chapters 01–03 ride: the bare
//! `engine.Peer`, with manual exports and imports, explicit `step`, and
//! hand-shuttled frames.
//!
//! `pairing.paired` runs both `op:start-session` halves in-process and leaves both
//! sessions open on the Goblins V1.0 wire profile. (Real peers do the same
//! handshake, over a netlayer in production.) V1.0 has no wire `op:resolve`.
//! When a deliver carries an `answer`, the runtime attaches a resolver, and the
//! partner's reply comes back as an ordinary `op:deliver` to that resolver.
//! `Event.view()` re-projects that callback as the semantic `Resolve`.
//!
//! Run: `zig build examples` (it also runs under `zig build check`).

const std = @import("std");
const pancake = @import("pancake");
const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer if (gpa.deinit() == .leak) @panic("leaked memory");
    const allocator = gpa.allocator();

    var pair = try engine.pairing.paired(allocator);
    defer pair.deinit();
    const phone = &pair.p1;
    const speaker = &pair.p2;

    try speaker.exportObject(1);
    try phone.importObject(1);

    try phone.sendCopying(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(1) },
        .args = &.{ .{ .symbol = "queue" }, .{ .bytes = "Hot Knife" } },
        .answer = .from(42),
    } });
    _ = try phone.step();
    try speaker.feedInbound(phone.takeOutbound().?);
    _ = try speaker.step();
    {
        var call = speaker.pollEvent().?;
        defer call.deinit();
        std.debug.print("speaker received a {s}\n", .{@tagName(call.kind())});
    }

    try speaker.exportObject(5);
    try speaker.sendCopying(.{ .resolve = .{
        .answer = .from(42),
        .resolution = .{ .fulfill = .{ .reference = .{ .near = model.NearRef.object(5) } } },
    } });
    _ = try speaker.step();
    try phone.feedInbound(speaker.takeOutbound().?);
    _ = try phone.step();

    var resolved = phone.pollEvent().?;
    defer resolved.deinit();
    const body = try resolved.view();
    const fulfilled = switch (body.resolve.resolution) {
        .fulfill => |arg| arg,
        .@"break" => |err| {
            std.debug.print("call broke: {s}\n", .{err.message});
            return;
        },
    };
    const receipt_import = switch (fulfilled) {
        .reference => |reference| switch (reference) {
            .far => |far| far.import_position.int(),
            .near => |near| near.export_position.int(),
            else => return error.UnexpectedReferenceShape,
        },
        else => return error.UnexpectedResolutionPayload,
    };
    std.debug.print(
        "phone resolved answer={d} -> receipt at import {d}\n",
        .{ body.resolve.answer.int(), receipt_import },
    );
}
