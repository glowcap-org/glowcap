//! Generates `include/pancake_net_transport_tcp.h` from the Zig
//! `c_abi_net_transport_tcp` source.
//!
//! The TCP transport's public C ABI is a separate archive from
//! `libpancake_ocapn` (ADR-0059), so it gets its own header. As with
//! `tools/gen/header/ocapn.zig`, the function signatures are *reflected* from the real
//! `src/c_abi/net_transport/tcp/mod.zig` exports, so the header cannot disagree
//! with the implementation, and the prose lives here.
//! `zig build gen-header-net-transport-tcp-check` is the staleness gate;
//! `zig build gen-header-net-transport-tcp` is the fixer.
//!
//! The shared frame/context vocabulary (`PancakeFrame`,
//! `PancakeManagedFrame`, `PancakeContext`) is declared in `pancake_ocapn.h`,
//! which this header includes; only the three TCP handles and the
//! `pancake_tcp_*` prototypes are new here.

const std = @import("std");
const c = @import("c_abi_net_transport_tcp");
const header_emit = @import("header_emit.zig");

const Output = @import("output").Output;
pub const outputs = [_]Output{
    .{ .path = "include/pancake_net_transport_tcp.h", .generate = generate },
};
pub const step_name = "gen-header-net-transport-tcp";

// Every prototype the header emits, in order. `emitFn` refuses a name missing
// here; the comptime guard below holds the table against the real
// `c_abi_net_transport_tcp` declarations in both directions, so a new
// `pub export fn pancake_tcp_*`
// cannot silently miss the header while the gate stays green.
const emitted_fn_names = [_][]const u8{
    "pancake_tcp_netlayer_new",
    "pancake_tcp_netlayer_new_in",
    "pancake_tcp_transport_provider",
    "pancake_tcp_netlayer_shutdown",
    "pancake_tcp_netlayer_release",
    "pancake_tcp_connect",
    "pancake_tcp_connect_with_diagnostic",
    "pancake_tcp_listen",
    "pancake_tcp_listener_port",
    "pancake_tcp_listener_readiness_fd",
    "pancake_tcp_accept",
    "pancake_tcp_accept_with_diagnostic",
    "pancake_tcp_conn_read_frame",
    "pancake_tcp_conn_read_frame_with_diagnostic",
    "pancake_tcp_conn_write_frame",
    "pancake_tcp_conn_write_frame_with_diagnostic",
    "pancake_tcp_conn_shutdown",
    "pancake_tcp_conn_release",
    "pancake_tcp_listener_shutdown",
    "pancake_tcp_listener_release",
    "pancake_tcp_last_error",
    "pancake_tcp_clear_last_error",
};

// The reflection machinery is shared with the other header generators; this
// `Spec` binds it to `libpancake_net_transport_tcp`. The archive has no
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

