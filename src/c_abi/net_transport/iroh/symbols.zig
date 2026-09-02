//! The annotated symbol inventory of `libglowcap_net_transport_iroh` — the
//! crossing semantics a language FFI table cannot reflect from the C
//! signature alone.
//!
//! Every export has a row here (in the TS loader's reading order) or an
//! omission reason on its row. The steady-state loop surface returns
//! immediately; endpoint construction and graceful teardown may wait on the
//! sidecar runtime and are marked for host runtimes accordingly. Outbound dial
//! completion is correlated by request id through the readiness stream.

const shared = @import("c_abi_shared");

pub const Symbol = shared.symbols.Symbol;
pub const OmittedFamily = shared.symbols.OmittedFamily;
const omit = shared.symbols.omit_reason;

pub const omitted_families = [_]OmittedFamily{};

pub const symbols = [_]Symbol{
    .{ .name = "glowcap_iroh_archive_fingerprint" },
    .{ .name = "glowcap_iroh_last_error", .out_params = &.{0} },
    .{
        .name = "glowcap_iroh_netlayer_new",
        .out_params = &.{ 3, 4, 6 },
        .nonblocking = true,
        .blocking = true,
    },
    .{ .name = "glowcap_iroh_netlayer_close", .nonblocking = true, .blocking = true },
    .{
        .name = "glowcap_iroh_netlayer_release",
        .out_params = &.{ 1, 3 },
        .nonblocking = true,
        .blocking = true,
    },
    .{ .name = "glowcap_iroh_netlayer_node_id", .out_params = &.{ 1, 3 } },
    .{ .name = "glowcap_iroh_netlayer_direct_addrs", .out_params = &.{ 1, 3 } },
    .{ .name = "glowcap_iroh_conn_release" },
    .{ .name = "glowcap_iroh_conn_id" },
    .{ .name = "glowcap_iroh_conn_remote_node_id", .out_params = &.{ 1, 3 } },
    .{
        .name = "glowcap_iroh_netlayer_readiness_fd",
        .section = "The event-driven loop surface: the netlayer's one I/O model.\n`readiness_fd` hands back the endpoint's single OS readiness fd, which the\nevent loop parks on (a `node:net` Socket over a dup of it); `drain_ready`,\nconnect lifecycle, and the `try_*` calls all return immediately.",
    },
    .{ .name = "glowcap_iroh_netlayer_drain_ready", .out_params = &.{ 1, 3 } },
    .{ .name = "glowcap_iroh_netlayer_try_accept", .out_params = &.{1} },
    .{ .name = "glowcap_iroh_netlayer_start_connect" },
    .{ .name = "glowcap_iroh_netlayer_finish_connect", .out_params = &.{2} },
    .{ .name = "glowcap_iroh_netlayer_cancel_connect" },
    .{ .name = "glowcap_iroh_conn_try_read", .out_params = &.{ 1, 3 } },
    .{ .name = "glowcap_iroh_conn_try_write", .out_params = &.{3} },
    .{ .name = "glowcap_iroh_transport_provider", .out_params = &.{1} },
    // The rows below are omitted from the TypeScript loader, each for the
    // reason on its row.
    .{
        .name = "glowcap_iroh_clear_last_error",
        .ts_omit = omit.ts_last_error,
        .python_omit = omit.python_last_error,
        .racket_omit = omit.racket_last_error,
    },
    .{
        .name = "glowcap_iroh_netlayer_new_in",
        .out_params = &.{ 4, 5, 7 },
        .nonblocking = true,
        .blocking = true,
        .rust_omit = omit.rust_transport_allocator,
        .python_omit = omit.python_transport_allocator,
        .racket_omit = omit.racket_transport_allocator,
    },
};
