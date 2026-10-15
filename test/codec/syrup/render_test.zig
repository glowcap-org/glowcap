//! Decimal rendering and the exact-size writer contract.

const std = @import("std");
const glowcap = @import("glowcap");
const render = @import("syrup").render;

test "a decimal's counted width is the width it fills" {
    const probes = [_]u64{ 0, 1, 9, 10, 11, 99, 100, 101, 999, 1000, 65535, 4294967295, 4294967296 };
    for (probes) |value| try expectDecimal(value);
    var bound: u64 = 1;
    for (0..20) |_| {
        try expectDecimal(bound - 1);
        try expectDecimal(bound);
        try expectDecimal(bound + 1);
        bound = std.math.mul(u64, bound, 10) catch break;
    }
    try expectDecimal(std.math.maxInt(u64) - 1);
    try expectDecimal(std.math.maxInt(u64));
}

/// `value` measures, fills, and overflows a short buffer through the sinks
/// the record writers use, and the digits match the standard formatter.
fn expectDecimal(value: u64) !void {
    var expected: [21]u8 = undefined;
    const want = try std.fmt.bufPrint(&expected, "{d}+", .{value});
    try std.testing.expectEqual(want.len - 1, glowcap.foundation.decimal.width(value));
    var buf: [21]u8 = undefined;
    glowcap.foundation.decimal.fill(buf[0 .. want.len - 1], value);
    try std.testing.expectEqualStrings(want[0 .. want.len - 1], buf[0 .. want.len - 1]);
    try std.testing.expectEqual(want.len, try render.measureRecord(writeOneDecimal, .{value}));
    try render.renderRecordInto(buf[0..want.len], writeOneDecimal, .{value});
    try std.testing.expectEqualStrings(want, buf[0..want.len]);
    try std.testing.expectError(
        error.EncoderInvariantViolation,
        render.renderRecordInto(buf[0 .. want.len - 1], writeOneDecimal, .{value}),
    );
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    var sink = render.ListSink{ .allocator = std.testing.allocator, .list = &list };
    try writeOneDecimal(&sink, value);
    try std.testing.expectEqualStrings(want, list.items);
}

fn writeOneDecimal(sink: anytype, value: u64) !void {
    try sink.appendTerminatedDecimal(value, '+');
}

test "exact renderer contains measure-fill divergence" {
    const DivergentWriter = struct {
        fn overfill(sink: anytype, pass: *usize) !void {
            pass.* += 1;
            for (0..pass.*) |_| try sink.append('x');
        }

        fn underfill(sink: anytype, pass: *usize) !void {
            pass.* += 1;
            const count: usize = if (pass.* == 1) 2 else 1;
            for (0..count) |_| try sink.append('x');
        }
    };

    var overfill_pass: usize = 0;
    try std.testing.expectError(
        error.EncoderInvariantViolation,
        render.renderRecordExact(std.testing.allocator, DivergentWriter.overfill, .{&overfill_pass}),
    );

    var underfill_pass: usize = 0;
    try std.testing.expectError(
        error.EncoderInvariantViolation,
        render.renderRecordExact(std.testing.allocator, DivergentWriter.underfill, .{&underfill_pass}),
    );
}
