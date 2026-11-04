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
    boolean,
    bytes: ByteBounds,
    symbol,
    float64,
    error_value,
    target,
    pending_target,
    nothing,
    value,
    pending_value,
    list: *const List,
    tuple: *const Tuple,
    record: *const Record,
};

// Immutable graph nodes borrow the Model arena through emission.
pub const List = struct { element: Type, max_items: ?u64 = null };
pub const Tuple = struct { fields: []const Type };
pub const Record = struct { tag: []const u8, fields: []const Type };
