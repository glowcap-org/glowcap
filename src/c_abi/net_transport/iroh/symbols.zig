//! The annotated symbol inventory of `libpancake_net_transport_iroh` — the
//! crossing semantics a language FFI table cannot reflect from the C
//! signature alone.
//!
//! Every export has a row here (in the TS loader's reading order) or an
//! omission reason on its row. Every call returns immediately; outbound dial
//! completion is correlated by request id through the readiness stream.

const shared = @import("c_abi_shared");

pub const Symbol = shared.symbols.Symbol;
pub const OmittedFamily = shared.symbols.OmittedFamily;

pub const omitted_families = [_]OmittedFamily{};

pub const symbols = [_]Symbol{
    .{ .name = "pancake_iroh_last_error", .out_params = &.{0} },
    .{ .name = "pancake_iroh_netlayer_new", .out_params = &.{3} },
    .{ .name = "pancake_iroh_netlayer_close" },
    .{ .name = "pancake_iroh_netlayer_release" },
    .{ .name = "pancake_iroh_netlayer_node_id", .out_params = &.{ 1, 3 } },
    .{ .name = "pancake_iroh_netlayer_direct_addrs", .out_params = &.{ 1, 3 } },
    .{ .name = "pancake_iroh_conn_release" },
    .{ .name = "pancake_iroh_conn_id" },
    .{ .name = "pancake_iroh_conn_remote_node_id", .out_params = &.{ 1, 3 } },
    .{
        .name = "pancake_iroh_netlayer_readiness_fd",
        .section = "The event-driven loop surface: the netlayer's one I/O model.\n`readiness_fd` hands back the endpoint's single OS readiness fd, which the\nevent loop parks on (a `node:net` Socket over a dup of it); `drain_ready`,\nconnect lifecycle, and the `try_*` calls all return immediately.",
    },
    .{ .name = "pancake_iroh_netlayer_drain_ready", .out_params = &.{ 1, 3 } },
    .{ .name = "pancake_iroh_netlayer_try_accept", .out_params = &.{1} },
    .{ .name = "pancake_iroh_netlayer_start_connect" },
    .{ .name = "pancake_iroh_netlayer_finish_connect", .out_params = &.{2} },
    .{ .name = "pancake_iroh_netlayer_cancel_connect" },
    .{ .name = "pancake_iroh_conn_try_read", .out_params = &.{ 1, 3 } },
    .{ .name = "pancake_iroh_conn_try_write", .out_params = &.{3} },
    // The rows below are omitted from the TypeScript loader, each for the
    // reason on its row.
    .{
        .name = "pancake_iroh_clear_last_error",
        .ts_omit = "unused: the TS binding reads the slot after a failing call and never resets it",
        .python_omit = "unused: the Python binding reads the slot after a failing call and never resets it",
        .racket_omit = "unused: the Racket binding reads the slot after a failing call and never resets it",
    },
    .{
        .name = "pancake_iroh_netlayer_new_in",
        .ts_omit = "unused: the TS binding keeps its transports on the library allocator",
        .rust_omit = "unused: the Rust binding keeps its transports on the library allocator",
        .python_omit = "unused: the Python binding keeps its transports on the library allocator",
        .racket_omit = "unused: the Racket binding keeps its transports on the library allocator",
    },
};
