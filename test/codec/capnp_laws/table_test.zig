//! Compare every field bit through the actual Cap'n Proto packers and decoders.
const std = @import("std");
const wire = @import("wire");

test "Cap'n Proto pointer fields agree with Bend" {
    var rows: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer rows.deinit();
    for ([_]wire.PointerKind{ .@"struct", .list }) |kind| {
        try row(&rows.writer, kind, 0);
        for (0..62) |i| try row(&rows.writer, kind, @as(u62, 1) << @intCast(i));
        try row(&rows.writer, kind, std.math.maxInt(u62));
        // Alternate field bits, including list element tag 101, with a negative offset.
        try row(&rows.writer, kind, 0x1555_5555_5555_5555 | (1 << 29));
    }
    try std.testing.expectEqualStrings(@embedFile("bend_table"), rows.written());
}

fn row(writer: *std.Io.Writer, kind: wire.PointerKind, payload: u62) !void {
    const input = @as(u64, payload) << 2 | @backingInt(kind);
    const decoded_kind = @backingInt(wire.pointerKind(input));
    try writer.writeByte(bit(decoded_kind, 0));
    try writer.writeByte(bit(decoded_kind, 1));
    const encoded = switch (kind) {
        .@"struct" => blk: {
            const ptr = wire.decodeStructPointer(input);
            try bits(writer, 32, @as(u32, @bitCast(ptr.offset)));
            try bits(writer, 16, ptr.data_words);
            try bits(writer, 16, ptr.ptr_words);
            break :blk wire.encodeStructPointer(ptr.offset, ptr.data_words, ptr.ptr_words);
        },
        .list => blk: {
            const ptr = wire.decodeListPointer(input);
            try bits(writer, 32, @as(u32, @bitCast(ptr.offset)));
            try bits(writer, 3, @backingInt(ptr.elem));
            try bits(writer, 29, ptr.count);
            break :blk wire.encodeListPointer(ptr.offset, ptr.elem, ptr.count);
        },
        else => unreachable,
    };
    try writer.writeByte(' ');
    for (0..64) |i| try writer.writeByte(bit(encoded, @intCast(i)));
    try writer.writeByte('\n');
}

fn bits(writer: *std.Io.Writer, width: usize, value: u64) !void {
    try writer.writeByte(' ');
    for (0..width) |i| try writer.writeByte(bit(value, @intCast(i)));
}

fn bit(value: u64, i: u6) u8 {
    return '0' + @as(u8, @as(u1, @truncate(value >> i)));
}
