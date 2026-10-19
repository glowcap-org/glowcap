//! Generates `include/glowcap_net_transport_tcp.h` from the Zig
//! `c_abi_net_transport_tcp` source.
//!
//! The TCP transport's public C ABI is a separate archive from
//! `libglowcap_ocapn` (ADR-0022), so it gets its own header. As with
//! `tools/gen/header/ocapn.zig`, the function signatures are *reflected* from the real
//! `src/c_abi/net_transport/tcp/mod.zig` exports, so the header cannot disagree
//! with the implementation, and the prose lives here.
//! `zig build gen-header-net-transport-tcp-check` is the staleness gate,
//! `zig build gen-header-net-transport-tcp` is the fixer.
//!
//! The shared frame/context vocabulary (`GlowcapFrame`,
//! `GlowcapManagedFrame`, `GlowcapContext`) is declared in `glowcap_ocapn.h`,
//! which this header includes. Only the three TCP handles and the
//! `glowcap_tcp_*` prototypes are new here.

const std = @import("std");
const c = @import("c_abi_net_transport_tcp");
const header_emit = @import("header_emit.zig");

const Output = @import("output").Output;
pub const outputs = [_]Output{
    .{ .path = "include/glowcap_net_transport_tcp.h", .generate = generate },
};
pub const step_name = "gen-header-net-transport-tcp";

// Every prototype the header emits, in order. `emitFn` refuses a name missing
// here; the comptime guard below holds the table against the real
// `c_abi_net_transport_tcp` declarations in both directions, so a new
// `pub export fn glowcap_tcp_*`
// cannot silently miss the header while the gate stays green.
const emitted_fn_names = [_][]const u8{
    "glowcap_tcp_archive_fingerprint",
    "glowcap_tcp_netlayer_new",
    "glowcap_tcp_netlayer_new_in",
    "glowcap_tcp_transport_provider",
    "glowcap_tcp_netlayer_shutdown",
    "glowcap_tcp_netlayer_release",
    "glowcap_tcp_connect",
    "glowcap_tcp_listen",
    "glowcap_tcp_listener_port",
    "glowcap_tcp_listener_readiness_fd",
    "glowcap_tcp_accept",
    "glowcap_tcp_conn_read_frame",
    "glowcap_tcp_conn_write_frame",
    "glowcap_tcp_conn_shutdown",
    "glowcap_tcp_conn_release",
    "glowcap_tcp_listener_shutdown",
    "glowcap_tcp_listener_release",
    "glowcap_tcp_last_error",
    "glowcap_tcp_clear_last_error",
};

// The reflection machinery is shared with the other header generators; this
// `Spec` binds it to `libglowcap_net_transport_tcp`. The archive has no
// function-pointer typedefs and emits no `#define`s, so `Spec` supplies only
// the module and the prototype table.
const Spec = struct {
    pub const c = @import("c_abi_net_transport_tcp");
    pub const emitted_fns: []const []const u8 = &emitted_fn_names;
};
const E = header_emit.Emit(Spec);
const Buf = header_emit.Buf;
const line = header_emit.line;
const emitDoc = header_emit.emitDoc;
const emitFn = E.emitFn;

// Coverage guard, both directions: every `pub export fn glowcap_tcp_*` in
// `c_abi_net_transport_tcp` must be listed, and every listed name must be real.
comptime {
    E.guardFns("c_abi_net_transport_tcp", "glowcap_tcp_");
}

