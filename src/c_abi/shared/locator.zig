//! C-stable borrowed OCapN locator vocabulary.
//!
//! OCapN owns locator values and the `glowcap_locator_*` handle API. This leaf
//! owns only the layout that lets independently linked archives borrow the
//! same value without sharing symbols or allocation ownership.

pub const GLOWCAP_LOCATOR_VIEW_ABI_VERSION: u32 = 1;
pub const GLOWCAP_HINT_STRING: u32 = 1;
pub const GLOWCAP_HINT_BYTES: u32 = 2;
pub const GLOWCAP_HINT_BOOLEAN: u32 = 3;
pub const GLOWCAP_HINT_INTEGER: u32 = 4;
pub const GLOWCAP_HINTS_MAP: u32 = 0;
pub const GLOWCAP_HINTS_BOOLEAN_FALSE: u32 = 1;

pub const GlowcapLocatorHintView = extern struct {
    name: ?[*]const u8,
    name_len: usize,
    kind: u32,
    bytes: ?[*]const u8,
    bytes_len: usize,
    boolean_value: u8,
    integer_value: i64,
};

pub const GlowcapLocatorView = extern struct {
    abi_version: u32,
    struct_size: usize,
    transport: ?[*]const u8,
    transport_len: usize,
    designator: ?[*]const u8,
    designator_len: usize,
    hints: ?[*]const GlowcapLocatorHintView,
    hint_count: usize,
    hint_wire_form: u32,
};

/// Consume one callback-scoped locator view. A producer calls the sink before
/// returning. The sink must copy anything it keeps.
pub const GlowcapLocatorSinkFn = *const fn (
    sink_ctx: ?*anyopaque,
    locator: ?*const GlowcapLocatorView,
) callconv(.c) i32;
