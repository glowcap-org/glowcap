//! Bounded copying between plain actor messages and owning Host values.
const std = @import("std");
const driver = @import("driver_core");
const AllocationBound = @import("call_memory.zig").AllocationBound;

/// Values counts roots and every descendant, including struct values. Keys
/// count separately in struct_entries. Bytes sums every copied leaf occurrence,
/// including keys, tags, digits and error text. Capabilities counts occurrences.
pub const Bounds = struct {
    values: usize = 0,
    struct_entries: usize = 0,
    bytes: usize = 0,
    capabilities: usize = 0,

    pub fn validate(self: Bounds) !void {
        if (self.struct_entries > self.values or self.capabilities > self.values or
            (self.values == 0 and self.bytes != 0)) return error.InvalidArguments;
    }
};

/// Every container element is one counted value or struct entry. Positive
/// child-spine requests cannot exceed those totals. Root arrays are included.
/// The owning C reply conversion uses one even for a scalar result.
pub fn allocationBound(comptime To: type, shape: Bounds) !AllocationBound {
    try shape.validate();
    var bound: AllocationBound = .{};
    try bound.includeTotal(try std.math.mul(usize, shape.values, @sizeOf(To)), @alignOf(To), shape.values);
    const Entry = std.meta.Elem(@FieldType(To, "struct"));
    try bound.includeTotal(try std.math.mul(usize, shape.struct_entries, @sizeOf(Entry)), @alignOf(Entry), shape.struct_entries);
    try bound.includeTotal(shape.bytes, 1, try std.math.add(usize, shape.values, shape.struct_entries));
    return bound;
}

pub fn copy(comptime To: type, allocator: std.mem.Allocator, value: anytype) !To {
    return driver.copyValue(To, allocator, value) catch |err|
        if (err == error.UnsupportedValue) error.NotDurable else err;
}
