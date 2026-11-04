//! Checked ordinary-call types. Constraints travel with their value category.
//! An absent integer endpoint is unbounded, never an implicit machine limit.
pub const IntegerBounds = struct {
    min: ?i64 = null,
    max: ?i64 = null,
};
pub const ByteBounds = struct {
    min: u64 = 0,
    max: ?u64 = null,
};
pub const Type = union(enum) {
    text: ByteBounds,
    integer: IntegerBounds,
    target,
    pending_target,
    nothing,
    value,
    pending_value,
};
