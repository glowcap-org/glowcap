//! The annotated symbol inventory of `libglowcap_ocapn` — the crossing
//! semantics a language FFI table cannot reflect from the C signature alone.
//!
//! Every export has a row here (in the TS table's reading order) or a binding-
//! specific omission reason on its row. The generator holds this inventory and
//! the export set to each other in both directions at compile time.

const shared = @import("c_abi_shared");

pub const Symbol = shared.symbols.Symbol;
const omit = shared.symbols.omit_reason;
pub const omitted_families = [_]shared.symbols.OmittedFamily{};

pub const symbols = [_]Symbol{
    .{ .name = "glowcap_ocapn_archive_fingerprint" },
    .{
        .name = "glowcap_abi_version",
        .out_params = &.{ 0, 1, 2 },
        .section = "`outBuffers` marks the buffer params the callee writes, so the wasm\nadapter copies back only true outputs (dlopen ignores it).",
    },
    .{ .name = "glowcap_last_error", .out_params = &.{0} },
    .{
        .name = "glowcap_context_new_with_allocator",
        .out_params = &.{1},
        .racket_omit = "unused: the Racket binding keeps every archive on the library allocator",
    },
    .{ .name = "glowcap_context_report_failure", .pointer_params = &.{1} },
    .{
        .name = "glowcap_context_allocate_lifecycle_id",
        .out_params = &.{1},
        .rust_omit = "native Host construction assigns Host identity; Rust currently owns no other Context-scoped diagnostic lifecycle",
        .ts_omit = "native Host construction assigns Host identity; TypeScript currently owns no other Context-scoped diagnostic lifecycle",
        .python_omit = "native Host construction assigns Host identity; Python currently owns no other Context-scoped diagnostic lifecycle",
        .racket_omit = "native Host construction assigns Host identity; Racket currently owns no other Context-scoped diagnostic lifecycle",
    },
    .{
        .name = "glowcap_context_next_failure",
        .out_params = &.{ 1, 2, 4 },
    },
    .{
        .name = "glowcap_context_release",
    },
    .{ .name = "glowcap_managed_frame_release", .out_params = &.{} },
    .{
        .name = "glowcap_locator_record_encode",
        .out_params = &.{ 1, 2 },
        .pointer_params = &.{0},
    },
    // A raw-pointer release must free the address it was handed, so the
    // pointer crosses by identity, never as a copied JS buffer.
    .{ .name = "glowcap_locator_record_bytes_release", .pointer_params = &.{0} },
    .{
        .name = "glowcap_uri_parse_peer",
        .out_params = &.{2},
        .section = "OCapN locator URIs — core vocabulary in libglowcap_ocapn, so a consumer\nreaches them without any transport archive. The one grammar every binding\nshares.",
    },
    .{ .name = "glowcap_uri_parse_peer_in", .out_params = &.{3} },
    .{ .name = "glowcap_uri_parse_sturdyref", .out_params = &.{3} },
    .{ .name = "glowcap_uri_parse_sturdyref_in", .out_params = &.{4} },
    .{ .name = "glowcap_uri_format_peer", .out_params = &.{ 9, 11 } },
    .{ .name = "glowcap_uri_format_sturdyref", .out_params = &.{ 12, 14 } },
    .{ .name = "glowcap_locator_new", .out_params = &.{5} },
    .{ .name = "glowcap_locator_new_in", .out_params = &.{6} },
    .{ .name = "glowcap_locator_clone", .out_params = &.{1} },
    .{ .name = "glowcap_locator_clone_in", .out_params = &.{2} },
    .{ .name = "glowcap_locator_borrow_view", .out_params = &.{1} },
    .{ .name = "glowcap_sturdyref_borrow_locator", .out_params = &.{1} },
    .{ .name = "glowcap_sturdyref_swissnum", .out_params = &.{ 1, 2 } },
    .{ .name = "glowcap_sturdyref_release" },
    .{ .name = "glowcap_locator_add_string" },
    .{ .name = "glowcap_locator_add_bytes" },
    .{ .name = "glowcap_locator_add_boolean" },
    .{ .name = "glowcap_locator_add_integer" },
    .{ .name = "glowcap_locator_transport", .out_params = &.{ 1, 2 } },
    .{ .name = "glowcap_locator_designator", .out_params = &.{ 1, 2 } },
    .{ .name = "glowcap_designator_host_port", .out_params = &.{ 2, 3, 4 } },
    .{ .name = "glowcap_locator_hint_count", .out_params = &.{1} },
    .{ .name = "glowcap_locator_hint_at", .out_params = &.{2} },
    .{ .name = "glowcap_locator_hint_wire_form", .out_params = &.{1} },
    .{ .name = "glowcap_locator_release" },
    // The rows below are omitted from the TypeScript table, each for the
    // reason on its row.
    .{
        .name = "glowcap_context_new",
        .out_params = &.{0},
    },
    .{
        .name = "glowcap_clear_last_error",
        .ts_omit = omit.ts_last_error,
        .python_omit = omit.python_last_error,
        .racket_omit = omit.racket_last_error,
    },
    .{
        .name = "glowcap_locator_hint",
        .out_params = &.{3},
        .ts_omit = "the TS surface walks hints through hint_count/hint_at; the single-lookup accessor is unused",
        .python_omit = "the Python surface walks hints through hint_count/hint_at; the single-lookup accessor is unused",
        .racket_omit = "the Racket surface walks hints through hint_count/hint_at; the single-lookup accessor is unused",
    },
    .{
        .name = "glowcap_locator_host_port",
        .ts_omit = "the TS surface resolves host:port through designator_host_port",
        .python_omit = "the Python surface resolves host:port through designator_host_port",
        .racket_omit = "the Racket surface resolves host:port through designator_host_port",
    },
};
