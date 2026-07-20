//! The annotated symbol inventory of `libpancake_net_transport_inproc` — the
//! crossing semantics a language FFI table cannot reflect from the C
//! signature alone.
//!
//! Every export has a row here (in the TS table's reading order) or an
//! omission reason on its row. The generator holds this inventory and the
//! export set to each other in both directions at compile time.

const shared = @import("c_abi_shared");

pub const Symbol = shared.symbols.Symbol;
pub const OmittedFamily = shared.symbols.OmittedFamily;

pub const omitted_families = [_]OmittedFamily{};

pub const symbols = [_]Symbol{
    .{ .name = "pancake_inproc_last_error", .out_params = &.{0} },
    .{ .name = "pancake_inproc_netlayer_new", .out_params = &.{0} },
    .{ .name = "pancake_inproc_netlayer_release" },
    .{ .name = "pancake_inproc_connect", .out_params = &.{5}, .blocking = true },
    .{ .name = "pancake_inproc_listen", .out_params = &.{3} },
    .{ .name = "pancake_inproc_accept", .out_params = &.{3}, .blocking = true },
    .{ .name = "pancake_inproc_conn_read_frame", .out_params = &.{1}, .blocking = true },
    .{ .name = "pancake_inproc_conn_write_frame", .out_params = &.{}, .blocking = true },
    .{ .name = "pancake_inproc_conn_release" },
    .{ .name = "pancake_inproc_listener_release" },
    // The rows below are omitted from the TypeScript table, each for the
    // reason on its row.
    .{
        .name = "pancake_inproc_clear_last_error",
        .ts_omit = "unused: the TS binding reads the slot after a failing call and never resets it",
        .python_omit = "unused: the Python binding reads the slot after a failing call and never resets it",
        .racket_omit = "unused: the Racket binding reads the slot after a failing call and never resets it",
    },
    .{
        .name = "pancake_inproc_netlayer_new_in",
        .ts_omit = "unused: the TS binding keeps its transports on the library allocator",
        .python_omit = "unused: the Python binding keeps its transports on the library allocator",
        .racket_omit = "unused: the Racket binding keeps its transports on the library allocator",
    },
};
