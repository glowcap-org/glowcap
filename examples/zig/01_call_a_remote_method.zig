//! 01 — Call a remote method.
//!
//! A phone calls `speaker.queue("Hot Knife")` on the kitchen speaker. This is the
//! basic CapTP move: invoke a method on a remote object and read the answer back.
//!
//! `pairing.paired` runs both `op:start-session` halves in-process and leaves both
//! sessions open on the Goblins V1.0 wire profile. (Real peers do the same
//! handshake, just over a netlayer.) One wrinkle of V1.0 is that it has no wire
//! `op:resolve`. So when a deliver carries an `answer`, the runtime quietly
//! attaches a resolver, and the partner's reply comes back as an ordinary
//! `op:deliver` to that resolver. You don't have to think about any of this:
//! `Event.view()` re-projects the callback as the `Resolve` it really stands for.
//!
//! Run: `zig build examples` (it also runs under `zig build check`).

const std = @import("std");
const pancake = @import("pancake");
const model = pancake.model;
const engine = pancake.engine;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer if (gpa.deinit() == .leak) @panic("leaked memory");
    const allocator = gpa.allocator();

    var pair = try engine.pairing.paired(allocator);
    defer pair.deinit();
    const phone = &pair.p1;
    const speaker = &pair.p2;

    // The speaker hosts an object at export id 1; the phone holds it as import 1.
    // (Chapter 02 derives this from a bootstrap fetch instead of pre-wiring it.)
    try speaker.session_state.registerExport(1);
    try phone.session_state.registerImport(1);

    // The phone calls queue("Hot Knife"), tagging the call with answer 42. The
    // args are static, so `sendCopying` clones them (vs. `send`, which takes
    // ownership and frees).
    try phone.sendCopying(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(1) },
        .args = &.{ .{ .symbol = "queue" }, .{ .bytes = "Hot Knife" } },
        .answer = 42,
    } });
    _ = try phone.step();
    try speaker.feedInbound(phone.takeOutbound().?);
    _ = try speaker.step();
    {
        var call = speaker.pollEvent().?;
        defer call.deinit();
        std.debug.print("speaker received a {s}\n", .{@tagName(call.kind())});
    }

    // The speaker hands back a receipt: a fresh local export (id 5), fulfilled to
    // the phone's answer 42. On V1.0 `step` encodes this as a resolver-callback.
    try speaker.session_state.registerExport(5);
    try speaker.sendCopying(.{ .resolve = .{
        .answer = 42,
        .resolution = .{ .fulfill = .{ .reference = .{ .near = model.NearRef.object(5) } } },
    } });
    _ = try speaker.step();
    try phone.feedInbound(speaker.takeOutbound().?);
    _ = try phone.step();

    var resolved = phone.pollEvent().?;
    defer resolved.deinit();
    // `view()` re-projects the V1.0 resolver-callback as the semantic Resolve.
    const body = try resolved.view();
    const fulfilled = switch (body.resolve.resolution) {
        .fulfill => |arg| arg,
        .break_ => |err| {
            std.debug.print("call broke: {s}\n", .{err.message});
            return;
        },
    };
    // The speaker sent Near(5) (its export); the perspective flip lands it on the
    // phone as Far(5) (the phone's import of that receipt).
    const receipt_import = switch (fulfilled) {
        .reference => |reference| switch (reference) {
            .far => |far| far.import_id,
            .near => |near| near.export_id,
            else => return error.UnexpectedReferenceShape,
        },
        else => return error.UnexpectedResolutionPayload,
    };
    std.debug.print(
        "phone resolved answer={d} -> receipt at import {d}\n",
        .{ body.resolve.answer, receipt_import },
    );
}
