//! The annotated symbol inventory of `libpancake_ocapn` — the crossing
//! semantics a language FFI table cannot reflect from the C signature alone.
//!
//! Every export either has a row here (in the TS table's reading order), an
//! omission reason on its row, or a family-level omission below, so a symbol
//! a binding does not declare is a decision with its reason recorded, never a
//! gap. The raw `pancake_peer_*` tier is the one whole family every binding
//! table omits: the peer is driven through the byte-fed host archive
//! (`libpancake_driver`, ADR-0072), so no raw peer call ever crosses a
//! binding FFI. The generator holds this inventory and the export set to
//! each other in both directions at compile time.

const shared = @import("c_abi_shared");

pub const Symbol = shared.symbols.Symbol;
pub const OmittedFamily = shared.symbols.OmittedFamily;

pub const omitted_families = [_]OmittedFamily{
    .{
        .prefix = "pancake_peer_",
        .reason = "the peer tier is driven through the byte-fed host archive (libpancake_driver); no raw peer call crosses a binding FFI",
    },
};

pub const symbols = [_]Symbol{
    .{
        .name = "pancake_abi_version",
        .out_params = &.{ 0, 1, 2 },
        .section = "`outBuffers` marks the buffer params the callee writes, so the wasm\nadapter copies back only true outputs (dlopen ignores it).",
    },
    .{ .name = "pancake_last_error", .out_params = &.{0} },
    .{
        .name = "pancake_context_new_with_allocator",
        .out_params = &.{1},
        .racket_omit = "unused: the Racket binding keeps every archive on the library allocator",
    },
    .{
        .name = "pancake_context_release",
        .racket_omit = "unused: the Racket binding keeps every archive on the library allocator",
    },
    .{ .name = "pancake_managed_frame_release", .out_params = &.{} },
    .{ .name = "pancake_encode_peer_locator", .out_params = &.{ 6, 7 } },
    // A raw-pointer release must free the address it was handed, so the
    // pointer crosses by identity, never as a copied JS buffer.
    .{ .name = "pancake_peer_locator_bytes_release", .pointer_params = &.{0} },
    .{
        .name = "pancake_uri_parse_peer",
        .out_params = &.{2},
        .section = "OCapN locator URIs — core vocabulary in libpancake_ocapn, so a consumer\nreaches them without any transport archive. The one grammar every binding\nshares.",
    },
    .{ .name = "pancake_uri_parse_sturdyref", .out_params = &.{2} },
    .{ .name = "pancake_uri_format_peer", .out_params = &.{ 9, 11 } },
    .{ .name = "pancake_locator_transport", .out_params = &.{ 1, 2 } },
    .{ .name = "pancake_locator_designator", .out_params = &.{ 1, 2 } },
    .{ .name = "pancake_designator_host_port", .out_params = &.{ 2, 3, 4 } },
    .{ .name = "pancake_locator_swissnum", .out_params = &.{ 1, 2 } },
    .{ .name = "pancake_locator_hint_count", .out_params = &.{1} },
    .{ .name = "pancake_locator_hint_at", .out_params = &.{ 2, 3, 4, 5 } },
    .{ .name = "pancake_locator_release" },
    // The rows below are omitted from the TypeScript table, each for the
    // reason on its row.
    .{
        .name = "pancake_context_new",
        .ts_omit = "unused: the TS binding mints contexts only through new_with_allocator",
        .racket_omit = "unused: the Racket binding keeps every archive on the library allocator",
    },
    .{
        .name = "pancake_clear_last_error",
        .ts_omit = "unused: the TS binding reads the slot after a failing call and never resets it",
        .python_omit = "unused: the Python binding reads the slot after a failing call and never resets it",
        .racket_omit = "unused: the Racket binding reads the slot after a failing call and never resets it",
    },
    .{
        .name = "pancake_event_release",
        .rust_omit = "peer-tier event handles never reach the Rust binding; the host archive drives the peer",
        .ts_omit = "peer-tier event handles never reach TS; the host archive drives the peer",
        .python_omit = "peer-tier event handles never reach Python; the host archive drives the peer",
        .racket_omit = "peer-tier event handles never reach Racket; the host archive drives the peer",
    },
    .{
        .name = "pancake_any_event_release",
        .rust_omit = "peer-tier event handles never reach the Rust binding; the host archive drives the peer",
        .ts_omit = "peer-tier event handles never reach TS; the host archive drives the peer",
        .python_omit = "peer-tier event handles never reach Python; the host archive drives the peer",
        .racket_omit = "peer-tier event handles never reach Racket; the host archive drives the peer",
    },
    .{
        .name = "pancake_build_handoff_give",
        .rust_omit = "handoff origination rides the host tier's action queue, never this raw builder",
        .out_params = &.{ 10, 11 },
        .ts_omit = "handoff origination rides the host tier's action queue (need-gift-id / provide), never this raw builder",
        .python_omit = "handoff origination rides the host tier's action queue, never this raw builder",
        .racket_omit = "handoff origination rides the host tier's action queue, never this raw builder",
    },
    .{
        .name = "pancake_handoff_give_bytes_release",
        .rust_omit = "handoff origination rides the host tier's action queue, so the Rust binding never owns raw give bytes",
        .ts_omit = "handoff origination rides the host tier's action queue, so TS never owns raw give bytes",
        .python_omit = "handoff origination rides the host tier's action queue, so Python never owns raw give bytes",
        .racket_omit = "handoff origination rides the host tier's action queue, so Racket never owns raw give bytes",
    },
    .{
        .name = "pancake_locator_hint",
        .ts_omit = "the TS surface walks hints through hint_count/hint_at; the single-lookup accessor is unused",
        .python_omit = "the Python surface walks hints through hint_count/hint_at; the single-lookup accessor is unused",
        .racket_omit = "the Racket surface walks hints through hint_count/hint_at; the single-lookup accessor is unused",
    },
    .{
        .name = "pancake_locator_host_port",
        .ts_omit = "the TS surface resolves host:port through designator_host_port",
        .python_omit = "the Python surface resolves host:port through designator_host_port",
        .racket_omit = "the Racket surface resolves host:port through designator_host_port",
    },
    .{
        .name = "pancake_uri_format_sturdyref",
        .rust_omit = "unused: the Rust surface formats peer URIs only",
        .ts_omit = "unused: the TS surface formats peer URIs only",
        .python_omit = "unused: the Python surface formats peer URIs only",
        .racket_omit = "unused: the Racket surface formats peer URIs only",
    },
};
