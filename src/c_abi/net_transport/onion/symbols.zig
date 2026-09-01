//! The annotated symbol inventory of `libpancake_net_transport_onion` — the
//! crossing semantics a language FFI table cannot reflect from the C signature
//! alone.
//!
//! Every export has a row here (in the TS table's reading order) or an omission
//! reason on its row. The generator holds this inventory and the export set to
//! each other in both directions at compile time.

const shared = @import("c_abi_shared");

pub const Symbol = shared.symbols.Symbol;
pub const OmittedFamily = shared.symbols.OmittedFamily;
const omit = shared.symbols.omit_reason;

pub const omitted_families = [_]OmittedFamily{};

pub const symbols = [_]Symbol{
    .{ .name = "pancake_onion_archive_fingerprint" },
    .{ .name = "pancake_onion_last_error", .out_params = &.{0} },
    .{ .name = "pancake_onion_transport_provider", .out_params = &.{1} },
    .{ .name = "pancake_onion_netlayer_new", .out_params = &.{1} },
    .{ .name = "pancake_onion_netlayer_shutdown" },
    .{
        .name = "pancake_onion_netlayer_release",
        .out_params = &.{ 1, 3 },
        .blocking = true,
        .nonblocking = true,
    },
    // Every row below reaches Tor, so each is both `blocking` (it may park the
    // calling OS thread) and `nonblocking` (a JS runtime must dispatch it off the
    // event loop). The second mark makes the TypeScript surface's Tor-reaching
    // methods async.
    //
    // Onion has no runtime-native Tor equivalent, so its ergonomic surface
    // dispatches these calls away from Deno's event loop. TCP and inproc use the
    // same rule for their raw native frame shuttles, while their high-level hosts
    // prefer runtime-native async transports.
    // Every release is a completion barrier and is dispatched off-thread:
    // netlayer release joins connect/listen tasks, connection release joins
    // frame I/O, and listener release joins accept before withdrawing the
    // undetached service.
    .{
        .name = "pancake_onion_connect",
        .out_params = &.{ 5, 6, 8 },
        .blocking = true,
        .nonblocking = true,
    },
    .{
        .name = "pancake_onion_listen",
        .out_params = &.{ 1, 3, 4, 6, 7, 8, 10 },
        .blocking = true,
        .nonblocking = true,
    },
    .{
        .name = "pancake_onion_listener_wait",
        .out_params = &.{ 2, 3, 5 },
        .blocking = true,
        .nonblocking = true,
    },
    // The readiness half: both return at once, so neither is blocking in either
    // sense. An embedder that polls these never reaches the blocking rows for the
    // arrival case, so the transport stays usable from an event loop.
    .{ .name = "pancake_onion_listener_readiness_fd", .out_params = &.{1} },
    .{ .name = "pancake_onion_conn_readiness_fd", .out_params = &.{1} },
    .{
        .name = "pancake_onion_accept",
        .out_params = &.{ 3, 4, 6 },
        .blocking = true,
        .nonblocking = true,
    },
    .{
        .name = "pancake_onion_conn_read_frame",
        .out_params = &.{ 1, 2, 4 },
        .blocking = true,
        .nonblocking = true,
    },
    .{
        .name = "pancake_onion_conn_write_frame",
        .out_params = &.{ 2, 4 },
        .blocking = true,
        .nonblocking = true,
    },
    .{ .name = "pancake_onion_conn_shutdown" },
    .{ .name = "pancake_onion_conn_release", .out_params = &.{ 1, 3 }, .blocking = true, .nonblocking = true },
    .{ .name = "pancake_onion_listener_shutdown" },
    .{
        .name = "pancake_onion_listener_release",
        .out_params = &.{ 1, 3 },
        .blocking = true,
        .nonblocking = true,
    },
    // The rows below are omitted from the TypeScript table, each for the reason
    // on its row.
    .{
        .name = "pancake_onion_clear_last_error",
        .ts_omit = omit.ts_last_error,
        .python_omit = omit.python_last_error,
        .racket_omit = omit.racket_last_error,
    },
    .{
        .name = "pancake_onion_netlayer_new_in",
        .ts_omit = omit.ts_transport_allocator,
        .python_omit = omit.python_transport_allocator,
        .racket_omit = omit.racket_transport_allocator,
    },
};
