const std = @import("std");
const inlineAssert = @import("config.zig").quirks.inlineAssert;

/// A replacement for std.MultiArrayList(T).Slice that supports `append`,
/// `subset` extraction, handles 0-field structs, and avoids branch quota
/// issues with large structs.
pub fn MultiSlice(comptime T: type) type {
    @setEvalBranchQuota(50_000);
    const info = @typeInfo(T).@"struct";
    const field_names = info.field_names;
    const field_types = info.field_types;
    const field_attrs = info.field_attrs;

    return struct {
        ptrs: [field_names.len][*]u8,
        len: usize,
        capacity: usize,

        const Self = @This();
        pub const Elem = T;
        pub const Field = std.meta.FieldEnum(T);

        pub fn FieldType(comptime field: Field) type {
            @setEvalBranchQuota(50_000);
            return field_types[@intFromEnum(field)];
        }

        pub fn items(self: Self, comptime field: Field) []FieldType(field) {
            const F = FieldType(field);
            if (self.capacity == 0) {
                return &[_]F{};
            }
            const byte_ptr = self.ptrs[@intFromEnum(field)];
            const casted_ptr: [*]F = if (@sizeOf(F) == 0)
                undefined
            else
                @ptrCast(@alignCast(byte_ptr));
            return casted_ptr[0..self.len];
        }

        pub fn set(self: Self, index: usize, elem: T) void {
            inline for (field_names, 0..) |field_name, i| {
                self.items(@as(Field, @enumFromInt(i)))[index] = @field(elem, field_name);
            }
        }

        pub fn get(self: Self, index: usize) T {
            var result: T = undefined;
            inline for (field_names, 0..) |field_name, i| {
                @field(result, field_name) = self.items(@as(Field, @enumFromInt(i)))[index];
            }
            return result;
        }

        pub fn subset(self: Self, comptime Subset: type) MultiSlice(Subset) {
            const subset_fields = @typeInfo(Subset).@"struct".field_names;
            var result: MultiSlice(Subset) = undefined;
            inline for (subset_fields, 0..) |subset_field, dst_idx| {
                const src_idx = comptime for (field_names, 0..) |field_name, i| {
                    if (std.mem.eql(u8, field_name, subset_field)) break i;
                } else @compileError("subset field '" ++ subset_field ++ "' not found in source");
                result.ptrs[dst_idx] = self.ptrs[src_idx];
            }
            result.len = self.len;
            result.capacity = self.capacity;
            return result;
        }

        pub fn memset(self: Self, elem: T) void {
            inline for (field_names, field_types, 0..) |field_name, F, i| {
                const field: Field = @enumFromInt(i);
                const value = @field(elem, field_name);
                const slice = self.items(field);
                if (@sizeOf(F) == 0) {
                    // Zero-size types have nothing to set.
                } else if (@bitSizeOf(F) != @sizeOf(F) * 8) {
                    // Types like bool, u3, enum(u2), or packed struct { data:
                    // i14 } have fewer bits than their storage size, so
                    // @memset can't be called directly on their slices.
                    // Convert to a byte-array representation by bit-casting
                    // to an unsigned int of the same bit width and
                    // zero-extending into a storage-sized int, then @memset
                    // the reinterpreted byte array for the same performance as
                    // a normal @memset.
                    const StorageInt = std.math.IntFittingRange(0, (@as(comptime_int, 1) << (@sizeOf(F) * 8)) - 1);
                    const IntEquivalent = std.math.IntFittingRange(0, (@as(comptime_int, 1) << @bitSizeOf(F)) - 1);
                    const storage: StorageInt = switch (@typeInfo(F)) {
                        .int, .@"struct", .@"union" => @as(IntEquivalent, @bitCast(value)),
                        .bool => @intFromBool(value),
                        .@"enum" => @intFromEnum(value),
                        else => @compileError("memset: unsupported non-byte-aligned type '" ++ @typeName(F) ++ "'"),
                    };
                    const ints: [*]StorageInt = @ptrCast(slice.ptr);
                    @memset(ints[0..slice.len], storage);
                } else {
                    @memset(slice, value);
                }
            }
        }

        pub fn append(self: *Self, elem: T) void {
            inlineAssert(self.len < self.capacity);
            self.len += 1;
            self.set(self.len - 1, elem);
        }

        pub fn initCapacity(allocator: std.mem.Allocator, capacity: usize) std.mem.Allocator.Error!Self {
            if (field_names.len == 0 or capacity == 0) {
                return .{ .ptrs = undefined, .len = 0, .capacity = capacity };
            }
            const byte_count = capacityInBytes(capacity);
            const buf = try allocator.alignedAlloc(u8, alignment, byte_count);
            var result: Self = .{ .ptrs = undefined, .len = 0, .capacity = capacity };
            var ptr: [*]u8 = buf.ptr;
            for (sorted_sizes, sorted_fields) |field_size, fi| {
                result.ptrs[fi] = ptr;
                ptr += field_size * capacity;
            }
            return result;
        }

        const alignment: std.mem.Alignment = blk: {
            var max_align: usize = 1;
            for (field_types, field_attrs) |F, attrs| {
                const a: usize = if (@sizeOf(F) == 0)
                    1
                else
                    attrs.@"align" orelse @alignOf(F);
                if (a > max_align) max_align = a;
            }
            break :blk @enumFromInt(std.math.log2(max_align));
        };

        const sorted_sizes: [field_names.len]usize = blk: {
            var sizes: [field_names.len]usize = undefined;
            for (sortOrder(), 0..) |si, i| {
                sizes[i] = @sizeOf(field_types[si]);
            }
            break :blk sizes;
        };

        const sorted_fields: [field_names.len]usize = sortOrder();

        fn sortOrder() [field_names.len]usize {
            @setEvalBranchQuota(field_names.len * field_names.len + 100);
            var order: [field_names.len]usize = undefined;
            for (0..field_names.len) |i| order[i] = i;
            for (0..field_names.len) |i| {
                var best = i;
                for (i + 1..field_names.len) |j| {
                    const best_type = field_types[order[best]];
                    const j_type = field_types[order[j]];
                    const best_align = if (@sizeOf(best_type) == 0)
                        1
                    else
                        field_attrs[order[best]].@"align" orelse @alignOf(best_type);
                    const j_align = if (@sizeOf(j_type) == 0)
                        1
                    else
                        field_attrs[order[j]].@"align" orelse @alignOf(j_type);
                    if (j_align > best_align) best = j;
                }
                const tmp = order[i];
                order[i] = order[best];
                order[best] = tmp;
            }
            return order;
        }

        fn capacityInBytes(capacity: usize) usize {
            var total: usize = 0;
            for (sorted_sizes) |s| {
                total += s * capacity;
            }
            return total;
        }
    };
}

