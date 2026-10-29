//! The annotated symbol inventory of `libglowcap_host`, the crossing
//! semantics a language FFI table cannot reflect from the C signature alone.
//!
//! Every `glowcap_host_*` export has one row here, in the header's canonical
//! order. The binding generators under `tools/gen/binding/` reflect each
//! symbol's real parameter and return types from this module's re-exports and
//! merge the two facts only a human can supply: which buffer parameters the
//! callee *writes* (`out_params`: the wasm boundary copies back only true
//! outputs), and the rare parameter that crosses as an opaque pointer even
//! though its type reflects as a writable slot (`pointer_params`). A binding
//! that reaches a verb through a different spelling opts its table out per
//! row with the reason recorded (`ts_omit` / `rust_omit` / `python_omit`), so
//! an omission is a decision, not a gap. The generators hold this table and
//! the export set to each other in both directions at compile time.

const shared = @import("c_abi_shared");

pub const Symbol = shared.symbols.Symbol;
pub const OmittedFamily = shared.symbols.OmittedFamily;
const omit = shared.symbols.omit_reason;

/// No whole family is omitted from the TypeScript table on this archive. The
/// per-symbol omissions below carry their reasons on the row.
pub const omitted_families = [_]OmittedFamily{};

pub const symbols = [_]Symbol{
    .{ .name = "glowcap_host_archive_fingerprint" },
    .{
        .name = "glowcap_host_new",
        .out_params = &.{9},
        .section = "Lifecycle. `outBuffers` marks the buffer params the callee writes, so\nthe wasm adapter copies back only true outputs (dlopen ignores it).",
        .python_omit = "Python gives every Host an explicit GlowcapContext so Zig callerless diagnostics have one claim owner",
        .racket_omit = "Racket gives every Host an explicit GlowcapContext so Zig callerless diagnostics have one claim owner",
    },
    .{
        .name = "glowcap_host_new_in",
        .out_params = &.{10},
    },
    .{ .name = "glowcap_host_diagnostic_id", .out_params = &.{1} },
    .{
        .name = "glowcap_host_release_on_drop",
        .out_params = &.{1},
        .ts_omit = "the TypeScript release rides a finalizer, so the Host is built with the setting off and the per-session opt-in stays",
        .python_omit = "the Python release rides a finalizer, so the Host is built with the setting off and the per-session opt-in stays",
        .racket_omit = "the Racket release rides a finalizer, so the Host is built with the setting off and the per-session opt-in stays",
    },
    .{
        .name = "glowcap_host_set_release_on_drop",
        .ts_omit = "the TypeScript release rides a finalizer, so the Host is built with the setting off and the per-session opt-in stays",
        .python_omit = "the Python release rides a finalizer, so the Host is built with the setting off and the per-session opt-in stays",
        .racket_omit = "the Racket release rides a finalizer, so the Host is built with the setting off and the per-session opt-in stays",
    },
    .{ .name = "glowcap_host_close" },
    .{ .name = "glowcap_host_close_progress", .out_params = &.{2} },
    .{ .name = "glowcap_host_close_wait_ms", .out_params = &.{2} },
    .{
        .name = "glowcap_host_lifecycle_state",
        .out_params = &.{1},
        .rust_omit = "close_progress already returns the terminal state while supplying the clock; the Rust binding needs no second observation call",
        .ts_omit = "close_progress already returns the terminal state while supplying the clock; the TypeScript binding needs no second observation call",
        .python_omit = "close_progress already returns the terminal state while supplying the clock; the Python binding needs no second observation call",
        .racket_omit = "close_progress already returns the terminal state while supplying the clock; the Racket binding needs no second observation call",
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
        .ts_omit = "the dialed and accepted opens retain the transport default in Zig; route policy uses set/remove",
        .rust_omit = "the dialed and accepted opens retain the transport default in Zig; route policy uses set/remove",
        .python_omit = "the dialed and accepted opens retain the transport default in Zig; route policy uses set/remove",
        .racket_omit = "the dialed and accepted opens retain the transport default in Zig; route policy uses set/remove",
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
        .rust_omit = "transport packages interpret their own locators; the generic Runtime retains only providers and connectors",
        .ts_omit = "transport packages interpret their own locators; the generic Runtime retains only providers and connectors",
        .python_omit = "transport packages interpret their own locators; the generic Runtime retains only providers and connectors",
        .racket_omit = "transport packages interpret their own locators; the generic Runtime retains only providers and connectors",
        .section = "Resolve a dial to a GlowcapDialPlan (grammar + hint + iroh posture); a free function.",
    },
    .{ .name = "glowcap_host_pending_dial", .out_params = &.{ 3, 5, 6 } },
    .{
        .name = "glowcap_host_pending_dial_introducer",
        .out_params = &.{3},
        .ts_omit = "TypeScript connectors receive redemption posture only; Rooms holds its signaling context in the route coordinator until the Rust application replaces it",
        .python_omit = "Python has no directory-scoped signaling connector; Zig provider dials do not use this byte-fed projection",
        .racket_omit = "Racket has no directory-scoped signaling connector; Zig provider dials do not use this byte-fed projection",
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
        .rust_omit = "the Rust pump feeds raw bytes (feed_bytes); no GlowcapFrame is built binding-side",
        .out_params = &.{},
        .ts_omit = "the TS pump feeds transport packets; no GlowcapFrame is ever built on the JS side",
        .python_omit = "the Python pump feeds raw bytes (feed_bytes); no GlowcapFrame is built binding-side",
        .racket_omit = "the Racket pump feeds raw bytes (feed_bytes); no GlowcapFrame is built binding-side",
    },
    .{
        .name = "glowcap_host_session_feed_bytes",
        .out_params = &.{},
        .section = "The byte pump and action queue. The fed chunk (index 1) is input-only:\nthe annotation is what keeps the wasm boundary at one copy-in per feed\nwith no full-chunk copy-back.",
    },
    .{
        .name = "glowcap_host_session_feed_packet",
        .out_params = &.{},
        .python_omit = "the Python pump still drives the stream-specific byte seam until its WebRTC adapter exists",
        .racket_omit = "the Racket pump still drives the stream-specific byte seam until its WebRTC adapter exists",
    },
    .{
        .name = "glowcap_host_session_resume_feed",
        .out_params = &.{},
    },
    .{
        .name = "glowcap_host_session_take_packet",
        .out_params = &.{ 1, 2, 4 },
        .python_omit = "the Python pump still drains the stream-specific byte seam until its WebRTC adapter exists",
        .racket_omit = "the Racket pump still drains the stream-specific byte seam until its WebRTC adapter exists",
    },
    .{ .name = "glowcap_host_session_take_outbound", .out_params = &.{ 1, 2, 4 } },
    .{
        .name = "glowcap_host_next_action",
        .rust_omit = "the Rust binding drains actions through the C hook pump (pump_drain), never the pull queue",
        .out_params = &.{1},
        .python_omit = "the Python binding drains actions through the C hook pump (pump_drain), never the pull queue",
        .racket_omit = "the Racket binding drains actions through the C hook pump (pump_drain), never the pull queue",
    },
    .{
        .name = "glowcap_host_pump_drain",
        .out_params = &.{ 2, 3 },
        .ts_omit = "the TS action loop drains through next_action directly; the C hook pump is for embedders without closures",
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
        .ts_omit = "Ordinary Host actor hosting currently has a Rust front; TypeScript retains its session-owned spawn front",
        .python_omit = "Ordinary Host actor hosting currently has a Rust front; Python retains its session-owned spawn front",
        .racket_omit = "Ordinary Host actor hosting currently has a Rust front; Racket retains its session-owned spawn front",
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
    // admits only its fixed hosted-object callbacks. Rust, Python, and Racket
    // each install the trace callback, which is lossless and needs no ring, so
    // they take the queue's omission rather than a second way to say the same
    // thing.
    .{
        .name = "glowcap_host_set_trace_queue",
        .out_params = &.{},
        .rust_omit = "the Rust veneer installs the trace callback; the drained ring is the seam for an embedder that cannot take one",
        .python_omit = "the Python veneer installs the trace callback; the drained ring is the seam for an embedder that cannot take one",
        .racket_omit = "the Racket veneer installs the trace callback; the drained ring is the seam for an embedder that cannot take one",
    },
    .{
        .name = "glowcap_host_next_trace",
        .out_params = &.{1},
        .rust_omit = "no queue to drain: the Rust veneer installs the trace callback",
        .python_omit = "no queue to drain: the Python veneer installs the trace callback",
        .racket_omit = "no queue to drain: the Racket veneer installs the trace callback",
    },
    .{
        .name = "glowcap_host_resolver_fulfill",
        .out_params = &.{},
        .section = "Off-turn settlement: a behavior atomically defers its answer onto a fresh\nresolver vow and the work's completion settles it later, top-level.",
    },
    .{
        .name = "glowcap_host_resolver_fulfill_value",
        .out_params = &.{},
        .python_omit = "automatic awaitable completion in this binding uses the plain-data resolver seam",
        .racket_omit = "the explicit resolver in this binding uses the plain-data seam",
    },
    .{
        .name = "glowcap_host_resolver_break",
        .out_params = &.{},
        .ts_omit = "automatic Promise rejection uses resolver_abandon because its session may already have retired the deferred answer; no manual resolver is exposed",
        .python_omit = "automatic awaitable rejection uses resolver_abandon because its session may already have retired the deferred answer; no manual resolver is exposed",
    },
    .{ .name = "glowcap_host_resolver_abandon", .out_params = &.{} },
    .{ .name = "glowcap_host_session_listen", .out_params = &.{2} },
    .{
        .name = "glowcap_host_session_resolve",
        .out_params = &.{ 2, 3 },
        .ts_omit = "generic opaque capability resolution is consumed by Rust Rooms; this binding currently exposes the wire listen operation",
        .python_omit = "generic opaque capability resolution is consumed by Rust Rooms; this binding currently exposes the wire listen operation",
        .racket_omit = "generic opaque capability resolution is consumed by Rust Rooms; this binding currently exposes the wire listen operation",
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
        .ts_omit = "sessionless delivery serves Rust managed hosting; TypeScript uses Session notifications",
        .python_omit = "sessionless delivery serves Rust managed hosting; Python uses Session notifications",
        .racket_omit = "sessionless delivery serves Rust managed hosting; Racket uses Session notifications",
    },
    .{
        .name = "glowcap_host_send",
        .out_params = &.{6},
        .ts_omit = "sessionless owning-value delivery serves the Rust Loam executor; TypeScript uses Session sends and has no Loam hosting profile",
        .python_omit = "sessionless owning-value delivery serves the Rust Loam executor; Python uses Session sends and has no Loam hosting profile",
        .racket_omit = "sessionless owning-value delivery serves the Rust Loam executor; Racket uses Session sends and has no Loam hosting profile",
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
        .rust_omit = "a Rust behavior sends through the session verbs",
        .out_params = &.{6},
        .ts_omit = "a TS behavior sends through the session verbs; the turn-scoped send is the closure-free C spelling",
        .python_omit = "a Python behavior sends through the session verbs",
        .racket_omit = "a Racket behavior sends through the session verbs",
    },
    .{
        .name = "glowcap_host_turn_tell",
        .rust_omit = "a Rust behavior tells through the session verbs",
        .out_params = &.{},
        .ts_omit = "a TS behavior tells through the session verbs; the turn-scoped tell is the closure-free C spelling",
        .python_omit = "a Python behavior tells through the session verbs",
        .racket_omit = "a Racket behavior tells through the session verbs",
    },
    .{ .name = "glowcap_host_turn_defer", .out_params = &.{1} },
    .{
        .name = "glowcap_host_turn_defer_if_answer",
        .out_params = &.{1},
        .ts_omit = "automatic promise deferral requires an answer; optional deferral needs an explicit callback lifetime owner",
        .python_omit = "automatic coroutine deferral requires an answer; optional deferral needs an explicit callback lifetime owner",
    },
    .{ .name = "glowcap_host_turn_spawn", .out_params = &.{4} },
    .{ .name = "glowcap_host_turn_break", .out_params = &.{} },
    .{ .name = "glowcap_host_ref_release", .section = "Capability lifetime, teardown, diagnostics." },
    .{ .name = "glowcap_host_session_published_ref", .out_params = &.{3} },
    .{
        .name = "glowcap_host_session_break_far_vows",
        .out_params = &.{},
        .rust_omit = "the Rust binding reports physical EOF through session_transport_closed; it has no separate manual far-vow break surface",
        .ts_omit = "the TypeScript binding reports physical EOF through session_transport_closed; it has no separate manual far-vow break surface",
        .python_omit = "the Python binding reports physical EOF through session_transport_closed; it has no separate manual far-vow break surface",
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
        .rust_omit = "the Rust surface reads the retained abort through session_last_abort's struct view alone",
        .out_params = &.{ 1, 2, 3, 5 },
        .ts_omit = "the TS surface reads the retained abort through session_last_abort's struct view alone",
        .python_omit = "the Python surface reads the retained abort through session_last_abort's struct view alone",
        .racket_omit = "the Racket surface reads the retained abort through session_last_abort's struct view alone",
    },
    .{ .name = "glowcap_host_session_partner_identity", .out_params = &.{1} },
    .{ .name = "glowcap_host_session_bind_verified_channel_key", .out_params = &.{} },
    .{ .name = "glowcap_host_last_error", .out_params = &.{0} },
    .{
        .name = "glowcap_host_clear_last_error",
        .rust_omit = omit.rust_last_error,
        .ts_omit = omit.ts_last_error,
        .python_omit = omit.python_last_error,
        .racket_omit = omit.racket_last_error,
    },
};
