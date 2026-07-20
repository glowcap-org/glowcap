//! The annotated symbol inventory of `libpancake_driver` — the crossing
//! semantics a language FFI table cannot reflect from the C signature alone.
//!
//! Every `pancake_host_*` export has one row here, in the header's canonical
//! order. The binding generators under `tools/gen/binding/` reflect each
//! symbol's real parameter and return types from this module's re-exports and
//! merge the two facts only a human can supply: which buffer parameters the
//! callee *writes* (`out_params` — the wasm boundary copies back only true
//! outputs), and the rare parameter that crosses as an opaque pointer even
//! though its type reflects as a writable slot (`pointer_params`). A binding
//! that reaches a verb through a different spelling opts its table out per
//! row with the reason recorded (`ts_omit` / `rust_omit` / `python_omit`), so
//! an omission is a decision, not a gap. The generators hold this table and
//! the export set to each other in both directions at compile time.

const shared = @import("c_abi_shared");

pub const Symbol = shared.symbols.Symbol;
pub const OmittedFamily = shared.symbols.OmittedFamily;

/// No whole family is omitted from the TypeScript table on this archive; the
/// six per-symbol omissions below carry their reasons on the row.
pub const omitted_families = [_]OmittedFamily{};

pub const symbols = [_]Symbol{
    .{
        .name = "pancake_host_new",
        .out_params = &.{6},
        .section = "Lifecycle. `outBuffers` marks the buffer params the callee writes, so\nthe wasm adapter copies back only true outputs (dlopen ignores it).",
    },
    .{
        .name = "pancake_host_new_in",
        .out_params = &.{7},
        .racket_omit = "unused: the Racket binding keeps its hosts on the library allocator",
    },
    .{ .name = "pancake_host_release" },
    .{ .name = "pancake_host_designator_from_seed", .out_params = &.{2} },
    .{ .name = "pancake_host_set_self_designator", .out_params = &.{} },
    .{ .name = "pancake_host_set_session_limits" },
    .{ .name = "pancake_host_session_open_dialed_locator", .out_params = &.{5} },
    .{ .name = "pancake_host_session_open_accepted", .out_params = &.{7} },
    .{
        .name = "pancake_host_plan_dial",
        .out_params = &.{8},
        .section = "Resolve a dial to a PancakeDialPlan (grammar + hint + iroh posture); a free function.",
    },
    .{ .name = "pancake_host_pending_dial", .out_params = &.{2} },
    .{ .name = "pancake_host_plan_accept", .out_params = &.{6} },
    .{ .name = "pancake_host_session_release" },
    .{ .name = "pancake_host_session_session_open" },
    .{
        .name = "pancake_host_session_feed",
        .rust_omit = "the Rust pump feeds raw bytes (feed_bytes); no PancakeFrame is built binding-side",
        .out_params = &.{},
        .ts_omit = "the TS pump feeds raw bytes (feed_bytes); no PancakeFrame is ever built on the JS side",
        .python_omit = "the Python pump feeds raw bytes (feed_bytes); no PancakeFrame is built binding-side",
        .racket_omit = "the Racket pump feeds raw bytes (feed_bytes); no PancakeFrame is built binding-side",
    },
    .{
        .name = "pancake_host_session_feed_bytes",
        .out_params = &.{},
        .section = "The byte pump and action queue. The fed chunk (index 1) is input-only:\nthe annotation is what keeps the wasm boundary at one copy-in per feed\nwith no full-chunk copy-back.",
    },
    .{ .name = "pancake_host_session_take_outbound", .out_params = &.{1} },
    .{ .name = "pancake_host_next_action", .rust_omit = "the Rust binding drains actions through the C hook pump (pump_drain), never the pull queue", .out_params = &.{1} },
    .{
        .name = "pancake_host_pump_drain",
        .out_params = &.{2},
        .ts_omit = "the TS action loop drains through next_action directly; the C hook pump is for embedders without closures",
    },
    .{ .name = "pancake_host_dialed" },
    .{ .name = "pancake_host_dial_failed", .out_params = &.{} },
    .{ .name = "pancake_host_provide_gift_id", .out_params = &.{} },
    .{
        .name = "pancake_host_session_publish",
        .out_params = &.{6},
        .section = "Publish and spawn (behavior = the trampoline pointer, ctx = the JS\nregistry id packed as a pointer-sized integer, free = NULL).",
    },
    .{ .name = "pancake_host_session_spawn", .out_params = &.{4} },
    .{ .name = "pancake_host_publish", .out_params = &.{} },
    .{
        .name = "pancake_host_session_fetch",
        .out_params = &.{3},
        .section = "Fetch and enliven — each mints a host vow (out param).",
    },
    .{ .name = "pancake_host_session_enliven", .out_params = &.{3} },
    .{
        .name = "pancake_host_session_send",
        .out_params = &.{6},
        .section = "Send, tell, vows, projections.",
    },
    .{ .name = "pancake_host_session_tell", .out_params = &.{} },
    .{ .name = "pancake_host_vow_send", .out_params = &.{6} },
    .{ .name = "pancake_host_vow_index", .out_params = &.{3} },
    .{ .name = "pancake_host_vow_untag", .out_params = &.{4} },
    .{ .name = "pancake_host_vow_get", .out_params = &.{4} },
    .{
        .name = "pancake_host_turn_forward",
        .out_params = &.{},
        .pointer_params = &.{6},
        .section = "Turn verbs (legal only inside a behavior callback). `turn_forward`'s\nout-reply is the raw pointer the trampoline was handed, so it crosses as\na pointer, not a JS buffer.",
    },
    .{
        .name = "pancake_host_turn_send",
        .rust_omit = "a Rust behavior sends through the session verbs",
        .out_params = &.{6},
        .ts_omit = "a TS behavior sends through the session verbs; the turn-scoped send is the closure-free C spelling",
        .python_omit = "a Python behavior sends through the session verbs",
        .racket_omit = "a Racket behavior sends through the session verbs",
    },
    .{
        .name = "pancake_host_turn_tell",
        .rust_omit = "a Rust behavior tells through the session verbs",
        .out_params = &.{},
        .ts_omit = "a TS behavior tells through the session verbs; the turn-scoped tell is the closure-free C spelling",
        .python_omit = "a Python behavior tells through the session verbs",
        .racket_omit = "a Racket behavior tells through the session verbs",
    },
    .{ .name = "pancake_host_turn_spawn", .out_params = &.{4} },
    .{ .name = "pancake_host_turn_break", .out_params = &.{} },
    .{
        .name = "pancake_host_gc_release",
        .section = "GC, teardown, diagnostics.",
    },
    .{ .name = "pancake_host_session_break_far_vows", .out_params = &.{} },
    .{ .name = "pancake_host_session_set_exporter_location", .out_params = &.{} },
    .{ .name = "pancake_host_session_last_abort", .out_params = &.{1} },
    .{
        .name = "pancake_host_session_partner_abort",
        .rust_omit = "the Rust surface reads the retained abort through session_last_abort's struct view alone",
        .out_params = &.{ 1, 2, 3, 5 },
        .ts_omit = "the TS surface reads the retained abort through session_last_abort's struct view alone",
        .python_omit = "the Python surface reads the retained abort through session_last_abort's struct view alone",
        .racket_omit = "the Racket surface reads the retained abort through session_last_abort's struct view alone",
    },
    .{ .name = "pancake_host_last_error", .out_params = &.{0} },
    .{
        .name = "pancake_host_clear_last_error",
        .rust_omit = "unused: the Rust binding reads the slot after a failing call and never resets it",
        .ts_omit = "unused: the TS binding reads the slot after a failing call and never resets it",
        .python_omit = "unused: the Python binding reads the slot after a failing call and never resets it",
        .racket_omit = "unused: the Racket binding reads the slot after a failing call and never resets it",
    },
};
