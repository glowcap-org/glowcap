//! The annotated symbol inventory of `libglowcap_net_transport_webrtc`: the
//! crossing semantics a language FFI table cannot reflect from the C signature
//! alone.
//!
//! Every export has a row here (in the loader's reading order) or an omission
//! reason on its row. The readiness and try-I/O exports return immediately.
//! Peer construction and SDP/ICE mutation, including the answer and candidates
//! handed to a managed dial, enter the sidecar runtime and are marked as
//! blocking crossings. The offer handed to a managed accept is not: it calls
//! the netlayer's `send_answer` back on the calling thread before it returns,
//! and a blocking crossing refuses that callback.

const shared = @import("c_abi_shared");

pub const Symbol = shared.symbols.Symbol;
pub const OmittedFamily = shared.symbols.OmittedFamily;
const omit = shared.symbols.omit_reason;

pub const omitted_families = [_]OmittedFamily{};

pub const symbols = [_]Symbol{
    .{ .name = "glowcap_webrtc_archive_fingerprint" },
    .{ .name = "glowcap_webrtc_last_error", .out_params = &.{0} },
    .{ .name = "glowcap_webrtc_netlayer_new", .out_params = &.{1} },
    .{
        .name = "glowcap_webrtc_netlayer_new_in",
        .out_params = &.{2},
        .python_omit = "unused: the Python binding keeps its webrtc netlayer on the library allocator",
        .racket_omit = "unused: the Racket binding keeps its webrtc netlayer on the library allocator",
        .rust_omit = "unused: the Rust binding keeps its webrtc netlayer on the library allocator",
    },
    .{ .name = "glowcap_webrtc_netlayer_readiness_fd" },
    .{ .name = "glowcap_webrtc_netlayer_drain_ready", .out_params = &.{ 1, 3 } },
    .{ .name = "glowcap_webrtc_netlayer_provide_offer", .out_params = &.{5} },
    .{ .name = "glowcap_webrtc_netlayer_provide_answer", .blocking = true },
    .{ .name = "glowcap_webrtc_netlayer_provide_candidate", .blocking = true },
    .{ .name = "glowcap_webrtc_netlayer_fail_exchange", .blocking = true },
    .{ .name = "glowcap_webrtc_netlayer_release" },
    .{ .name = "glowcap_webrtc_peer_new", .out_params = &.{2}, .blocking = true },
    .{
        .name = "glowcap_webrtc_peer_new_in",
        .out_params = &.{3},
        .blocking = true,
        .python_omit = "unused: the Python binding keeps its webrtc peers on the netlayer allocator",
        .racket_omit = "unused: the Racket binding keeps its webrtc peers on the netlayer allocator",
        .rust_omit = "unused: the Rust binding keeps its webrtc peers on the netlayer allocator",
    },
    .{ .name = "glowcap_webrtc_peer_authorize_remote" },
    .{ .name = "glowcap_webrtc_peer_create_offer", .out_params = &.{ 1, 3 }, .blocking = true },
    .{ .name = "glowcap_webrtc_peer_create_answer", .out_params = &.{ 1, 3 }, .blocking = true },
    .{ .name = "glowcap_webrtc_peer_set_remote_offer", .blocking = true },
    .{ .name = "glowcap_webrtc_peer_set_remote_answer", .blocking = true },
    .{ .name = "glowcap_webrtc_peer_add_remote_candidate", .blocking = true },
    .{ .name = "glowcap_webrtc_peer_next_local_candidate", .out_params = &.{ 1, 3 } },
    .{ .name = "glowcap_webrtc_peer_id" },
    .{ .name = "glowcap_webrtc_peer_is_open" },
    .{ .name = "glowcap_webrtc_peer_try_receive_packet", .out_params = &.{ 1, 3 } },
    .{ .name = "glowcap_webrtc_peer_try_send_packet", .out_params = &.{3} },
    .{ .name = "glowcap_webrtc_peer_close" },
    .{ .name = "glowcap_webrtc_peer_release" },
    .{ .name = "glowcap_webrtc_transport_provider", .out_params = &.{1} },
    // The row below is omitted from the language loaders, for the reason given.
    .{
        .name = "glowcap_webrtc_clear_last_error",
        .ts_omit = omit.ts_last_error,
        .python_omit = omit.python_last_error,
        .racket_omit = omit.racket_last_error,
    },
};
