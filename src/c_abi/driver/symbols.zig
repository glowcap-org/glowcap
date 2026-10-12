//! The annotated symbol inventory of `libglowcap_driver`'s own
//! `glowcap_driver_*` family: the crossing semantics a language FFI table
//! cannot reflect from the C signature alone. Host and transport archives
//! keep their own inventories. One family, one table.
//!
//! Rows are in the header's canonical order. `blocking` marks the verbs that
//! may park the calling thread (a positive-timeout step or provider listener
//! bind), which a runtime with a blocking-call escape (Racket futures, a
//! worker thread) routes accordingly. Dial starts are nonblocking by provider
//! contract. Connect completion and handshakes advance through later steps.

const shared = @import("c_abi_shared");

pub const Symbol = shared.symbols.Symbol;
pub const OmittedFamily = shared.symbols.OmittedFamily;

pub const omitted_families = [_]OmittedFamily{};

pub const symbols = [_]Symbol{
    .{ .name = "glowcap_driver_archive_fingerprint" },
    .{
        .name = "glowcap_driver_take_host",
        .out_params = &.{2},
        .pointer_params = &.{1},
        .section = "Lifecycle.",
    },
    .{ .name = "glowcap_driver_close" },
    .{ .name = "glowcap_driver_retire" },
    .{ .name = "glowcap_driver_lifecycle_state", .out_params = &.{1} },
    .{ .name = "glowcap_driver_step_wait_ms", .out_params = &.{1} },
    // Not `blocking`, like `glowcap_host_release`: trace callbacks fire for
    // every session the teardown closes, and a deactivated-thread mark would
    // make each a non-async re-entry.
    .{ .name = "glowcap_driver_release" },
    .{
        .name = "glowcap_driver_add_provider",
        .pointer_params = &.{1},
        .section = "Transport providers.",
    },
    .{ .name = "glowcap_driver_has_transport", .out_params = &.{3} },
    .{
        .name = "glowcap_driver_dial",
        .out_params = &.{3},
        .pointer_params = &.{1},
        .section = "Dial, listen, readiness.",
    },
    .{
        .name = "glowcap_driver_adopt_external",
        .out_params = &.{5},
        .section = "Dial, listen, readiness.",
    },
    .{ .name = "glowcap_driver_listen", .out_params = &.{6}, .blocking = true },
    .{ .name = "glowcap_driver_listener_locator", .out_params = &.{2} },
    .{ .name = "glowcap_driver_listener_restoration_state", .out_params = &.{ 2, 4 } },
    .{ .name = "glowcap_driver_listener_advertise", .pointer_params = &.{2} },
    .{ .name = "glowcap_driver_listener_select" },
    .{ .name = "glowcap_driver_listener_close" },
    .{ .name = "glowcap_driver_readiness_fd", .out_params = &.{1} },
    .{
        // Not `blocking`, for `glowcap_host_session_feed_bytes`'s reason:
        // behavior callbacks fire inside a step, and a deactivated-thread
        // mark would turn every one into a non-async re-entry. A
        // zero-timeout step never parks; a runtime that parks in a
        // positive-timeout step routes it to a worker thread it owns.
        .name = "glowcap_driver_step",
        .section = "Step, wake, events.",
    },
    .{ .name = "glowcap_driver_detach_thread" },
    .{ .name = "glowcap_driver_wake", .nonblocking = true },
    .{ .name = "glowcap_driver_next_event", .out_params = &.{1} },
    .{ .name = "glowcap_driver_claim_reference_exporter", .out_params = &.{2} },
    .{ .name = "glowcap_driver_claim_exporter_session" },
    // Not `blocking`, like `glowcap_host_session_release`: the close emits
    // trace callbacks on the calling thread.
    .{ .name = "glowcap_driver_session_close" },
    .{ .name = "glowcap_driver_session_lifecycle_state", .out_params = &.{2} },
    .{ .name = "glowcap_driver_session_serve" },
    .{ .name = "glowcap_driver_session_release" },
    .{
        .name = "glowcap_driver_last_error",
        .out_params = &.{0},
        .section = "Last error.",
    },
    .{ .name = "glowcap_driver_clear_last_error" },
};
