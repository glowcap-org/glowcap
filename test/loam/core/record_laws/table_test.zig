//! Compare decimal width at the boundaries of the binary rank and decimal
//! cutoff decisions. Schema sizes are measured without allocating payloads.
const std = @import("std");
const records = @import("loam_records");
const syntax = @import("syrup").RecordSyntax;

const base: records.Schema = .{ .id = 1, .version = 1, .max_payload = 0, .max_edges = 0 };

fn schemaWidth(value: u64, overhead: usize) !usize {
    var schema = base;
    schema.id = value;
    return try schema.encodedSizeBound() - overhead + 1;
}

fn expectWidths(width: usize, value: u64, overhead: usize) !void {
    errdefer std.debug.print("decimal width for {d}\n", .{value});
    try std.testing.expectEqual(width, try schemaWidth(value, overhead));
    if (std.math.cast(usize, value)) |length| {
        var schema = base;
        schema.max_payload = length;
        const payload_size = std.math.add(usize, length, width + 1);
        // The baseline already includes the two bytes of the empty payload.
        const envelope_size: error{Overflow}!usize = if (payload_size) |size|
            std.math.add(usize, overhead - 2, size)
        else |err|
            err;
        try std.testing.expectEqual(payload_size, syntax.byteStringSize(length));
        try std.testing.expectEqual(envelope_size, schema.encodedSizeBound());
    }
}

test "binary ranks and decimal cutoffs agree with the Bend record model" {
    const overhead = try base.encodedSizeBound();
    var expected = std.mem.tokenizeAny(u8, @embedFile("bend_table"), " \n");
    for ([_]u64{ 10, 2 }) |radix| {
        var power = radix;
        while (true) {
            for ([_]u64{ power - 1, power }) |value| {
                const width = try std.fmt.parseInt(usize, expected.next() orelse return error.MissingBendWidths, 10);
                try expectWidths(width, value, overhead);
            }
            power = std.math.mul(u64, power, radix) catch break;
        }
    }

    const zero = try std.fmt.parseInt(usize, expected.next() orelse return error.MissingBendWidths, 10);
    try expectWidths(zero, 0, overhead);
    const largest = try std.fmt.parseInt(usize, expected.next() orelse return error.MissingBendWidths, 10);
    // The largest payload overflows its length prefix. Measure its width
    // as a schema scalar, which spends only the decimal digits.
    try std.testing.expectEqual(largest, try schemaWidth(std.math.maxInt(u64), overhead));
    const edge_units = try std.fmt.parseInt(usize, expected.next() orelse return error.MissingBendWidths, 10);
    try std.testing.expect(expected.next() == null);

    var linked = base;
    linked.max_edges = 2;
    try std.testing.expectEqual(edge_units * records.Edge.encodedSize(), try linked.encodedSizeBound() - overhead);
}
