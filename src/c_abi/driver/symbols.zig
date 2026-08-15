//! The annotated symbol inventory of `libpancake_driver`'s own
//! `pancake_driver_*` family — the crossing semantics a language FFI table
//! cannot reflect from the C signature alone. Host and transport archives
//! keep their own inventories; one family, one table.
//!
//! Rows are in the header's canonical order. `blocking` marks the verbs that
//! may park the calling thread (a positive-timeout step or provider listener
//! bind), which a runtime with a blocking-call escape (Racket futures, a
//! worker thread) routes accordingly. Dial starts are nonblocking by provider
//! contract; connect completion and handshakes advance through later steps.

const shared = @import("c_abi_shared");

pub const Symbol = shared.symbols.Symbol;
pub const OmittedFamily = shared.symbols.OmittedFamily;

pub const omitted_families = [_]OmittedFamily{};

pub const symbols = [_]Symbol{
    .{
        .name = "pancake_driver_take_host",
        .out_params = &.{2},
        .pointer_params = &.{1},
        .section = "Lifecycle.",
    },
    .{ .name = "pancake_driver_close" },
    .{ .name = "pancake_driver_retire" },
    .{ .name = "pancake_driver_lifecycle_state", .out_params = &.{1} },
    .{ .name = "pancake_driver_step_wait_ms", .out_params = &.{1} },
    // Not `blocking`, like `pancake_host_release`: trace callbacks fire for
    // every session the teardown closes, and a deactivated-thread mark would
    // make each a non-async re-entry.
    .{ .name = "pancake_driver_release" },
    .{
        .name = "pancake_driver_add_provider",
        .pointer_params = &.{1},
        .section = "Transport providers.",
    },
    .{ .name = "pancake_driver_has_transport", .out_params = &.{3} },
    .{
        .name = "pancake_driver_dial",
        .out_params = &.{3},
        .pointer_params = &.{1},
        .section = "Dial, listen, readiness.",
    },
    .{
        .name = "pancake_driver_adopt_external",
        .out_params = &.{5},
        .section = "Dial, listen, readiness.",
    },
    .{ .name = "pancake_driver_listen", .out_params = &.{6}, .blocking = true },
    .{ .name = "pancake_driver_listener_locator", .out_params = &.{2} },
    .{ .name = "pancake_driver_listener_restoration_state", .out_params = &.{ 2, 4 } },
    .{ .name = "pancake_driver_listener_advertise", .pointer_params = &.{2} },
    .{ .name = "pancake_driver_listener_select" },
    .{ .name = "pancake_driver_listener_close" },
    .{ .name = "pancake_driver_readiness_fd", .out_params = &.{1} },
    .{
        // Not `blocking`, for `pancake_host_session_feed_bytes`'s reason:
        // behavior callbacks fire inside a step, and a deactivated-thread
        // mark would turn every one into a non-async re-entry. A
        // zero-timeout step never parks; a runtime that parks in a
        // positive-timeout step routes it to a worker thread it owns.
        .name = "pancake_driver_step",
        .section = "Step, wake, events.",
    },
    .{ .name = "pancake_driver_detach_thread" },
    .{ .name = "pancake_driver_wake", .nonblocking = true },
    .{ .name = "pancake_driver_next_event", .out_params = &.{1} },
    .{ .name = "pancake_driver_claim_reference_exporter", .out_params = &.{2} },
    // Not `blocking`, like `pancake_host_session_release`: the close emits
    // trace callbacks on the calling thread.
    .{ .name = "pancake_driver_session_close" },
    .{ .name = "pancake_driver_session_lifecycle_state", .out_params = &.{2} },
    .{ .name = "pancake_driver_session_serve" },
    .{ .name = "pancake_driver_session_release" },
    .{
        .name = "pancake_driver_last_error",
        .out_params = &.{0},
        .section = "Last error.",
    },
    .{ .name = "pancake_driver_clear_last_error" },
};