/// Build the full header text. Caller owns the returned bytes.
fn generate(gpa: std.mem.Allocator) ![]u8 {
    var b: Buf = .empty;
    errdefer b.deinit(gpa);

    try b.appendSlice(gpa,
        \\/* Generated from src/c_abi/net_transport/tcp/mod.zig by tools/gen/header/net_tcp.zig.
        \\   Do not edit by hand: run `zig build gen-header-net-transport-tcp`.
        \\   Function signatures are reflected from the Zig source, so this header
        \\   cannot drift from the implementation.
        \\
        \\   The TCP transport's public C ABI: a separate archive
        \\   (libglowcap_net_transport_tcp) from libglowcap_ocapn (ADR-0022). It is
        \\   a companion, not a superset: it exports only the glowcap_tcp_* family
        \\   and shares no core symbol with libglowcap_ocapn, so a consumer links
        \\   BOTH archives and includes BOTH headers. The shared frame and
        \\   context vocabulary lives in glowcap_ocapn.h (included below) and the
        \\   archives agree on its layout; only the three TCP handles and the
        \\   glowcap_tcp_* prototypes are declared here. The TCP archive has its own
        \\   last-error slot, read through glowcap_tcp_last_error rather than
        \\   glowcap_ocapn's glowcap_last_error. */
        \\#ifndef GLOWCAP_NET_TRANSPORT_TCP_H
        \\#define GLOWCAP_NET_TRANSPORT_TCP_H
        \\
        \\#include <stddef.h>
        \\#include <stdint.h>
        \\#include "glowcap_ocapn.h"
        \\#include "glowcap_transport_provider.h"
        \\
        \\#ifdef __cplusplus
        \\extern "C" {
        \\#endif
        \\
    );

    try emitDoc(&b, gpa,
        \\Orientation: the low-level endpoint API is blocking, cleartext TCP for
        \\a byte-fed GlowcapHost. The same archive also owns the complete
        \\TCP provider package: tcp, keyed-tcp, and noise-tcp. Read a frame with
        \\glowcap_tcp_conn_read_frame, feed its bytes to the Host, and
        \\write Host output with glowcap_tcp_conn_write_frame. The netlayer owns
        \\the I/O backend; create
        \\it, make connections/listeners from it, then release it after every
        \\endpoint made from it is released. There is no TLS.
    );

    try b.appendSlice(gpa,
        \\
        \\/* A TCP netlayer: the one owned I/O backend the endpoints run on.
        \\   Created by glowcap_tcp_netlayer_new; released by
        \\   glowcap_tcp_netlayer_release after every endpoint is released. */
        \\typedef struct GlowcapTcpNetlayer GlowcapTcpNetlayer;
        \\/* One blocking TCP connection carrying one OCapN session, framed on the
        \\   netlayer's codec. One read and one write may run concurrently; calls in
        \\   the same direction are serialized by the archive. Created by
        \\   glowcap_tcp_connect or glowcap_tcp_accept; released by
        \\   glowcap_tcp_conn_release. */
        \\typedef struct GlowcapTcpConn GlowcapTcpConn;
        \\/* A bound TCP listener. Created by glowcap_tcp_listen; released by
        \\   glowcap_tcp_listener_release. */
        \\typedef struct GlowcapTcpListener GlowcapTcpListener;
        \\/* Per-stream TCP policy. A zeroed value disables keepalive. Otherwise
        \\   every field is required and positive. */
        \\typedef struct GlowcapTcpStreamOptions {
        \\  uint32_t keepalive_idle_sec;
        \\  uint32_t keepalive_interval_sec;
        \\  uint32_t keepalive_count;
        \\} GlowcapTcpStreamOptions;
        \\/* Defaults inherited by connections from this netlayer. */
        \\typedef struct GlowcapTcpConfig {
        \\  GlowcapTcpStreamOptions stream;
        \\} GlowcapTcpConfig;
        \\/* Per-operation override carried through GlowcapTransportOperationOptions. */
        \\typedef struct GlowcapTcpOperationOptions {
        \\  GlowcapTcpStreamOptions stream;
        \\} GlowcapTcpOperationOptions;
        \\
    );

    try emitFn(&b, gpa, "glowcap_tcp_archive_fingerprint", &.{}, "Return the exact callable-surface fingerprint of this archive. A dynamic loader must compare it with the binding-generated GLOWCAP_TCP_ARCHIVE_FINGERPRINT before calling any other glowcap_tcp_* function.");
    try emitFn(&b, gpa, "glowcap_tcp_netlayer_new", &.{ "config", "out_netlayer" }, "Create the netlayer handle that owns the blocking I/O backend, allocating\nthrough the library allocator. `config` is required and supplies inherited\nstream defaults. Release with glowcap_tcp_netlayer_release after releasing\nevery endpoint made from it.");
    try emitFn(&b, gpa, "glowcap_tcp_netlayer_new_in", &.{ "context", "config", "out_netlayer" }, "Create a netlayer whose backend and per-connection buffers allocate through\n`context`, with the same required configuration.");
    try emitFn(&b, gpa, "glowcap_tcp_transport_provider", &.{ "netlayer", "out_provider" }, "Fill out_provider with this runtime's complete TCP package: tcp, keyed-tcp,\nand noise-tcp. Install it once with glowcap_driver_add_provider. The driver\nacquires the provider lease through retain and releases it after all transport\nuse retires; release the TCP runtime only after the driver is released.");
    try emitFn(&b, gpa, "glowcap_tcp_netlayer_shutdown", &.{"netlayer"}, "Seal connect admission and request cancellation of a connect already in\nprogress, without freeing netlayer. Call this before joining a foreign thread\ninside glowcap_tcp_connect. Idempotent.");
    try emitFn(&b, gpa, "glowcap_tcp_netlayer_release", &.{"netlayer"}, "Release the netlayer and its I/O backend after every connection and listener\nmade from it is released. First stop new calls, invoke shutdown, and join the\nembedding's operation leases; release must not race call initiation.");
    const optional_diagnostic_doc = "out_error/out_error_len optionally capture this call's diagnostic before an\noff-thread runtime regains control: omit all three diagnostic arguments, or\nprovide out_error_len. It receives the full length; out_error receives at most\nerror_cap - 1 bytes and is NUL-terminated when error_cap is nonzero.";

    try emitFn(&b, gpa, "glowcap_tcp_connect", &.{ "netlayer", "host", "host_len", "port", "options", "codec", "max_frame_bytes", "out_conn", "out_error", "error_cap", "out_error_len" }, "Connect to host:port and return an owned connection framing on `codec`,\nrefusing inbound frames over max_frame_bytes. `options == NULL` inherits the\nnetlayer's stream defaults; a nonnull zeroed value disables keepalive for this\nconnection. Blocking; `host` is borrowed. GLOWCAP_ERR_INVALID_ARGUMENT for a\nbad option, codec, frame cap, or address; GLOWCAP_ERR_TIMEOUT when the connect\ntimeout elapses; GLOWCAP_ERR_IO when the dial fails otherwise. Release with\nglowcap_tcp_conn_release.\n\n" ++ optional_diagnostic_doc);
    try emitFn(&b, gpa, "glowcap_tcp_listen", &.{ "netlayer", "host", "host_len", "port", "out_listener" }, "Bind and listen on host:port (port 0 picks an OS-chosen port; read it back\nwith glowcap_tcp_listener_port). Release with glowcap_tcp_listener_release.");
    try emitFn(&b, gpa, "glowcap_tcp_listener_port", &.{ "listener", "out_port" }, "The OS-resolved local port of a listener (useful after binding to port 0).");
    try emitFn(&b, gpa, "glowcap_tcp_listener_readiness_fd", &.{ "listener", "out_fd" }, "Return the borrowed listening descriptor. Park an external reactor on it and\ncall glowcap_tcp_accept after it is readable. Readiness is advisory: serialize\naccept consumers when the reactor must not park. The listener owns the fd; do\nnot close it or use it after glowcap_tcp_listener_release.");
    try emitFn(&b, gpa, "glowcap_tcp_accept", &.{ "listener", "options", "codec", "max_frame_bytes", "out_conn", "out_error", "error_cap", "out_error_len" }, "Block until a client connects, returning an owned connection framing on\n`codec`. `options` has the same inherit-or-override contract as\nglowcap_tcp_connect.\n\n" ++ optional_diagnostic_doc);
    try emitFn(&b, gpa, "glowcap_tcp_conn_read_frame", &.{ "conn", "out_frame", "out_error", "error_cap", "out_error_len" }, "Block for one whole frame as an owned managed frame. Returns GLOWCAP_ERR_CLOSED\non graceful EOF, GLOWCAP_ERR_IO on a socket fault.\n\n" ++ optional_diagnostic_doc);
    try emitFn(&b, gpa, "glowcap_tcp_conn_write_frame", &.{ "conn", "frame", "out_error", "error_cap", "out_error_len" }, "Write one frame's borrowed bytes and flush. Returns GLOWCAP_ERR_CLOSED after\nshutdown begins.\n\n" ++ optional_diagnostic_doc);
    try emitFn(&b, gpa, "glowcap_tcp_conn_shutdown", &.{"conn"}, "Seal admission and interrupt blocked reads and writes without freeing\nthe connection. May race operations; join the embedding's leases before release.\nIdempotent. Returns GLOWCAP_ERR_IO when the socket cannot be interrupted; the\ntransport last-error slot names the cause.");
    try emitFn(&b, gpa, "glowcap_tcp_conn_release", &.{ "conn", "out_error", "error_cap", "out_error_len" }, "After stopping new calls, invoke shutdown, join admitted operations, and free\nthe handle. Returns the shutdown outcome after completing the ownership sweep.\nRelease must not race call initiation.\n\n" ++ optional_diagnostic_doc);
    try emitFn(&b, gpa, "glowcap_tcp_listener_shutdown", &.{"listener"}, "Seal accept admission and interrupt a blocked accept without freeing the\nlistener. May race operations; join the embedding's leases before release.\nIdempotent; the listener's pre-opened wake channel makes this operation infallible.");
    try emitFn(&b, gpa, "glowcap_tcp_listener_release", &.{"listener"}, "After stopping new calls, invoking shutdown, and joining the embedding's\noperation leases, close and free the listener. Release must not race call initiation.");

    try emitFn(&b, gpa, "glowcap_tcp_last_error", &.{ "out_buf", "cap" }, "Copy the calling thread's last TCP-transport error into out_buf, the tcp\nsibling of glowcap_last_error, reading this archive's own per-thread slot. A\nglowcap_tcp_* call that returns GLOWCAP_ERR_IO records its concrete cause here.\nCopies at most cap-1 bytes and NUL-terminates when cap>0; out_buf NULL or cap 0\nqueries the length. Returns the full message length, or 0 when none is set." ++ header_emit.last_error_freshness_doc);
    try emitFn(&b, gpa, "glowcap_tcp_clear_last_error", &.{}, "Clear the calling thread's TCP-transport last-error slot.");

    try b.appendSlice(gpa,
        \\
        \\#ifdef __cplusplus
        \\}
        \\#endif
        \\
        \\#endif /* GLOWCAP_NET_TRANSPORT_TCP_H */
        \\
    );

    try E.assertAllEmitted(&b, "gen-header-net-transport-tcp");
    return b.toOwnedSlice(gpa);
}