// Coverage guard, both directions: every `pub export fn pancake_tcp_*` in
// `c_abi_net_transport_tcp` must be listed, and every listed name must be real.
comptime {
    E.guardFns("c_abi_net_transport_tcp", "pancake_tcp_");
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
        \\   (libpancake_net_transport_tcp) from libpancake_ocapn (ADR-0059). It is
        \\   a companion, not a superset: it exports only the pancake_tcp_* family
        \\   and shares no core symbol with libpancake_ocapn, so a consumer links
        \\   BOTH archives and includes BOTH headers. The shared frame and
        \\   context vocabulary lives in pancake_ocapn.h (included below) and the
        \\   archives agree on its layout; only the three TCP handles and the
        \\   pancake_tcp_* prototypes are declared here. The TCP archive has its own
        \\   last-error slot, read through pancake_tcp_last_error rather than
        \\   pancake_ocapn's pancake_last_error. */
        \\#ifndef PANCAKE_NET_TRANSPORT_TCP_H
        \\#define PANCAKE_NET_TRANSPORT_TCP_H
        \\
        \\#include <stddef.h>
        \\#include <stdint.h>
        \\#include "pancake_ocapn.h"
        \\#include "pancake_transport_provider.h"
        \\
        \\#ifdef __cplusplus
        \\extern "C" {
        \\#endif
        \\
    );

    try emitDoc(&b, gpa,
        \\Orientation: the low-level endpoint API is blocking, cleartext TCP for
        \\a byte-fed PancakeHost. The same archive also owns the complete native
        \\TCP provider package: tcp, keyed-tcp, and noise-tcp. Read a frame with
        \\pancake_tcp_conn_read_frame, feed its bytes to the Host, and
        \\write Host output with pancake_tcp_conn_write_frame. The netlayer owns
        \\the I/O backend; create
        \\it, make connections/listeners from it, then release it after every
        \\endpoint made from it is released. There is no TLS.
    );

    try b.appendSlice(gpa,
        \\
        \\/* A TCP netlayer: the one owned I/O backend the endpoints run on.
        \\   Created by pancake_tcp_netlayer_new; released by
        \\   pancake_tcp_netlayer_release after every endpoint is released. */
        \\typedef struct PancakeTcpNetlayer PancakeTcpNetlayer;
        \\/* One blocking TCP connection carrying one OCapN session, framed on the
        \\   netlayer's codec. One read and one write may run concurrently; calls in
        \\   the same direction are serialized by the archive. Created by
        \\   pancake_tcp_connect or pancake_tcp_accept; released by
        \\   pancake_tcp_conn_release. */
        \\typedef struct PancakeTcpConn PancakeTcpConn;
        \\/* A bound TCP listener. Created by pancake_tcp_listen; released by
        \\   pancake_tcp_listener_release. */
        \\typedef struct PancakeTcpListener PancakeTcpListener;
        \\/* Per-stream TCP policy. A zeroed value disables keepalive. Otherwise
        \\   every field is required and positive. */
        \\typedef struct PancakeTcpStreamOptions {
        \\  uint32_t keepalive_idle_sec;
        \\  uint32_t keepalive_interval_sec;
        \\  uint32_t keepalive_count;
        \\} PancakeTcpStreamOptions;
        \\/* Defaults inherited by connections from this netlayer. */
        \\typedef struct PancakeTcpConfig {
        \\  PancakeTcpStreamOptions stream;
        \\} PancakeTcpConfig;
        \\/* Per-operation override carried through PancakeTransportOperationOptions. */
        \\typedef struct PancakeTcpOperationOptions {
        \\  PancakeTcpStreamOptions stream;
        \\} PancakeTcpOperationOptions;
        \\
    );

    try emitFn(&b, gpa, "pancake_tcp_netlayer_new", &.{ "config", "out_netlayer" }, "Create the netlayer handle that owns the blocking I/O backend, allocating\nthrough the library allocator. `config` is required and supplies inherited\nstream defaults. Release with pancake_tcp_netlayer_release after releasing\nevery endpoint made from it.");
    try emitFn(&b, gpa, "pancake_tcp_netlayer_new_in", &.{ "context", "config", "out_netlayer" }, "Create a netlayer whose backend and per-connection buffers allocate through\n`context`, with the same required configuration.");
    try emitFn(&b, gpa, "pancake_tcp_transport_provider", &.{ "netlayer", "out_provider" }, "Fill out_provider with this runtime's complete TCP package: tcp, keyed-tcp,\nand noise-tcp. Install it once with pancake_driver_add_provider. The driver\nacquires the provider lease through retain and releases it after all transport\nuse retires; release the TCP runtime only after the driver is released.");
    try emitFn(&b, gpa, "pancake_tcp_netlayer_shutdown", &.{"netlayer"}, "Seal connect admission and request cancellation of a connect already in\nprogress, without freeing netlayer. Call this before joining a foreign thread\ninside pancake_tcp_connect. Idempotent.");
    try emitFn(&b, gpa, "pancake_tcp_netlayer_release", &.{"netlayer"}, "Release the netlayer and its I/O backend after every connection and listener\nmade from it is released. First stop new calls, invoke shutdown, and join the\nembedding's operation leases; release must not race call initiation.");
    const diagnosed_doc = "The same operation as its unsuffixed sibling, plus an atomic diagnostic\ncapture for runtimes that dispatch native calls to worker threads. out_error_len\nis required and receives the full diagnostic length; out_error receives at most\nerror_cap - 1 bytes and is NUL-terminated when error_cap is nonzero.";

    try emitFn(&b, gpa, "pancake_tcp_connect", &.{ "netlayer", "host", "host_len", "port", "options", "codec", "max_frame_bytes", "out_conn" }, "Connect to host:port and return an owned connection framing on `codec`,\nrefusing inbound frames over max_frame_bytes. `options == NULL` inherits the\nnetlayer's stream defaults; a nonnull zeroed value disables keepalive for this\nconnection. Blocking; `host` is borrowed. PANCAKE_ERR_INVALID_ARGUMENT for a\nbad option, codec, frame cap, or address; PANCAKE_ERR_IO (see\npancake_tcp_last_error) when the dial fails. Release with pancake_tcp_conn_release.");
    try emitFn(&b, gpa, "pancake_tcp_connect_with_diagnostic", &.{ "netlayer", "host", "host_len", "port", "options", "codec", "max_frame_bytes", "out_conn", "out_error", "error_cap", "out_error_len" }, diagnosed_doc);
    try emitFn(&b, gpa, "pancake_tcp_listen", &.{ "netlayer", "host", "host_len", "port", "out_listener" }, "Bind and listen on host:port (port 0 picks an OS-chosen port; read it back\nwith pancake_tcp_listener_port). Release with pancake_tcp_listener_release.");
    try emitFn(&b, gpa, "pancake_tcp_listener_port", &.{ "listener", "out_port" }, "The OS-resolved local port of a listener (useful after binding to port 0).");
    try emitFn(&b, gpa, "pancake_tcp_listener_readiness_fd", &.{ "listener", "out_fd" }, "Return the borrowed listening descriptor. Park an external reactor on it and\ncall pancake_tcp_accept after it is readable. Readiness is advisory: serialize\naccept consumers when the reactor must not park. The listener owns the fd; do\nnot close it or use it after pancake_tcp_listener_release.");
    try emitFn(&b, gpa, "pancake_tcp_accept", &.{ "listener", "options", "codec", "max_frame_bytes", "out_conn" }, "Block until a client connects, returning an owned connection framing on\n`codec`. `options` has the same inherit-or-override contract as pancake_tcp_connect.");
    try emitFn(&b, gpa, "pancake_tcp_accept_with_diagnostic", &.{ "listener", "options", "codec", "max_frame_bytes", "out_conn", "out_error", "error_cap", "out_error_len" }, diagnosed_doc);
    try emitFn(&b, gpa, "pancake_tcp_conn_read_frame", &.{ "conn", "out_frame" }, "Block for one whole frame as an owned managed frame. Returns PANCAKE_ERR_CLOSED\non graceful EOF, PANCAKE_ERR_IO on a socket fault.");
    try emitFn(&b, gpa, "pancake_tcp_conn_read_frame_with_diagnostic", &.{ "conn", "out_frame", "out_error", "error_cap", "out_error_len" }, diagnosed_doc);
    try emitFn(&b, gpa, "pancake_tcp_conn_write_frame", &.{ "conn", "frame" }, "Write one frame's borrowed bytes and flush. Returns PANCAKE_ERR_CLOSED after\nshutdown begins.");
    try emitFn(&b, gpa, "pancake_tcp_conn_write_frame_with_diagnostic", &.{ "conn", "frame", "out_error", "error_cap", "out_error_len" }, diagnosed_doc);
    try emitFn(&b, gpa, "pancake_tcp_conn_shutdown", &.{"conn"}, "Seal native admission and interrupt blocked reads and writes without freeing\nthe connection. May race operations; join the embedding's leases before release.\nIdempotent. Returns PANCAKE_ERR_IO when the socket cannot be interrupted; the\ntransport last-error slot names the cause.");
    try emitFn(&b, gpa, "pancake_tcp_conn_release", &.{"conn"}, "After stopping new calls, invoke shutdown, join admitted operations, and free\nthe handle. Returns the shutdown outcome after completing the ownership sweep.\nRelease must not race call initiation.");
    try emitFn(&b, gpa, "pancake_tcp_listener_shutdown", &.{"listener"}, "Seal native accept admission and interrupt a blocked accept without freeing the\nlistener. May race operations; join the embedding's leases before release.\nIdempotent; the listener's pre-opened wake channel makes this operation infallible.");
    try emitFn(&b, gpa, "pancake_tcp_listener_release", &.{"listener"}, "After stopping new calls, invoking shutdown, and joining the embedding's\noperation leases, close and free the listener. Release must not race call initiation.");

    try emitFn(&b, gpa, "pancake_tcp_last_error", &.{ "out_buf", "cap" }, "Copy the calling thread's last TCP-transport error into out_buf, the tcp\nsibling of pancake_last_error, reading this archive's own per-thread slot. A\npancake_tcp_* call that returns PANCAKE_ERR_IO records its concrete cause here.\nCopies at most cap-1 bytes and NUL-terminates when cap>0; out_buf NULL or cap 0\nqueries the length. Returns the full message length, or 0 when none is set.");
    try emitFn(&b, gpa, "pancake_tcp_clear_last_error", &.{}, "Clear the calling thread's TCP-transport last-error slot.");

    try b.appendSlice(gpa,
        \\
        \\#ifdef __cplusplus
        \\}
        \\#endif
        \\
        \\#endif /* PANCAKE_NET_TRANSPORT_TCP_H */
        \\
    );

    try E.assertAllEmitted(&b, "gen-header-net-transport-tcp");
    return b.toOwnedSlice(gpa);
}
