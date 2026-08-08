//! The annotated symbol inventory of `libpancake_net_transport_webrtc` — the
//! crossing semantics a language FFI table cannot reflect from the C signature
//! alone.
//!
//! Every export has a row here (in the loader's reading order) or an omission
//! reason on its row. No WebRTC transport export parks the calling thread: the
//! netlayer readiness fd owns channel-open, candidate, byte, and close wakeups.

const shared = @import("c_abi_shared");

pub const Symbol = shared.symbols.Symbol;
pub const OmittedFamily = shared.symbols.OmittedFamily;

pub const omitted_families = [_]OmittedFamily{};

const ts_omit = "browser-native TypeScript uses RTCPeerConnection and does not dlopen the native WebRTC companion";

pub const symbols = [_]Symbol{
    .{ .name = "pancake_webrtc_last_error", .out_params = &.{0}, .ts_omit = ts_omit },
    .{ .name = "pancake_webrtc_netlayer_new", .out_params = &.{1}, .ts_omit = ts_omit },
    .{
        .name = "pancake_webrtc_netlayer_new_in",
        .out_params = &.{2},
        .ts_omit = ts_omit,
        .python_omit = "unused: the Python binding keeps its webrtc netlayer on the library allocator",
        .racket_omit = "unused: the Racket binding keeps its webrtc netlayer on the library allocator",
        .rust_omit = "unused: the Rust binding keeps its webrtc netlayer on the library allocator",
    },
    .{ .name = "pancake_webrtc_netlayer_readiness_fd", .ts_omit = ts_omit },
    .{ .name = "pancake_webrtc_netlayer_drain_ready", .out_params = &.{ 1, 3 }, .ts_omit = ts_omit },
    .{ .name = "pancake_webrtc_netlayer_release", .ts_omit = ts_omit },
    .{ .name = "pancake_webrtc_peer_new", .out_params = &.{2}, .ts_omit = ts_omit },
    .{
        .name = "pancake_webrtc_peer_new_in",
        .out_params = &.{3},
        .ts_omit = ts_omit,
        .python_omit = "unused: the Python binding keeps its webrtc peers on the netlayer allocator",
        .racket_omit = "unused: the Racket binding keeps its webrtc peers on the netlayer allocator",
        .rust_omit = "unused: the Rust binding keeps its webrtc peers on the netlayer allocator",
    },
    .{ .name = "pancake_webrtc_peer_create_offer", .out_params = &.{ 1, 3 }, .ts_omit = ts_omit },
    .{ .name = "pancake_webrtc_peer_create_answer", .out_params = &.{ 1, 3 }, .ts_omit = ts_omit },
    .{ .name = "pancake_webrtc_peer_set_remote_offer", .ts_omit = ts_omit },
    .{ .name = "pancake_webrtc_peer_set_remote_answer", .ts_omit = ts_omit },
    .{ .name = "pancake_webrtc_peer_add_remote_candidate", .ts_omit = ts_omit },
    .{ .name = "pancake_webrtc_peer_next_local_candidate", .out_params = &.{ 1, 3 }, .ts_omit = ts_omit },
    .{ .name = "pancake_webrtc_peer_id", .ts_omit = ts_omit },
    .{ .name = "pancake_webrtc_peer_is_open", .ts_omit = ts_omit },
    .{ .name = "pancake_webrtc_peer_try_read", .out_params = &.{ 1, 3 }, .ts_omit = ts_omit },
    .{ .name = "pancake_webrtc_peer_try_write", .out_params = &.{3}, .ts_omit = ts_omit },
    .{ .name = "pancake_webrtc_peer_close", .ts_omit = ts_omit },
    .{ .name = "pancake_webrtc_peer_release", .ts_omit = ts_omit },
    // The row below is omitted from the language loaders, for the reason given.
    .{
        .name = "pancake_webrtc_clear_last_error",
        .ts_omit = ts_omit,
        .python_omit = "unused: the Python binding reads the slot after a failing call and never resets it",
        .racket_omit = "unused: the Racket binding reads the slot after a failing call and never resets it",
    },
};
