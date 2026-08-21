const std = @import("std");

const c = @import("c_abi_shared");
const engine = @import("pancake").ocapn.engine;

test "last abort projection retains bounded secondary diagnostics" {
    var peer = engine.Peer.init(std.testing.allocator);
    defer peer.deinit();
    peer.recordFailure(error.PrimaryFailure);
    peer.recordSecondaryFailure(error.FirstCleanupFailure);
    peer.recordSecondaryFailure(error.LaterCleanupFailure);

    const projected = c.lastAbortToC(peer.lastAbort().?);
    try std.testing.expectEqualStrings(
        "FirstCleanupFailure",
        projected.secondary_error_name.?[0..projected.secondary_error_name_len],
    );
    try std.testing.expectEqual(@as(u32, 2), projected.secondary_error_count);
}

test "last-error overflow is visibly truncated" {
    const truncated_suffix = "... [truncated]";
    const oversized = @as([512]u8, @splat('x'));
    c.setLastError("cause: {s}", .{oversized});
    defer c.lastErrorClear();

    const len = c.lastErrorRead(null, 0);
    var buf: [512]u8 = undefined;
    try std.testing.expectEqual(len, c.lastErrorRead(&buf, buf.len));
    try std.testing.expect(std.mem.endsWith(u8, buf[0..len], truncated_suffix));
}
