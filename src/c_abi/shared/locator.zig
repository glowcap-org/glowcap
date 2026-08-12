//! C-stable borrowed OCapN locator vocabulary.
//!
//! OCapN owns locator values and the `pancake_locator_*` handle API. This leaf
//! owns only the layout that lets independently linked archives borrow the
//! same value without sharing symbols or allocation ownership.

pub const PANCAKE_LOCATOR_VIEW_ABI_VERSION: u32 = 1;
pub const PANCAKE_HINT_STRING: u32 = 1;
pub const PANCAKE_HINT_BYTES: u32 = 2;
pub const PANCAKE_HINT_BOOLEAN: u32 = 3;
pub const PANCAKE_HINT_INTEGER: u32 = 4;
pub const PANCAKE_HINTS_MAP: u32 = 0;
pub const PANCAKE_HINTS_BOOLEAN_FALSE: u32 = 1;

pub const PancakeLocatorHintView = extern struct {
    name: ?[*]const u8,
    name_len: usize,
    kind: u32,
    bytes: ?[*]const u8,
    bytes_len: usize,
    boolean_value: u8,
    integer_value: i64,
};

pub const PancakeLocatorView = extern struct {
    abi_version: u32,
    struct_size: usize,
    transport: ?[*]const u8,
    transport_len: usize,
    designator: ?[*]const u8,
    designator_len: usize,
    hints: ?[*]const PancakeLocatorHintView,
    hint_count: usize,
    hint_wire_form: u32,
};

/// Consume one callback-scoped locator view. A producer calls the sink before
/// returning; the sink must copy anything it keeps.
pub const PancakeLocatorSinkFn = *const fn (
    sink_ctx: ?*anyopaque,
    locator: ?*const PancakeLocatorView,
) callconv(.c) i32;