test "basic MultiSlice operations" {
    const Row = struct {
        a: u32,
        b: u8,
    };
    const MS = MultiSlice(Row);

    var ms = try MS.initCapacity(std.testing.allocator, 4);
    defer std.testing.allocator.free(@as([*]u8, @ptrCast(@alignCast(ms.ptrs[MS.sorted_fields[0]])))[0..MS.capacityInBytes(4)]);

    try std.testing.expectEqual(0, ms.len);

    ms.append(.{ .a = 10, .b = 1 });
    ms.append(.{ .a = 20, .b = 2 });

    try std.testing.expectEqual(2, ms.len);
    try std.testing.expectEqual(10, ms.items(.a)[0]);
    try std.testing.expectEqual(20, ms.items(.a)[1]);
    try std.testing.expectEqual(1, ms.items(.b)[0]);
    try std.testing.expectEqual(2, ms.items(.b)[1]);

    const row = ms.get(0);
    try std.testing.expectEqual(10, row.a);
    try std.testing.expectEqual(1, row.b);

    ms.set(0, .{ .a = 99, .b = 9 });
    try std.testing.expectEqual(99, ms.items(.a)[0]);
}

test "memset" {
    const Row = struct {
        a: u32,
        b: u8,
    };
    const MS = MultiSlice(Row);

    var ms = try MS.initCapacity(std.testing.allocator, 4);
    defer std.testing.allocator.free(@as([*]u8, @ptrCast(@alignCast(ms.ptrs[MS.sorted_fields[0]])))[0..MS.capacityInBytes(4)]);

    ms.len = 4;
    ms.memset(.{ .a = 42, .b = 7 });

    for (0..4) |i| {
        try std.testing.expectEqual(42, ms.items(.a)[i]);
        try std.testing.expectEqual(7, ms.items(.b)[i]);
    }

    ms.memset(.{ .a = 0, .b = 255 });
    try std.testing.expectEqual(0, ms.items(.a)[0]);
    try std.testing.expectEqual(255, ms.items(.b)[0]);
}

