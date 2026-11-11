//! The annotated symbol inventory of `libglowcap_net_transport_tcp`: the
//! crossing semantics a language FFI table cannot reflect from the C
//! signature alone.
//!
//! Every export has one row here, in the TS table's reading order.
//! `archive_contract.fingerprint` holds this inventory and the export set to
//! each other in both directions at compile time.

const shared = @import("c_abi_shared");

pub const Symbol = shared.symbols.Symbol;

pub const symbols = [_]Symbol{
    .{ .name = "glowcap_tcp_archive_fingerprint" },
    .{ .name = "glowcap_tcp_last_error", .out_params = &.{0} },
    .{ .name = "glowcap_tcp_netlayer_new", .out_params = &.{1} },
    .{ .name = "glowcap_tcp_transport_provider", .out_params = &.{1} },
    .{ .name = "glowcap_tcp_netlayer_shutdown" },
    .{ .name = "glowcap_tcp_netlayer_release", .blocking = true, .nonblocking = true },
    .{
        .name = "glowcap_tcp_connect",
        .out_params = &.{ 7, 8, 10 },
        .blocking = true,
        .nonblocking = true,
    },
    .{ .name = "glowcap_tcp_listen", .out_params = &.{4} },
    .{ .name = "glowcap_tcp_listener_port", .out_params = &.{1} },
    .{ .name = "glowcap_tcp_listener_readiness_fd", .out_params = &.{1} },
    .{
        .name = "glowcap_tcp_accept",
        .out_params = &.{ 4, 5, 7 },
        .blocking = true,
        .nonblocking = true,
    },
    .{
        .name = "glowcap_tcp_conn_read_frame",
        .out_params = &.{ 1, 2, 4 },
        .blocking = true,
        .nonblocking = true,
    },
    .{
        .name = "glowcap_tcp_conn_write_frame",
        .out_params = &.{ 2, 4 },
        .blocking = true,
        .nonblocking = true,
    },
    .{ .name = "glowcap_tcp_conn_shutdown" },
    .{ .name = "glowcap_tcp_conn_release", .out_params = &.{ 1, 3 }, .blocking = true, .nonblocking = true },
    .{ .name = "glowcap_tcp_listener_shutdown" },
    .{ .name = "glowcap_tcp_listener_release", .blocking = true, .nonblocking = true },
    .{
        .name = "glowcap_tcp_clear_last_error",
    },
    .{
        .name = "glowcap_tcp_netlayer_new_in",
    },
};
