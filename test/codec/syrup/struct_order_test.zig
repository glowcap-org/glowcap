//! Dictionary keys keep whole-entry wire order without buffering value bytes.

const std = @import("std");
const glowcap = @import("glowcap");
const model = glowcap.ocapn.model;
const syrup = glowcap.ocapn.codec.syrup;
const a = std.testing.allocator;

test "dictionary ordering matches sorted entry encodings across prefix widths and backings" {
    const long_key: [101]u8 = @splat('x');
    const keys = [_][]const u8{ "", "a", "b", "\xc3\xa9", "\"", long_key[0..9], long_key[0..10], long_key[0..11], long_key[0..99], long_key[0..100], long_key[0..101] };
    var entries: [keys.len]model.StructEntry = undefined;
    for (&entries, keys, 0..) |*entry, key, i| entry.* = .{ .key = key, .value = .{ .integer = @intCast(i) } };
    for (0..keys.len + 1) |count| {
        var expected: std.ArrayList(u8) = .empty;
        defer expected.deinit(a);
        try expected.appendSlice(a, "<10'op:deliver<11'desc:export7+>[{");
        var encoded: [keys.len][]u8 = undefined;
        var built: usize = 0;
        defer for (encoded[0..built]) |bytes| a.free(bytes);
        for (keys[0..count], 0..) |key, i| {
            encoded[i] = try std.fmt.allocPrint(a, "{d}\"{s}{d}+", .{ key.len, key, i });
            built += 1;
        }
        std.mem.sort([]u8, encoded[0..count], {}, struct {
            fn less(_: void, x: []u8, y: []u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.less);
        for (encoded[0..count]) |bytes| try expected.appendSlice(a, bytes);
        try expected.appendSlice(a, "}]ff>");
        const args = [_]model.Argument{.{ .@"struct" = entries[0..count] }};
        var frame = try syrup.encodeMessage(a, .{ .deliver = .{
            .target = .{ .far = model.FarRef.object(7) },
            .args = &args,
        } });
        defer frame.deinit();
        try std.testing.expectEqualSlices(u8, expected.items, frame.bytes());
        // No slab: dictionary entries are projected from wire checkpoints.
        var decoded = try syrup.decodeBody(frame.view());
        decoded.deliver.target = .{ .far = model.FarRef.object(7) };
        var forwarded = try syrup.encodeBody(a, &decoded);
        defer forwarded.deinit();
        try std.testing.expectEqualSlices(u8, expected.items, forwarded.bytes());
    }
}
