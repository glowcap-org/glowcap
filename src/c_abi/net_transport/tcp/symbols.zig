//! The annotated symbol inventory of `libpancake_net_transport_tcp` — the
//! crossing semantics a language FFI table cannot reflect from the C
//! signature alone.
//!
//! Every export either has a row here (in the TS table's reading order), an
//! omission reason on its row, or a family-level omission below. The owning
//! one-call session family (`pancake_tcp_session_*`) is the whole family
//! every binding table omits: bindings drive sessions through the byte-fed
//! host archive, and that family is the C consumer's surface. The generator
//! holds this inventory and the export set to each other in both directions
//! at compile time.

const shared = @import("c_abi_shared");

pub const Symbol = shared.symbols.Symbol;
pub const OmittedFamily = shared.symbols.OmittedFamily;

pub const omitted_families = [_]OmittedFamily{
    .{
        .prefix = "pancake_tcp_session_",
        .reason = "the owning one-call C session surface is the C consumer's; bindings drive sessions through the byte-fed host archive",
    },
};

pub const symbols = [_]Symbol{
    .{ .name = "pancake_tcp_last_error", .out_params = &.{0} },
    .{ .name = "pancake_tcp_netlayer_new", .out_params = &.{0} },
    .{ .name = "pancake_tcp_netlayer_release" },
    .{ .name = "pancake_tcp_connect", .out_params = &.{6}, .blocking = true },
    .{ .name = "pancake_tcp_listen", .out_params = &.{4} },
    .{ .name = "pancake_tcp_listener_port", .out_params = &.{1} },
    .{ .name = "pancake_tcp_accept", .out_params = &.{3}, .blocking = true },
    .{ .name = "pancake_tcp_conn_read_frame", .out_params = &.{1}, .blocking = true },
    .{ .name = "pancake_tcp_conn_write_frame", .out_params = &.{}, .blocking = true },
    .{ .name = "pancake_tcp_conn_release" },
    .{ .name = "pancake_tcp_listener_release" },
    // The rows below are omitted from the TypeScript table, each for the
    // reason on its row.
    .{
        .name = "pancake_tcp_clear_last_error",
        .ts_omit = "unused: the TS binding reads the slot after a failing call and never resets it",
        .python_omit = "unused: the Python binding reads the slot after a failing call and never resets it",
        .racket_omit = "unused: the Racket binding reads the slot after a failing call and never resets it",
    },
    .{
        .name = "pancake_tcp_netlayer_new_in",
        .ts_omit = "unused: the TS binding keeps its transports on the library allocator",
        .python_omit = "unused: the Python binding keeps its transports on the library allocator",
        .racket_omit = "unused: the Racket binding keeps its transports on the library allocator",
    },
    .{
        .name = "pancake_tcp_promise_release",
        .ts_omit = "companion of the owning session family, which TS does not drive",
        .rust_omit = "companion of the owning session family, which the Rust binding does not drive",
        .python_omit = "companion of the owning session family, which the Python binding does not drive",
        .racket_omit = "companion of the owning session family, which the Racket binding does not drive",
    },
    .{
        .name = "pancake_tcp_settled_release",
        .ts_omit = "companion of the owning session family, which TS does not drive",
        .rust_omit = "companion of the owning session family, which the Rust binding does not drive",
        .python_omit = "companion of the owning session family, which the Python binding does not drive",
        .racket_omit = "companion of the owning session family, which the Racket binding does not drive",
    },
};
