//! The borrowed-view round trip every codec's encoder is held to: a frame
//! decoded to views re-encodes to the bytes its owned source produced.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;

/// Encode a deliver carrying `arg` on a promise target (a far target decodes
/// to a near one, which the encoder refuses) through `codec` (`capnp` or
/// `syrup`), decode it to views, and re-encode the views.
pub fn expectArgumentViewRoundTrip(comptime codec: type, arg: model.Argument) !void {
    const allocator = std.testing.allocator;
    const args = [_]model.Argument{ .{ .symbol = "deposit" }, arg };
    var frame = try codec.encodeMessageForProfile(allocator, .v1_0, .{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = .from(3) } },
        .args = &args,
        .answer = .from(9),
    } });
    defer frame.deinit();

    const body = try codec.decodeBodyForProfile(.v1_0, frame.view());
    var again = try codec.encodeBodyForProfile(allocator, .v1_0, &body, null);
    defer again.deinit();
    try std.testing.expectEqualSlices(u8, frame.bytes(), again.bytes());
}
