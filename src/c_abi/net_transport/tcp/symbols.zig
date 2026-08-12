//! The annotated symbol inventory of `libpancake_net_transport_tcp` — the
//! crossing semantics a language FFI table cannot reflect from the C
//! signature alone.
//!
//! Every export has a row here (in the TS table's reading order) or a binding-
//! specific omission reason on its row. The generator holds this inventory and
//! the export set to each other in both directions at compile time.

const shared = @import("c_abi_shared");

pub const Symbol = shared.symbols.Symbol;
pub const omitted_families = [_]shared.symbols.OmittedFamily{};

pub const symbols = [_]Symbol{
    .{ .name = "pancake_tcp_last_error", .out_params = &.{0} },
    .{ .name = "pancake_tcp_netlayer_new", .out_params = &.{0} },
    .{ .name = "pancake_tcp_transport_provider", .out_params = &.{1} },
    .{ .name = "pancake_tcp_netlayer_shutdown" },
    .{ .name = "pancake_tcp_netlayer_release", .blocking = true, .nonblocking = true },
    .{
        .name = "pancake_tcp_connect",
        .out_params = &.{6},
        .blocking = true,
        .nonblocking = true,
        .ts_omit = shared.symbols.diagnosed.ts_uses_companion,
    },
    .{
        .name = "pancake_tcp_connect_with_diagnostic",
        .out_params = &.{ 6, 7, 9 },
        .blocking = true,
        .nonblocking = true,
        .rust_omit = shared.symbols.diagnosed.rust_uses_tls,
        .python_omit = shared.symbols.diagnosed.python_uses_tls,
        .racket_omit = shared.symbols.diagnosed.racket_uses_tls,
    },
    .{ .name = "pancake_tcp_listen", .out_params = &.{4} },
    .{ .name = "pancake_tcp_listener_port", .out_params = &.{1} },
    .{ .name = "pancake_tcp_listener_readiness_fd", .out_params = &.{1} },
    .{
        .name = "pancake_tcp_accept",
        .out_params = &.{3},
        .blocking = true,
        .nonblocking = true,
        .ts_omit = shared.symbols.diagnosed.ts_uses_companion,
    },
    .{
        .name = "pancake_tcp_accept_with_diagnostic",
        .out_params = &.{ 3, 4, 6 },
        .blocking = true,
        .nonblocking = true,
        .rust_omit = shared.symbols.diagnosed.rust_uses_tls,
        .python_omit = shared.symbols.diagnosed.python_uses_tls,
        .racket_omit = shared.symbols.diagnosed.racket_uses_tls,
    },
    .{
        .name = "pancake_tcp_conn_read_frame",
        .out_params = &.{1},
        .blocking = true,
        .nonblocking = true,
        .ts_omit = shared.symbols.diagnosed.ts_uses_companion,
    },
    .{
        .name = "pancake_tcp_conn_read_frame_with_diagnostic",
        .out_params = &.{ 1, 2, 4 },
        .blocking = true,
        .nonblocking = true,
        .rust_omit = shared.symbols.diagnosed.rust_uses_tls,
        .python_omit = shared.symbols.diagnosed.python_uses_tls,
        .racket_omit = shared.symbols.diagnosed.racket_uses_tls,
    },
    .{
        .name = "pancake_tcp_conn_write_frame",
        .out_params = &.{},
        .blocking = true,
        .nonblocking = true,
        .ts_omit = shared.symbols.diagnosed.ts_uses_companion,
    },
    .{
        .name = "pancake_tcp_conn_write_frame_with_diagnostic",
        .out_params = &.{ 2, 4 },
        .blocking = true,
        .nonblocking = true,
        .rust_omit = shared.symbols.diagnosed.rust_uses_tls,
        .python_omit = shared.symbols.diagnosed.python_uses_tls,
        .racket_omit = shared.symbols.diagnosed.racket_uses_tls,
    },
    .{ .name = "pancake_tcp_conn_shutdown" },
    .{ .name = "pancake_tcp_conn_release", .blocking = true, .nonblocking = true },
    .{ .name = "pancake_tcp_listener_shutdown" },
    .{ .name = "pancake_tcp_listener_release", .blocking = true, .nonblocking = true },
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
};