test "memset bool field" {
    const Row = struct {
        a: bool,
        b: u8,
    };
    const MS = MultiSlice(Row);

    var ms = try MS.initCapacity(std.testing.allocator, 4);
    defer std.testing.allocator.free(@as([*]u8, @ptrCast(@alignCast(ms.ptrs[MS.sorted_fields[0]])))[0..MS.capacityInBytes(4)]);

    ms.len = 4;
    ms.memset(.{ .a = true, .b = 7 });

    for (0..4) |i| {
        try std.testing.expectEqual(true, ms.items(.a)[i]);
        try std.testing.expectEqual(7, ms.items(.b)[i]);
    }

    ms.memset(.{ .a = false, .b = 0 });
    try std.testing.expectEqual(false, ms.items(.a)[0]);
    try std.testing.expectEqual(0, ms.items(.b)[0]);
}

test "memset small int field" {
    const Row = struct {
        a: u3,
        b: u8,
    };
    const MS = MultiSlice(Row);

    var ms = try MS.initCapacity(std.testing.allocator, 4);
    defer std.testing.allocator.free(@as([*]u8, @ptrCast(@alignCast(ms.ptrs[MS.sorted_fields[0]])))[0..MS.capacityInBytes(4)]);

    ms.len = 4;
    ms.memset(.{ .a = 5, .b = 7 });

    for (0..4) |i| {
        try std.testing.expectEqual(@as(u3, 5), ms.items(.a)[i]);
        try std.testing.expectEqual(7, ms.items(.b)[i]);
    }

    ms.memset(.{ .a = 0, .b = 0 });
    try std.testing.expectEqual(@as(u3, 0), ms.items(.a)[0]);
}

test "memset small enum field" {
    const Color = enum(u2) { red, green, blue };
    const Row = struct {
        a: Color,
        b: u8,
    };
    const MS = MultiSlice(Row);

    var ms = try MS.initCapacity(std.testing.allocator, 4);
    defer std.testing.allocator.free(@as([*]u8, @ptrCast(@alignCast(ms.ptrs[MS.sorted_fields[0]])))[0..MS.capacityInBytes(4)]);

    ms.len = 4;
    ms.memset(.{ .a = .blue, .b = 7 });

    for (0..4) |i| {
        try std.testing.expectEqual(Color.blue, ms.items(.a)[i]);
        try std.testing.expectEqual(7, ms.items(.b)[i]);
    }

    ms.memset(.{ .a = .red, .b = 0 });
    try std.testing.expectEqual(Color.red, ms.items(.a)[0]);
}

test "memset small signed int field" {
    const Row = struct {
        a: i14,
        b: u8,
    };
    const MS = MultiSlice(Row);

    var ms = try MS.initCapacity(std.testing.allocator, 4);
    defer std.testing.allocator.free(@as([*]u8, @ptrCast(@alignCast(ms.ptrs[MS.sorted_fields[0]])))[0..MS.capacityInBytes(4)]);

    ms.len = 4;
    ms.memset(.{ .a = -7615, .b = 7 });

    for (0..4) |i| {
        try std.testing.expectEqual(@as(i14, -7615), ms.items(.a)[i]);
        try std.testing.expectEqual(7, ms.items(.b)[i]);
    }

    ms.memset(.{ .a = std.math.maxInt(i14), .b = 0 });
    try std.testing.expectEqual(@as(i14, std.math.maxInt(i14)), ms.items(.a)[0]);
}

test "memset packed struct field" {
    // Mirrors `storage.Shift` with `is_packed`, which is what packed shift
    // fields such as `case_folding_simple_only` become in a packed table.
    // See https://github.com/jacobsandlund/uucode/issues/55
    const Shift = packed struct { data: i14 };
    const Row = struct {
        a: Shift,
        b: u8,
    };
    const MS = MultiSlice(Row);

    var ms = try MS.initCapacity(std.testing.allocator, 4);
    defer std.testing.allocator.free(@as([*]u8, @ptrCast(@alignCast(ms.ptrs[MS.sorted_fields[0]])))[0..MS.capacityInBytes(4)]);

    ms.len = 4;
    ms.memset(.{ .a = .{ .data = std.math.maxInt(i14) }, .b = 7 });

    for (0..4) |i| {
        try std.testing.expectEqual(@as(i14, std.math.maxInt(i14)), ms.items(.a)[i].data);
        try std.testing.expectEqual(7, ms.items(.b)[i]);
    }

    ms.memset(.{ .a = .{ .data = -42 }, .b = 0 });
    try std.testing.expectEqual(@as(i14, -42), ms.items(.a)[0].data);
}

test "zero-field struct" {
    const Empty = struct {};
    const MS = MultiSlice(Empty);

    var ms = try MS.initCapacity(std.testing.allocator, 4);
    try std.testing.expectEqual(0, ms.len);

    ms.append(.{});
    try std.testing.expectEqual(1, ms.len);
}
