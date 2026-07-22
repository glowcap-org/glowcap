//! The annotated symbol inventory of `libpancake_net_transport_webrtc` — the
//! crossing semantics a language FFI table cannot reflect from the C signature
//! alone.
//!
//! Every export has a row here (in the loader's reading order) or an omission
//! reason on its row. Two calls park the calling thread: `peer_wait_open` waits
//! for the channel to open, and `peer_read` waits for inbound bytes, so a JS
//! runtime dispatches both off its event loop (`nonblocking`). The generator
//! holds this inventory and the export set to each other in both directions at
//! compile time.

const shared = @import("c_abi_shared");

pub const Symbol = shared.symbols.Symbol;
pub const OmittedFamily = shared.symbols.OmittedFamily;

pub const omitted_families = [_]OmittedFamily{};

pub const symbols = [_]Symbol{
    .{ .name = "pancake_webrtc_last_error", .out_params = &.{0} },
    .{ .name = "pancake_webrtc_peer_new", .out_params = &.{1} },
    .{
        .name = "pancake_webrtc_peer_new_in",
        .out_params = &.{2},
        .ts_omit = "unused: the TS binding keeps its webrtc peers on the library allocator",
        .python_omit = "unused: the Python binding keeps its webrtc peers on the library allocator",
        .racket_omit = "unused: the Racket binding keeps its webrtc peers on the library allocator",
        .rust_omit = "unused: the Rust binding keeps its webrtc peers on the library allocator",
    },
    .{ .name = "pancake_webrtc_peer_create_offer", .out_params = &.{ 1, 3 } },
    .{ .name = "pancake_webrtc_peer_create_answer", .out_params = &.{ 1, 3 } },
    .{ .name = "pancake_webrtc_peer_set_remote_offer" },
    .{ .name = "pancake_webrtc_peer_set_remote_answer" },
    .{ .name = "pancake_webrtc_peer_add_remote_candidate" },
    .{ .name = "pancake_webrtc_peer_next_local_candidate", .out_params = &.{ 1, 3 } },
    .{ .name = "pancake_webrtc_peer_wait_open", .nonblocking = true, .blocking = true },
    .{ .name = "pancake_webrtc_peer_read", .out_params = &.{ 1, 3 }, .nonblocking = true, .blocking = true },
    .{ .name = "pancake_webrtc_peer_write", .out_params = &.{3} },
    .{ .name = "pancake_webrtc_peer_close" },
    .{ .name = "pancake_webrtc_peer_release" },
    // The row below is omitted from the language loaders, for the reason given.
    .{
        .name = "pancake_webrtc_clear_last_error",
        .ts_omit = "unused: the TS binding reads the slot after a failing call and never resets it",
        .python_omit = "unused: the Python binding reads the slot after a failing call and never resets it",
        .racket_omit = "unused: the Racket binding reads the slot after a failing call and never resets it",
    },
};
