//! The annotated symbol inventory of `libglowcap_net_transport_inproc`, the
//! crossing semantics a language FFI table cannot reflect from the C
//! signature alone.
//!
//! Every export has one row here, in the TS table's reading order.
//! `archive_contract.fingerprint` holds this inventory and the export set to
//! each other in both directions at compile time.

const shared = @import("c_abi_shared");

pub const Symbol = shared.symbols.Symbol;

pub const symbols = [_]Symbol{
    .{ .name = "glowcap_inproc_archive_fingerprint" },
    .{ .name = "glowcap_inproc_last_error", .out_params = &.{0} },
    .{ .name = "glowcap_inproc_netlayer_new", .out_params = &.{0} },
    .{ .name = "glowcap_inproc_netlayer_release", .blocking = true, .nonblocking = true },
    .{
        .name = "glowcap_inproc_connect",
        .out_params = &.{ 5, 6, 8 },
        .nonblocking = true,
    },
    .{ .name = "glowcap_inproc_listen", .out_params = &.{3} },
    .{ .name = "glowcap_inproc_listener_readiness_fd", .out_params = &.{1} },
    .{
        .name = "glowcap_inproc_accept",
        .out_params = &.{ 3, 4, 6 },
        .blocking = true,
        .nonblocking = true,
    },
    .{
        .name = "glowcap_inproc_conn_read_frame",
        .out_params = &.{ 1, 2, 4 },
        .blocking = true,
        .nonblocking = true,
    },
    .{
        .name = "glowcap_inproc_conn_write_frame",
        .out_params = &.{ 2, 4 },
        .blocking = true,
        .nonblocking = true,
    },
    .{ .name = "glowcap_inproc_conn_shutdown" },
    .{ .name = "glowcap_inproc_conn_release", .blocking = true, .nonblocking = true },
    .{ .name = "glowcap_inproc_listener_shutdown" },
    .{
        .name = "glowcap_inproc_listener_release",
        .out_params = &.{ 1, 3 },
        .blocking = true,
        .nonblocking = true,
    },
    .{
        .name = "glowcap_inproc_clear_last_error",
    },
    .{
        .name = "glowcap_inproc_netlayer_new_in",
    },
};
