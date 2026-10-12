//! Generates `include/glowcap_net_transport_onion.h` from the Zig
//! `c_abi_net_transport_onion` source.
//!
//! The onion transport's public C ABI is a separate archive from
//! `libglowcap_ocapn` (ADR-0059), so it gets its own header. As with
//! `tools/gen/header/ocapn.zig`, the function signatures are *reflected* from the
//! real `src/c_abi/net_transport/onion/mod.zig` exports, so the header cannot
//! disagree with the implementation, and the prose lives here.
//! `zig build gen-header-net-transport-onion-check` is the staleness gate,
//! `zig build gen-header-net-transport-onion` is the fixer.
//!
//! The shared frame/peer/context vocabulary (`GlowcapFrame`,
//! `GlowcapManagedFrame`, `GlowcapContext`) is declared in `glowcap_ocapn.h`,
//! which this header includes. Only the three onion handles, the configuration
//! struct, and the `glowcap_onion_*` prototypes are new here.

const std = @import("std");
const c = @import("c_abi_net_transport_onion");
const header_emit = @import("header_emit.zig");

const Output = @import("output").Output;
pub const outputs = [_]Output{
    .{ .path = "include/glowcap_net_transport_onion.h", .generate = generate },
};
pub const step_name = "gen-header-net-transport-onion";

// Every prototype the header emits, in order. `emitFn` refuses a name missing
// here; the comptime guard below holds the table against the real
// `c_abi_net_transport_onion` declarations in both directions, so a new
// `pub export fn glowcap_onion_*` cannot silently miss the header while the gate
// stays green.
const emitted_fn_names = [_][]const u8{
    "glowcap_onion_archive_fingerprint",
    "glowcap_onion_netlayer_new",
    "glowcap_onion_netlayer_new_in",
    "glowcap_onion_transport_provider",
    "glowcap_onion_netlayer_shutdown",
    "glowcap_onion_netlayer_release",
    "glowcap_onion_connect",
    "glowcap_onion_listen",
    "glowcap_onion_listener_wait",
    "glowcap_onion_listener_readiness_fd",
    "glowcap_onion_conn_readiness_fd",
    "glowcap_onion_accept",
    "glowcap_onion_conn_read_frame",
    "glowcap_onion_conn_write_frame",
    "glowcap_onion_conn_shutdown",
    "glowcap_onion_conn_release",
    "glowcap_onion_listener_shutdown",
    "glowcap_onion_listener_release",
    "glowcap_onion_last_error",
    "glowcap_onion_clear_last_error",
};

const Spec = struct {
    pub const c = @import("c_abi_net_transport_onion");
    pub const emitted_fns: []const []const u8 = &emitted_fn_names;
};
const E = header_emit.Emit(Spec);
const Buf = header_emit.Buf;
const emitDoc = header_emit.emitDoc;
const emitFn = E.emitFn;

// Coverage guard, both directions: every `pub export fn glowcap_onion_*` in
// `c_abi_net_transport_onion` must be listed, and every listed name must be real.
comptime {
    E.guardFns("c_abi_net_transport_onion", "glowcap_onion_");
}

