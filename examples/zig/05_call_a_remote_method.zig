//! 05: Call a remote method on the raw engine.
//!
//! A phone calls `speaker.queue("Hot Knife")` on the kitchen speaker. This is
//! the basic CapTP move: invoke a method on a remote object and read the
//! answer back. This chapter sits one layer below everything chapters 01–04 ride:
//! the protocol peer, with manual exports and imports, explicit `step`, and
//! hand-shuttled frames. Sessions open already authenticated on CapTP 1.0 over
//! Syrup, the interop floor a live Goblins peer speaks.
//!
//! Run: `zig build examples` (it also runs under `zig build check`).

const std = @import("std");
const glowcap = @import("glowcap");
const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer if (gpa.deinit() == .leak) @panic("leaked memory");
    const allocator = gpa.allocator();

    var pair = try engine.pairing.pairedV1_0Syrup(allocator);
    defer pair.deinit();
    // `glowcap.Peer` is the front-door alias for `engine.Peer`, the type this
    // whole chapter drives by hand.
    const phone: *glowcap.Peer = &pair.p1;
    const speaker: *glowcap.Peer = &pair.p2;

    try speaker.exportObject(1);
    try phone.importObject(1);

    try phone.sendCopying(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(1) },
        .args = &.{ .{ .symbol = "queue" }, .{ .bytes = "Hot Knife" } },
        .answer = .from(42),
    } });
    _ = try phone.step();
    try speaker.feedOwned(phone.takeOutbound().?);
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
    try phone.feedOwned(speaker.takeOutbound().?);
    _ = try phone.step();

    var resolved = phone.pollEvent().?;
    defer resolved.deinit();
    const body = try resolved.view();
    const fulfilled = switch (body.resolve.resolution) {
        .fulfill => |arg| arg,
        .@"break" => |err| {
            // Fail, do not just report. This example runs under `zig build
            // examples`, and a chapter that prints a problem and exits zero
            // tells the gate everything worked.
            std.debug.print("call broke: {s}\n", .{err.message});
            return error.CallBroke;
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
