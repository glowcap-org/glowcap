//! Generates `include/glowcap_net_transport_inproc.h` from the Zig
//! `c_abi_net_transport_inproc` source.
//!
//! The in-process transport's public C ABI is a separate archive from
//! `libglowcap_ocapn` (ADR-0059), so it gets its own header. As with
//! `tools/gen/header/ocapn.zig`, the function signatures are *reflected* from the real
//! `src/c_abi/net_transport/inproc/mod.zig` exports, so the header cannot
//! disagree with the implementation, and the prose lives here.
//! `zig build gen-header-net-transport-inproc-check` is the staleness gate;
//! `zig build gen-header-net-transport-inproc` is the fixer.
//!
//! The shared frame/peer/context vocabulary (`GlowcapFrame`,
//! `GlowcapManagedFrame`, `GlowcapContext`) is declared in `glowcap_ocapn.h`,
//! which this header includes; only the three in-process handles and the
//! `glowcap_inproc_*` prototypes are new here.

const std = @import("std");
const c = @import("c_abi_net_transport_inproc");
const header_emit = @import("header_emit.zig");

const Output = @import("output").Output;
pub const outputs = [_]Output{
    .{ .path = "include/glowcap_net_transport_inproc.h", .generate = generate },
};
pub const step_name = "gen-header-net-transport-inproc";

// Every prototype the header emits, in order. `emitFn` refuses a name missing
// here; the comptime guard below holds the table against the real
// `c_abi_net_transport_inproc` declarations in both directions, so a new
// `pub export fn glowcap_inproc_*` cannot silently miss the header while the
// gate stays green.
const emitted_fn_names = [_][]const u8{
    "glowcap_inproc_archive_fingerprint",
    "glowcap_inproc_netlayer_new",
    "glowcap_inproc_netlayer_new_in",
    "glowcap_inproc_netlayer_release",
    "glowcap_inproc_connect",
    "glowcap_inproc_listen",
    "glowcap_inproc_listener_readiness_fd",
    "glowcap_inproc_accept",
    "glowcap_inproc_conn_read_frame",
    "glowcap_inproc_conn_write_frame",
    "glowcap_inproc_conn_shutdown",
    "glowcap_inproc_conn_release",
    "glowcap_inproc_listener_shutdown",
    "glowcap_inproc_listener_release",
    "glowcap_inproc_last_error",
    "glowcap_inproc_clear_last_error",
};

// The reflection machinery is shared with the other header generators; this
// `Spec` binds it to `libglowcap_net_transport_inproc`. No function-pointer
// typedefs and no `#define`s, so it supplies only the module and the table.
const Spec = struct {
    pub const c = @import("c_abi_net_transport_inproc");
    pub const emitted_fns: []const []const u8 = &emitted_fn_names;
};
const E = header_emit.Emit(Spec);
const Buf = header_emit.Buf;
const emitDoc = header_emit.emitDoc;
const emitFn = E.emitFn;

// Coverage guard, both directions: every `pub export fn glowcap_inproc_*` in
// `c_abi_net_transport_inproc` must be listed, and every listed name must be real.
comptime {
    E.guardFns("c_abi_net_transport_inproc", "glowcap_inproc_");
}

