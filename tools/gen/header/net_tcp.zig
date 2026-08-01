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
    "pancake_tcp_netlayer_release",
    "pancake_tcp_connect",
    "pancake_tcp_listen",
    "pancake_tcp_listener_port",
    "pancake_tcp_accept",
    "pancake_tcp_conn_read_frame",
    "pancake_tcp_conn_write_frame",
    "pancake_tcp_conn_release",
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
        \\   pancake_tcp_* prototypes are declared here. The TCP family has its own
        \\   last-error slot, read through pancake_tcp_last_error rather than
        \\   pancake_ocapn's pancake_last_error. */
        \\#ifndef PANCAKE_NET_TRANSPORT_TCP_H
        \\#define PANCAKE_NET_TRANSPORT_TCP_H
        \\
        \\#include <stddef.h>
        \\#include <stdint.h>
        \\#include "pancake_ocapn.h"
        \\
        \\#ifdef __cplusplus
        \\extern "C" {
        \\#endif
        \\
    );

    try emitDoc(&b, gpa,
        \\Orientation: blocking, cleartext TCP for a byte-fed PancakeHost. Read a
        \\frame with pancake_tcp_conn_read_frame, feed its bytes to the Host, and
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
        \\   netlayer's codec. Created by pancake_tcp_connect or pancake_tcp_accept;
        \\   released by pancake_tcp_conn_release. */
        \\typedef struct PancakeTcpConn PancakeTcpConn;
        \\/* A bound TCP listener. Created by pancake_tcp_listen; released by
        \\   pancake_tcp_listener_release. */
        \\typedef struct PancakeTcpListener PancakeTcpListener;
        \\
    );

    try emitFn(&b, gpa, "pancake_tcp_netlayer_new", &.{"out_netlayer"}, "Create the netlayer handle that owns the blocking I/O backend, allocating\nthrough the library allocator. Release with pancake_tcp_netlayer_release\nafter releasing every endpoint made from it.");
    try emitFn(&b, gpa, "pancake_tcp_netlayer_new_in", &.{ "context", "out_netlayer" }, "Create a netlayer whose backend and per-connection buffers allocate through\n`context`.");
    try emitFn(&b, gpa, "pancake_tcp_netlayer_release", &.{"netlayer"}, "Release the netlayer and its I/O backend. Every connection and listener\nmade from it must already be released.");
    try emitFn(&b, gpa, "pancake_tcp_connect", &.{ "netlayer", "host", "host_len", "port", "codec", "max_frame_bytes", "out_conn" }, "Connect to host:port and return an owned connection framing on `codec`,\nrefusing inbound frames over max_frame_bytes. Blocking; `host` is borrowed.\nPANCAKE_ERR_INVALID_ARGUMENT for a bad codec, a zero frame cap, or an\nunparseable address; PANCAKE_ERR_IO (see pancake_tcp_last_error) when the\ndial fails. Release with pancake_tcp_conn_release.");
    try emitFn(&b, gpa, "pancake_tcp_listen", &.{ "netlayer", "host", "host_len", "port", "out_listener" }, "Bind and listen on host:port (port 0 picks an OS-chosen port; read it back\nwith pancake_tcp_listener_port). Release with pancake_tcp_listener_release.");
    try emitFn(&b, gpa, "pancake_tcp_listener_port", &.{ "listener", "out_port" }, "The OS-resolved local port of a listener (useful after binding to port 0).");
    try emitFn(&b, gpa, "pancake_tcp_accept", &.{ "listener", "codec", "max_frame_bytes", "out_conn" }, "Block until a client connects, returning an owned connection framing on\n`codec`. Same argument and release contract as pancake_tcp_connect.");
    try emitFn(&b, gpa, "pancake_tcp_conn_read_frame", &.{ "conn", "out_frame" }, "Block for one whole frame as an owned managed frame. Returns PANCAKE_ERR_CLOSED\non graceful EOF, PANCAKE_ERR_IO on a socket fault.");
    try emitFn(&b, gpa, "pancake_tcp_conn_write_frame", &.{ "conn", "frame" }, "Write one frame's borrowed bytes and flush.");
    try emitFn(&b, gpa, "pancake_tcp_conn_release", &.{"conn"}, "Close the connection and free the handle; do not use `conn` afterward.");
    try emitFn(&b, gpa, "pancake_tcp_listener_release", &.{"listener"}, "Close the listener and free the handle; do not use `listener` afterward.");

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
