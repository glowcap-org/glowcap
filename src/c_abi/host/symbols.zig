//! The annotated symbol inventory of `libglowcap_host`, with the crossing
//! semantics a language FFI table cannot reflect from the C signature alone.
//!
//! Every `glowcap_host_*` export has one row, in the header's canonical order.
//! The binding generators under `tools/gen/binding/` reflect each symbol's real
//! parameter and return types from its re-exports. They merge two facts only a
//! human can supply. One is which buffer parameters the callee *writes*
//! (`out_params`: the wasm boundary copies back only true outputs). The other
//! is the rare parameter that crosses as an opaque pointer even though its type
//! reflects as a writable slot (`pointer_params`).
//!
//! `archive_contract.fingerprint` holds this inventory and the export set to
//! each other in both directions at compile time. Each binding's omission
//! policy under `bindings/ffi_omissions/` chooses the rows its FFI table skips.

const shared = @import("c_abi_shared");

pub const Symbol = shared.symbols.Symbol;

pub const symbols = [_]Symbol{
    .{ .name = "glowcap_host_archive_fingerprint" },
    .{
        .name = "glowcap_host_new",
        .out_params = &.{9},
        .section = "Lifecycle. `outBuffers` marks the buffer params the callee writes, so\nthe wasm adapter copies back only true outputs (dlopen ignores it).",
    },
    .{
        .name = "glowcap_host_new_in",
        .out_params = &.{10},
    },
    .{ .name = "glowcap_host_diagnostic_id", .out_params = &.{1} },
    .{
        .name = "glowcap_host_release_on_drop",
        .out_params = &.{1},
    },
    .{
        .name = "glowcap_host_set_release_on_drop",
    },
    .{ .name = "glowcap_host_close" },
    .{ .name = "glowcap_host_close_progress", .out_params = &.{2} },
    .{ .name = "glowcap_host_close_wait_ms", .out_params = &.{2} },
    .{
        .name = "glowcap_host_lifecycle_state",
        .out_params = &.{1},
    },
    .{ .name = "glowcap_host_release" },
    .{ .name = "glowcap_host_designator_from_seed", .out_params = &.{2} },
    .{
        .name = "glowcap_host_set_advertised_locator",
        .out_params = &.{},
        .pointer_params = &.{1},
    },
    .{
        .name = "glowcap_host_ensure_advertised_locator",
        .out_params = &.{},
    },
    .{ .name = "glowcap_host_remove_advertised_locator", .out_params = &.{} },
    .{ .name = "glowcap_host_set_session_limits" },
    .{ .name = "glowcap_host_set_ingress_limits" },
    .{
        .name = "glowcap_host_session_open_dialed_locator",
        .out_params = &.{2},
        .pointer_params = &.{1},
    },
    .{ .name = "glowcap_host_session_open_accepted", .out_params = &.{8} },
    .{
        .name = "glowcap_host_plan_dial",
        .out_params = &.{8},
        .section = "Resolve a dial to a GlowcapDialPlan (grammar + hint + iroh posture); a free function.",
    },
    .{ .name = "glowcap_host_pending_dial", .out_params = &.{ 3, 5, 6 } },
    .{
        .name = "glowcap_host_pending_dial_introducer",
        .out_params = &.{3},
    },
    .{ .name = "glowcap_host_reference_exporter", .out_params = &.{2} },
    .{ .name = "glowcap_host_session_close" },
    .{ .name = "glowcap_host_session_close_progress", .out_params = &.{2} },
    .{
        .name = "glowcap_host_session_lifecycle_state",
        .out_params = &.{1},
    },
    .{ .name = "glowcap_host_session_release" },
    .{ .name = "glowcap_host_session_is_open" },
    .{ .name = "glowcap_host_session_profile", .out_params = &.{ 1, 2, 3 } },
    .{ .name = "glowcap_host_session_transport_name", .out_params = &.{ 1, 2 } },
    .{ .name = "glowcap_host_session_trace_id", .out_params = &.{1} },
    .{
        .name = "glowcap_host_session_feed",
        .out_params = &.{},
    },
    .{
        .name = "glowcap_host_session_feed_bytes",
        .out_params = &.{},
        .section = "The byte pump and action queue. The fed chunk (index 1) is input-only:\nthe annotation is what keeps the wasm boundary at one copy-in per feed\nwith no full-chunk copy-back.",
    },
    .{
        .name = "glowcap_host_session_feed_packet",
        .out_params = &.{},
    },
    .{
        .name = "glowcap_host_session_resume_feed",
        .out_params = &.{},
    },
    .{
        .name = "glowcap_host_session_take_packet",
        .out_params = &.{ 1, 2, 4 },
    },
    .{ .name = "glowcap_host_session_take_outbound", .out_params = &.{ 1, 2, 4 } },
    .{
        .name = "glowcap_host_next_action",
        .out_params = &.{1},
    },
    .{
        .name = "glowcap_host_pump_drain",
        .out_params = &.{ 2, 3 },
    },
    .{ .name = "glowcap_host_dialed", .out_params = &.{4} },
    .{ .name = "glowcap_host_dial_failed", .out_params = &.{} },
    .{ .name = "glowcap_host_dial_cancelled" },
    .{ .name = "glowcap_host_provide_gift_id", .out_params = &.{} },
    .{ .name = "glowcap_host_gift_id_failed" },
    .{
        .name = "glowcap_host_session_publish",
        .out_params = &.{6},
        .section = "Publish and spawn (behavior = the trampoline pointer, ctx = the JS\nregistry id packed as a pointer-sized integer, free = NULL).",
    },
    .{ .name = "glowcap_host_session_spawn", .out_params = &.{4} },
    .{ .name = "glowcap_host_publish", .out_params = &.{} },
    .{
        .name = "glowcap_host_spawn",
        .out_params = &.{4},
    },
    .{ .name = "glowcap_host_unpublish", .out_params = &.{} },
    .{ .name = "glowcap_host_publish_durable", .out_params = &.{6} },
    .{ .name = "glowcap_host_publish_reference", .out_params = &.{4} },
    .{ .name = "glowcap_host_remove_durable", .out_params = &.{} },
    .{
        .name = "glowcap_host_session_fetch",
        .out_params = &.{3},
        .section = "Fetch and enliven — each mints a host vow (out param).",
    },
    .{ .name = "glowcap_host_session_enliven", .out_params = &.{3} },
    .{ .name = "glowcap_host_enliven", .out_params = &.{3} },
    .{ .name = "glowcap_host_enliven_for_version", .out_params = &.{4} },
    .{ .name = "glowcap_host_fetch_at", .out_params = &.{4}, .pointer_params = &.{1} },
    .{
        .name = "glowcap_host_set_trace",
        .out_params = &.{},
        .section = "Live trace: the host reports session opens, message verbs, and closes\nthrough one callback (null clears), or into a ring the embedder drains.",
    },
    // The drained trace seam exists for an embedder that cannot hand the
    // library an arbitrary C function pointer: the browser, whose wasm module
    // admits only its fixed hosted-object callbacks. An embedder that can
    // install the trace callback, which is lossless, needs no ring.
    .{
        .name = "glowcap_host_set_trace_queue",
        .out_params = &.{},
    },
    .{
        .name = "glowcap_host_next_trace",
        .out_params = &.{1},
    },
    .{
        .name = "glowcap_host_resolver_fulfill",
        .out_params = &.{},
        .section = "Off-turn settlement: a behavior atomically defers its answer onto a fresh\nresolver vow and the work's completion settles it later, top-level.",
    },
    .{
        .name = "glowcap_host_resolver_fulfill_value",
        .out_params = &.{},
    },
    .{
        .name = "glowcap_host_resolver_break",
        .out_params = &.{},
    },
    .{ .name = "glowcap_host_resolver_abandon", .out_params = &.{} },
    .{ .name = "glowcap_host_session_listen", .out_params = &.{2} },
    .{
        .name = "glowcap_host_session_resolve",
        .out_params = &.{ 2, 3 },
    },
    .{
        .name = "glowcap_host_session_send",
        .out_params = &.{6},
        .section = "Send, tell, vows, projections.",
    },
    .{ .name = "glowcap_host_session_tell", .out_params = &.{} },
    .{
        .name = "glowcap_host_tell",
        .out_params = &.{},
    },
    .{
        .name = "glowcap_host_send",
        .out_params = &.{6},
    },
    .{ .name = "glowcap_host_vow_send", .out_params = &.{6} },
    .{ .name = "glowcap_host_vow_tell", .out_params = &.{} },
    .{ .name = "glowcap_host_vow_release", .out_params = &.{} },
    .{ .name = "glowcap_host_vow_capability", .out_params = &.{2} },
    .{ .name = "glowcap_host_vow_index", .out_params = &.{3} },
    .{ .name = "glowcap_host_vow_untag", .out_params = &.{4} },
    .{ .name = "glowcap_host_vow_get", .out_params = &.{4} },
    .{
        .name = "glowcap_host_turn_session",
        .out_params = &.{1},
    },
    .{
        .name = "glowcap_host_turn_forward",
        .out_params = &.{},
        .pointer_params = &.{6},
        .section = "Turn verbs (legal only inside a behavior callback). `turn_forward`'s\nout-reply is the raw pointer the trampoline was handed, so it crosses as\na pointer, not a JS buffer.",
    },
    .{
        .name = "glowcap_host_turn_send",
        .out_params = &.{6},
    },
    .{
        .name = "glowcap_host_turn_tell",
        .out_params = &.{},
    },
    .{ .name = "glowcap_host_turn_defer", .out_params = &.{1} },
    .{
        .name = "glowcap_host_turn_defer_if_answer",
        .out_params = &.{1},
    },
    .{ .name = "glowcap_host_turn_spawn", .out_params = &.{4} },
    .{ .name = "glowcap_host_turn_break", .out_params = &.{} },
    .{
        .name = "glowcap_host_ref_retain",
        .out_params = &.{2},
        .section = "Capability lifetime, teardown, diagnostics.",
    },
    .{ .name = "glowcap_host_ref_release" },
    .{ .name = "glowcap_host_session_published_ref", .out_params = &.{3} },
    .{
        .name = "glowcap_host_session_break_far_vows",
        .out_params = &.{},
    },
    .{ .name = "glowcap_host_session_transport_closed", .out_params = &.{} },
    .{
        .name = "glowcap_host_session_set_exporter_location",
        .out_params = &.{},
        .pointer_params = &.{1},
    },
    .{ .name = "glowcap_host_session_last_abort", .out_params = &.{1} },
    .{
        .name = "glowcap_host_session_partner_abort",
        .out_params = &.{ 1, 2, 3, 5 },
    },
    .{ .name = "glowcap_host_session_partner_identity", .out_params = &.{1} },
    .{ .name = "glowcap_host_session_bind_verified_channel_key", .out_params = &.{} },
    .{ .name = "glowcap_host_last_error", .out_params = &.{0} },
    .{
        .name = "glowcap_host_clear_last_error",
    },
};