/// Build the full header text. Caller owns the returned bytes.
fn generate(gpa: std.mem.Allocator) ![]u8 {
    var b: Buf = .empty;
    errdefer b.deinit(gpa);

    try b.appendSlice(gpa,
        \\/* Generated from src/c_abi/net_transport/inproc/mod.zig by tools/gen/header/net_inproc.zig.
        \\   Do not edit by hand: run `zig build gen-header-net-transport-inproc`.
        \\   Function signatures are reflected from the Zig source, so this header
        \\   cannot drift from the implementation.
        \\
        \\   The in-process transport's public C ABI: a separate archive
        \\   (libglowcap_net_transport_inproc) from libglowcap_ocapn (ADR-0059). It
        \\   is a companion, not a superset: it exports only the glowcap_inproc_*
        \\   family and shares no core symbol with libglowcap_ocapn, so a consumer
        \\   links BOTH archives and includes BOTH headers. The shared frame, peer,
        \\   and context vocabulary lives in glowcap_ocapn.h (included below) and
        \\   the archives agree on its layout; only the three in-process handles and
        \\   the glowcap_inproc_* prototypes are declared here. The in-process
        \\   family has its own last-error slot, read through
        \\   glowcap_inproc_last_error rather than glowcap_ocapn's
        \\   glowcap_last_error. */
        \\#ifndef GLOWCAP_NET_TRANSPORT_INPROC_H
        \\#define GLOWCAP_NET_TRANSPORT_INPROC_H
        \\
        \\#include <stddef.h>
        \\#include <stdint.h>
        \\#include "glowcap_ocapn.h"
        \\
        \\#ifdef __cplusplus
        \\extern "C" {
        \\#endif
        \\
    );

    try emitDoc(&b, gpa,
        \\Orientation: the socket-free sibling of the TCP endpoints (glowcap_net_transport_tcp.h):
        \\two peers in one process wired by in-process pipes and no kernel transport.
        \\The listener exposes a wake descriptor for foreign reactors. The same
        \\host-owns-the-peer frame shuttle and
        \\netlayer lifecycle — create the netlayer, make connections/listeners from
        \\it, release them, then release it — but a listener binds to a string
        \\designator (any opaque token, not a host:port) and a dialer names that
        \\designator. This is the path a binding's smoke test dials to run a full
        \\OCapN conversation without touching a socket. Blocking; in-process only.
    );

    try b.appendSlice(gpa,
        \\
        \\/* An in-process netlayer: the switchboard plus the one owned I/O backend
        \\   its pipes block on. Created by glowcap_inproc_netlayer_new; released by
        \\   glowcap_inproc_netlayer_release after every endpoint is released. */
        \\typedef struct GlowcapInprocNetlayer GlowcapInprocNetlayer;
        \\/* One in-process connection carrying one OCapN session, framed on the
        \\   netlayer's codec. One read and one write may run concurrently; calls in
        \\   the same direction are serialized by the archive. Created by
        \\   glowcap_inproc_connect or glowcap_inproc_accept; released by
        \\   glowcap_inproc_conn_release. */
        \\typedef struct GlowcapInprocConn GlowcapInprocConn;
        \\/* A bound in-process listener. Created by glowcap_inproc_listen; released
        \\   by glowcap_inproc_listener_release. */
        \\typedef struct GlowcapInprocListener GlowcapInprocListener;
        \\
        \\
    );

    try emitFn(&b, gpa, "glowcap_inproc_archive_fingerprint", &.{}, "Return the exact callable-surface fingerprint. Compare it with the binding-generated GLOWCAP_INPROC_ARCHIVE_FINGERPRINT before any other call.");
    try emitFn(&b, gpa, "glowcap_inproc_netlayer_new", &.{"out_netlayer"}, "Create the in-process netlayer handle that owns the switchboard and its I/O\nbackend, allocating through the library allocator. Release with\nglowcap_inproc_netlayer_release after releasing every endpoint made from it.");
    try emitFn(&b, gpa, "glowcap_inproc_netlayer_new_in", &.{ "context", "out_netlayer" }, "Create an in-process netlayer whose switchboard, backend, and per-connection\nbuffers allocate through `context`.");
    try emitFn(&b, gpa, "glowcap_inproc_netlayer_release", &.{"netlayer"}, "Release the in-process netlayer. Every connection and listener made from it\nmust already be released.");
    const optional_diagnostic_doc = "out_error/out_error_len optionally capture this call's diagnostic before an\noff-thread runtime regains control: omit all three diagnostic arguments, or\nprovide out_error_len. It receives the full length; out_error receives at most\nerror_cap - 1 bytes and is NUL-terminated when error_cap is nonzero.";

    try emitFn(&b, gpa, "glowcap_inproc_connect", &.{ "netlayer", "designator", "designator_len", "codec", "max_frame_bytes", "out_conn", "out_error", "error_cap", "out_error_len" }, "Dial the listener bound at `designator` and return an owned connection\nframing on `codec`, refusing inbound frames over max_frame_bytes.\n`designator` is borrowed. GLOWCAP_ERR_INVALID_ARGUMENT for a bad codec or a\nzero frame cap; GLOWCAP_ERR_IO when no listener is bound there. Release with\nglowcap_inproc_conn_release.\n\n" ++ optional_diagnostic_doc);
    try emitFn(&b, gpa, "glowcap_inproc_listen", &.{ "netlayer", "designator", "designator_len", "out_listener" }, "Bind an in-process listener on `designator` (any opaque token; borrowed).\nGLOWCAP_ERR_INVALID_ARGUMENT for an empty or already-bound designator. Release\nwith glowcap_inproc_listener_release.");
    try emitFn(&b, gpa, "glowcap_inproc_listener_readiness_fd", &.{ "listener", "out_fd" }, "Return the borrowed wake descriptor nudged when a dial is queued. Park an\nexternal reactor on it before glowcap_inproc_accept. The listener owns the fd;\ndo not close it or use it after glowcap_inproc_listener_release.");
    try emitFn(&b, gpa, "glowcap_inproc_accept", &.{ "listener", "codec", "max_frame_bytes", "out_conn", "out_error", "error_cap", "out_error_len" }, "Block until a dialer connects, returning an owned connection framing on\n`codec`. Same argument and release contract as glowcap_inproc_connect.\n\n" ++ optional_diagnostic_doc);
    try emitFn(&b, gpa, "glowcap_inproc_conn_read_frame", &.{ "conn", "out_frame", "out_error", "error_cap", "out_error_len" }, "Block for one whole frame as an owned managed frame. Returns\nGLOWCAP_ERR_CLOSED on graceful EOF.\n\n" ++ optional_diagnostic_doc);
    try emitFn(&b, gpa, "glowcap_inproc_conn_write_frame", &.{ "conn", "frame", "out_error", "error_cap", "out_error_len" }, "Write one frame's borrowed bytes into the partner's pipe. Returns\nGLOWCAP_ERR_CLOSED after shutdown begins.\n\n" ++ optional_diagnostic_doc);
    try emitFn(&b, gpa, "glowcap_inproc_conn_shutdown", &.{"conn"}, "Seal native admission and interrupt blocked reads and writes without freeing\nthe connection. May race operations; join the embedding's leases before release.\nIdempotent.");
    try emitFn(&b, gpa, "glowcap_inproc_conn_release", &.{"conn"}, "After stopping new calls, invoking shutdown, and joining the embedding's\noperation leases, close and free the handle. Release must not race call initiation.");
    try emitFn(&b, gpa, "glowcap_inproc_listener_shutdown", &.{"listener"}, "Seal native accept admission and wake a blocked accept without freeing the\nlistener. May race operations; join the embedding's leases before release. Idempotent.");
    try emitFn(&b, gpa, "glowcap_inproc_listener_release", &.{ "listener", "out_error", "error_cap", "out_error_len" }, "After stopping new calls, invoking shutdown, and joining the embedding's\noperation leases, close and free the listener. Release must not race call\ninitiation.\n\n" ++ optional_diagnostic_doc);

    try emitFn(&b, gpa, "glowcap_inproc_last_error", &.{ "out_buf", "cap" }, "Copy the calling thread's last in-process-transport error into out_buf, the\ninproc sibling of glowcap_last_error, reading this archive's own per-thread\nslot. A glowcap_inproc_* call that returns a cause-bearing code records it\nhere. Copies at most cap-1 bytes and NUL-terminates when cap>0; out_buf NULL or\ncap 0 queries the length. Returns the full message length, or 0 when none is\nset." ++ header_emit.last_error_freshness_doc);
    try emitFn(&b, gpa, "glowcap_inproc_clear_last_error", &.{}, "Clear the calling thread's in-process-transport last-error slot.");

    try b.appendSlice(gpa,
        \\
        \\#ifdef __cplusplus
        \\}
        \\#endif
        \\
        \\#endif /* GLOWCAP_NET_TRANSPORT_INPROC_H */
        \\
    );

    try E.assertAllEmitted(&b, "gen-header-net-transport-inproc");
    return b.toOwnedSlice(gpa);
}