/// Build the full header text. Caller owns the returned bytes.
fn generate(gpa: std.mem.Allocator) ![]u8 {
    var b: Buf = .empty;
    errdefer b.deinit(gpa);

    try b.appendSlice(gpa,
        \\/* Generated from src/c_abi/net_transport/onion/mod.zig by tools/gen/header/net_onion.zig.
        \\   Do not edit by hand: run `zig build gen-header-net-transport-onion`.
        \\   Function signatures are reflected from the Zig source, so this header
        \\   cannot drift from the implementation.
        \\
        \\   The onion transport's public C ABI: a separate archive
        \\   (libglowcap_net_transport_onion) from libglowcap_ocapn (ADR-0059). It is
        \\   a companion, not a superset: it exports only the glowcap_onion_* family
        \\   and shares no core symbol with libglowcap_ocapn, so a consumer links
        \\   BOTH archives and includes BOTH headers. The shared frame, peer, and
        \\   context vocabulary lives in glowcap_ocapn.h (included below) and the
        \\   archives agree on its layout; only the onion handles, the configuration
        \\   struct, and the glowcap_onion_* prototypes are declared here. The onion
        \\   family has its own last-error slot, read through
        \\   glowcap_onion_last_error rather than glowcap_ocapn's
        \\   glowcap_last_error. */
        \\#ifndef GLOWCAP_NET_TRANSPORT_ONION_H
        \\#define GLOWCAP_NET_TRANSPORT_ONION_H
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
        \\Orientation: onion is the one netlayer the OCapN draft standardizes, and the
        \\one upstream Spritely Goblins ships, so it is where a glowcap peer and a
        \\Goblins vat meet on ground neither invented. A locator is
        \\ocapn://<serviceid>.onion, and the designator this API takes is that bare
        \\service id: 56 base32 characters with no .onion suffix.
        \\
        \\glowcap starts no Tor. It talks to a daemon the deployment already runs,
        \\over that daemon's SOCKS endpoint to dial and its control endpoint to host,
        \\and it never spawns, supervises, or configures one. A netlayer built against
        \\endpoints nothing is listening on fails at glowcap_onion_netlayer_new's
        \\first use rather than at some later dial.
        \\
        \\Two limits are worth reading before you rely on this. The service id is an
        \\ADDRESS, not an identity: Tor proves the far end of the circuit holds the key
        \\the address encodes, but the CapTP peer is whoever holds the local endpoint
        \\that service forwards to, so nothing here reports a proved peer. And an
        \\accepted circuit carries no client identity at all, because Tor tells a
        \\hidden service nothing about who dialed it, so a partner's claimed location
        \\on this side is unverified. ADR-0108 derives both.
        \\
        \\Otherwise the shape is the TCP transport's (glowcap_net_transport_tcp.h):
        \\the host owns the peer, and this family shuttles whole frames. Every call
        \\that reaches Tor blocks, and a circuit takes seconds rather than
        \\milliseconds, so size your timeouts for Tor and not for a socket.
    );

    try b.appendSlice(gpa,
        \\
        \\/* An onion netlayer: where Tor listens, how to authenticate to it, and the
        \\   one owned I/O backend its streams block on. Created by
        \\   glowcap_onion_netlayer_new; released by glowcap_onion_netlayer_release
        \\   after every endpoint is released. */
        \\typedef struct GlowcapOnionNetlayer GlowcapOnionNetlayer;
        \\/* One onion connection carrying one OCapN session, framed on the codec its
        \\   constructor named. One read and one write may run concurrently; calls
        \\   in the same direction are serialized by the archive. Created by
        \\   glowcap_onion_connect or glowcap_onion_accept; released by
        \\   glowcap_onion_conn_release. */
        \\typedef struct GlowcapOnionConn GlowcapOnionConn;
        \\/* A live onion service: the control session keeping it published plus the
        \\   local endpoint Tor forwards it to. Created by glowcap_onion_listen;
        \\   released by glowcap_onion_listener_release, which also withdraws the
        \\   service. */
        \\typedef struct GlowcapOnionListener GlowcapOnionListener;
        \\
        \\/* How the control endpoint expects to be authenticated. These are the three
        \\   forms a real torrc produces. NONE is what an unauthenticated Unix control
        \\   socket gives, and what upstream Goblins assumes. COOKIE sends the bytes of
        \\   the file CookieAuthFile names, as hexadecimal, and is the common default
        \\   on a distribution's Tor package. PASSWORD sends the cleartext of a
        \\   HashedControlPassword setup. */
        \\#define GLOWCAP_ONION_AUTH_NONE 0u
        \\#define GLOWCAP_ONION_AUTH_COOKIE 1u
        \\#define GLOWCAP_ONION_AUTH_PASSWORD 2u
        \\
        \\/* A version 3 onion service id is always exactly this many characters, so a
        \\   caller can size a fixed buffer for glowcap_onion_listen's out-parameter.
        \\   The key cap bounds Tor's ED25519-V3: private-key form with room to
        \\   spare. */
        \\#define GLOWCAP_ONION_SERVICE_ID_LEN 56u
    );
    try b.print(gpa, "\n#define GLOWCAP_ONION_SERVICE_KEY_CAP {d}u\n", .{c.GLOWCAP_ONION_SERVICE_KEY_CAP});
    try b.appendSlice(gpa,
        \\
        \\/* Everything the netlayer needs to reach Tor, and what to ask for when
        \\   hosting. Zero-initialize the whole struct and set the fields you use, so a
        \\   field added later reads as zero rather than as stack contents. Every
        \\   pointer is borrowed for the duration of the constructor call and copied
        \\   into the handle, so you may free your own strings afterwards.
        \\
        \\   Each endpoint is either an absolute Unix socket path (starting with '/')
        \\   or a host:port. A relative path is refused rather than guessed at.
        \\
        \\   socks is required: a netlayer that cannot dial is not a netlayer.
        \\   control_endpoint empty means dial-only, and glowcap_onion_listen then
        \\   fails rather than pretending to host. auth_secret carries the cookie
        \\   file's bytes or the password's text per auth_kind, and is unread for
        \\   GLOWCAP_ONION_AUTH_NONE. service_key empty asks Tor for a fresh service;
        \\   otherwise pass back the exact bytes an earlier glowcap_onion_listen
        \\   reported. That is how the same onion address comes back across a
        \\   restart. forward empty binds a loopback port and reports it to Tor. */
        \\typedef struct GlowcapOnionConfig {
        \\  const uint8_t *socks;
        \\  size_t socks_len;
        \\  const uint8_t *control_endpoint;
        \\  size_t control_endpoint_len;
        \\  uint32_t auth_kind;
        \\  const uint8_t *auth_secret;
        \\  size_t auth_secret_len;
        \\  const uint8_t *service_key;
        \\  size_t service_key_len;
        \\  const uint8_t *forward;
        \\  size_t forward_len;
        \\} GlowcapOnionConfig;
        \\
        \\
    );

    try emitFn(&b, gpa, "glowcap_onion_archive_fingerprint", &.{}, "Return the exact callable-surface fingerprint. Compare it with the binding-generated GLOWCAP_ONION_ARCHIVE_FINGERPRINT before any other call.");
    try emitFn(&b, gpa, "glowcap_onion_netlayer_new", &.{ "config", "out_netlayer" }, "Create the onion netlayer handle from `config`, allocating through the library\nallocator. The configuration text is copied in, so your strings need not\noutlive this call. GLOWCAP_ERR_INVALID_ARGUMENT for a missing socks endpoint or\nan unknown auth_kind. Release with glowcap_onion_netlayer_release after\nreleasing every endpoint made from it.");
    try emitFn(&b, gpa, "glowcap_onion_netlayer_new_in", &.{ "context", "config", "out_netlayer" }, "Create an onion netlayer whose configuration copy, backend, and per-connection\nbuffers allocate through `context`.");
    try emitFn(&b, gpa, "glowcap_onion_transport_provider", &.{ "netlayer", "out_provider" }, "Fill out_provider with this runtime's complete onion package. Install it once\nwith glowcap_driver_add_provider. The driver acquires the provider lease through\nretain and releases it after all transport use retires; release the onion\nruntime only after the driver is released.");
    try emitFn(&b, gpa, "glowcap_onion_netlayer_shutdown", &.{"netlayer"}, "Seal connect/listen admission and request cancellation of calls already reaching\nTor, without freeing netlayer. Call this before joining foreign threads that may\nbe inside glowcap_onion_connect or glowcap_onion_listen. Idempotent.");
    const optional_diagnostic_doc = "out_error/out_error_len optionally capture this call's diagnostic before an\noff-thread runtime regains control: omit all three diagnostic arguments, or\nprovide out_error_len. It receives the full length; out_error receives at most\nerror_cap - 1 bytes and is NUL-terminated when error_cap is nonzero.";
    try emitFn(&b, gpa, "glowcap_onion_netlayer_release", &.{ "netlayer", "out_error", "error_cap", "out_error_len" }, "Release the onion netlayer after every connection and listener made from it is\nreleased. First stop new calls, invoke shutdown, and join the embedding's\noperation leases; release must not race call initiation.\n\n" ++ optional_diagnostic_doc);

    try emitFn(&b, gpa, "glowcap_onion_connect", &.{ "netlayer", "service_id", "service_id_len", "codec", "max_frame_bytes", "out_conn", "out_error", "error_cap", "out_error_len" }, "Dial the onion service `service_id` through the configured Tor and return an\nowned connection framing on `codec`, refusing inbound frames over\nmax_frame_bytes. `service_id` is the bare 56-character designator, borrowed.\nGLOWCAP_ERR_INVALID_ARGUMENT for a designator that is not a well-formed version\n3 address, which is refused before any socket opens, and for a bad codec or a\nzero frame cap. GLOWCAP_ERR_IO when Tor is not reachable or could not reach the\nservice. Blocking: a circuit takes seconds. Release with\nglowcap_onion_conn_release.\n\n" ++ optional_diagnostic_doc);
    try emitFn(&b, gpa, "glowcap_onion_listen", &.{ "netlayer", "out_service_id", "out_service_id_cap", "out_service_id_len", "out_service_key", "out_service_key_cap", "out_service_key_len", "out_listener", "out_error", "error_cap", "out_error_len" }, "Ask Tor for an onion service and bind its local end. out_service_id receives\nthe designator with no NUL terminator, always GLOWCAP_ONION_SERVICE_ID_LEN\nbytes. out_service_key receives the key that restores this exact service, or\nnothing when the service was restored rather than minted; store those bytes and\npass them back as GlowcapOnionConfig.service_key for a durable onion address.\nThe service output pairs are optional; a NULL buffer with a non-NULL length\nqueries the length. Requires a configured control endpoint:\nGLOWCAP_ERR_INVALID_ARGUMENT without one. Blocking. Release with\nglowcap_onion_listener_release, which also withdraws the service.\n\n" ++ optional_diagnostic_doc);
    try emitFn(&b, gpa, "glowcap_onion_listener_wait", &.{ "listener", "timeout_ms", "out_ready", "out_error", "error_cap", "out_error_len" }, "Wait until glowcap_onion_accept would make progress, up to timeout_ms. Writes 1\ninto out_ready when the next accept should proceed and 0 on timeout.\nThis is what lets a blocking accept loop check a stop flag without closing the\nlistener from another thread.\n\n" ++ optional_diagnostic_doc);
    try emitFn(&b, gpa, "glowcap_onion_listener_readiness_fd", &.{ "listener", "out_fd" }, "Hand back the descriptor this listener's circuits arrive on, so your loop can\npoll instead of blocking. Park on it with whatever your loop uses and call\nglowcap_onion_accept once it is readable. Readiness means an accept can make\nprogress; it is not a nonblocking guarantee, because another accept consumer or\na close can consume that state first. Serialize accept consumers when a loop must\nnot park. An onion service's forward target is an ordinary local socket, which is\nwhy this is a real descriptor rather than a synthesized readiness fd. Owned by the\nlistener: do not close it, and do not use it after glowcap_onion_listener_release.");
    try emitFn(&b, gpa, "glowcap_onion_conn_readiness_fd", &.{ "conn", "out_fd" }, "Hand back the descriptor this connection's bytes flow over. Same contract as\nglowcap_onion_listener_readiness_fd: poll it, and read only when it is readable.\nA whole frame may still need more than one readable turn, in which case the read\nparks for the remainder, so this makes the common case free rather than every\ncase. Owned by the connection.");
    try emitFn(&b, gpa, "glowcap_onion_accept", &.{ "listener", "codec", "max_frame_bytes", "out_conn", "out_error", "error_cap", "out_error_len" }, "Block until Tor forwards a circuit to this service, returning an owned\nconnection framing on `codec`. Same argument and release contract as\nglowcap_onion_connect. The partner's claimed location is unverified on this\nside: Tor tells a hidden service nothing about who dialed it.\n\n" ++ optional_diagnostic_doc);
    try emitFn(&b, gpa, "glowcap_onion_conn_read_frame", &.{ "conn", "out_frame", "out_error", "error_cap", "out_error_len" }, "Block for one whole frame as an owned managed frame. Returns\nGLOWCAP_ERR_CLOSED on graceful EOF.\n\n" ++ optional_diagnostic_doc);
    try emitFn(&b, gpa, "glowcap_onion_conn_write_frame", &.{ "conn", "frame", "out_error", "error_cap", "out_error_len" }, "Write one frame's borrowed bytes to the partner. Returns GLOWCAP_ERR_CLOSED\nafter shutdown begins.\n\n" ++ optional_diagnostic_doc);
    try emitFn(&b, gpa, "glowcap_onion_conn_shutdown", &.{"conn"}, "Seal native admission and interrupt blocked reads and writes without freeing\nthe connection. May race operations; join the embedding's leases before release.\nIdempotent. Returns GLOWCAP_ERR_IO when the socket cannot be interrupted; the\ntransport last-error slot names the cause.");
    try emitFn(&b, gpa, "glowcap_onion_conn_release", &.{ "conn", "out_error", "error_cap", "out_error_len" }, "After stopping new calls, invoke shutdown, join admitted operations, and free\nthe handle. Returns the shutdown outcome after completing the ownership sweep.\nRelease must not race call initiation.\n\n" ++ optional_diagnostic_doc);
    try emitFn(&b, gpa, "glowcap_onion_listener_shutdown", &.{"listener"}, "Seal native accept admission and interrupt a blocked accept without freeing the\nlistener or withdrawing its service. May race operations; join the embedding's\nleases before release. Idempotent; the listener's pre-opened wake channel makes\nthis operation infallible.");
    try emitFn(&b, gpa, "glowcap_onion_listener_release", &.{ "listener", "out_error", "error_cap", "out_error_len" }, "After stopping new calls, invoking shutdown, and joining the embedding's\noperation leases, withdraw the service and free the listener. Release must not\nrace call initiation. This is the one release in the family with an effect a\npartner can observe: the address stops being published.\n\n" ++ optional_diagnostic_doc);

    try emitFn(&b, gpa, "glowcap_onion_last_error", &.{ "out_buf", "cap" }, "Copy the calling thread's last onion-transport error into out_buf, the onion\nsibling of glowcap_last_error, reading this archive's own per-thread slot. A\nglowcap_onion_* call that returns a cause-bearing code records it here. Copies\nat most cap-1 bytes and NUL-terminates when cap>0; out_buf NULL or cap 0 queries\nthe length. Returns the full message length, or 0 when none is set." ++ header_emit.last_error_freshness_doc);
    try emitFn(&b, gpa, "glowcap_onion_clear_last_error", &.{}, "Clear the calling thread's onion-transport last-error slot.");

    try b.appendSlice(gpa,
        \\
        \\#ifdef __cplusplus
        \\}
        \\#endif
        \\
        \\#endif /* GLOWCAP_NET_TRANSPORT_ONION_H */
        \\
    );

    try E.assertAllEmitted(&b, "gen-header-net-transport-onion");
    return b.toOwnedSlice(gpa);
}
