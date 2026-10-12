//! Generates `include/glowcap_net_transport_iroh.h` from the Zig
//! `c_abi_net_transport_iroh` source.
//!
//! The public iroh transport C ABI is a separate archive from
//! `libglowcap_ocapn` (ADR-0055, ADR-0059), so it gets its own header. As with
//! `tools/gen/header/ocapn.zig`, the function signatures are *reflected* from the real
//! `src/c_abi/net_transport/iroh/mod.zig` exports, so the header cannot disagree
//! with the implementation, and the prose lives here.
//! `zig build gen-header-net-transport-iroh-check` is the staleness gate,
//! `zig build gen-header-net-transport-iroh` is the fixer. Both run cargo-free:
//! the generator reflects types only and links the sidecar stubs
//! (`tools/gen/stub/iroh_sidecar.zig`).
//!
//! The shared frame/peer/context vocabulary (`GlowcapFrame`,
//! `GlowcapManagedFrame`, `GlowcapContext`) is declared in `glowcap_ocapn.h`,
//! which this header includes. Only the two iroh handles and the
//! `glowcap_iroh_*` prototypes are new here.

const std = @import("std");
const c = @import("c_abi_net_transport_iroh");
const header_emit = @import("header_emit.zig");

const Output = @import("output").Output;
pub const outputs = [_]Output{
    .{ .path = "include/glowcap_net_transport_iroh.h", .generate = generate },
};
pub const step_name = "gen-header-net-transport-iroh";

// Every prototype the header emits, in order. `emitFn` refuses a name missing
// here; the comptime guard below holds the table against the real
// `c_abi_net_transport_iroh` declarations in both directions, so a new
// `pub export fn glowcap_iroh_*`
// cannot silently miss the header while the gate stays green.
const emitted_fn_names = [_][]const u8{
    "glowcap_iroh_archive_fingerprint",
    "glowcap_iroh_netlayer_new",
    "glowcap_iroh_netlayer_new_in",
    "glowcap_iroh_netlayer_close",
    "glowcap_iroh_netlayer_release",
    "glowcap_iroh_netlayer_node_id",
    "glowcap_iroh_netlayer_direct_addrs",
    "glowcap_iroh_conn_release",
    "glowcap_iroh_conn_id",
    "glowcap_iroh_conn_remote_node_id",
    "glowcap_iroh_netlayer_readiness_fd",
    "glowcap_iroh_netlayer_drain_ready",
    "glowcap_iroh_netlayer_try_accept",
    "glowcap_iroh_netlayer_start_connect",
    "glowcap_iroh_netlayer_finish_connect",
    "glowcap_iroh_netlayer_cancel_connect",
    "glowcap_iroh_conn_try_read",
    "glowcap_iroh_conn_try_write",
    "glowcap_iroh_transport_provider",
    "glowcap_iroh_last_error",
    "glowcap_iroh_clear_last_error",
};

// The reflection machinery is shared with the other header generators; this
// `Spec` binds it to `libglowcap_net_transport_iroh`. No function-pointer
// typedefs and no `#define`s, so it supplies only the module and the table.
const Spec = struct {
    pub const c = @import("c_abi_net_transport_iroh");
    pub const emitted_fns: []const []const u8 = &emitted_fn_names;
};
const E = header_emit.Emit(Spec);
const Buf = header_emit.Buf;
const emitDoc = header_emit.emitDoc;
const emitFn = E.emitFn;

// Coverage guard, both directions: every `pub export fn glowcap_iroh_*` in
// `c_abi_net_transport_iroh` must be listed, and every listed name must be real.
comptime {
    E.guardFns("c_abi_net_transport_iroh", "glowcap_iroh_");
}

/// Build the full header text. Caller owns the returned bytes.
fn generate(gpa: std.mem.Allocator) ![]u8 {
    var b: Buf = .empty;
    errdefer b.deinit(gpa);

    try b.appendSlice(gpa,
        \\/* Generated from src/c_abi/net_transport/iroh/mod.zig by tools/gen/header/iroh.zig.
        \\   Do not edit by hand: run `zig build gen-header-net-transport-iroh`.
        \\   Function signatures are reflected from the Zig source, so this header
        \\   cannot drift from the implementation.
        \\
        \\   The iroh transport's public C ABI: a separate artifact
        \\   (libglowcap_net_transport_iroh) that links the Rust iroh sidecar
        \\   (ADR-0055). It is a companion, not a superset: it exports only the
        \\   glowcap_iroh_* family and shares no core symbol with libglowcap_ocapn,
        \\   so a consumer links BOTH archives and includes BOTH headers. The
        \\   shared frame, peer, and context vocabulary lives in glowcap_ocapn.h
        \\   (included below) and the archives agree on its layout; only the two
        \\   iroh handles and the glowcap_iroh_* prototypes are declared here. The
        \\   iroh family has its own last-error slot, read through
        \\   glowcap_iroh_last_error rather than glowcap_ocapn's glowcap_last_error.
        \\
        \\   This is NOT transports/iroh/include/glowcap_iroh_sidecar.h, which is
        \\   the sidecar's internal byte-level seam (glowcap_iroh_sidecar_connect_blocking,
        \\   glowcap_iroh_sidecar_conn_read, ...). This is the frame-level public
        \\   surface (glowcap_iroh_netlayer_*, glowcap_iroh_conn_try_read, ...). */
        \\#ifndef GLOWCAP_NET_TRANSPORT_IROH_H
        \\#define GLOWCAP_NET_TRANSPORT_IROH_H
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
        \\Orientation: the iroh transport is the host-driven netlayer boundary's
        \\encrypted-QUIC sibling of the TCP endpoints in glowcap_net_transport_tcp.h.
        \\It has one I/O model: an event-driven readiness loop, armed when the
        \\netlayer is created, that serves many connections from one host thread.
        \\The netlayer hands back a single OS readiness fd
        \\(glowcap_iroh_netlayer_readiness_fd); register it with your poller, and
        \\when it signals, drain the pending records with
        \\glowcap_iroh_netlayer_drain_ready, claim accepts with
        \\glowcap_iroh_netlayer_try_accept, and move raw bytes with the
        \\non-blocking glowcap_iroh_conn_try_read / _try_write. You frame those
        \\bytes yourself, feeding a GlowcapHost session and writing its
        \\outbound frames back — the same shape the TCP consumer uses. No call ever
        \\parks on a specific connection, so releasing one never races a read.
        \\
        \\The one difference from TCP is addressing: there is no host:port. A
        \\partner is dialed by its endpoint id — the canonical lowercase-hex
        \\designator glowcap_iroh_netlayer_node_id prints. Whether you also need a
        \\direct-address hint string from glowcap_iroh_netlayer_direct_addrs
        \\depends on the reachability the netlayer was created with: a
        \\GLOWCAP_IROH_REACH_DIRECT endpoint dials by id plus hints, while a
        \\discovery endpoint resolves the partner by id alone. Carry both in the
        \\OCapN locator a peer signs (transport "iroh", the id as designator, the
        \\hints under "direct-addresses").
        \\
        \\Those same calls are the raw byte channel a byte-transparent relay
        \\needs for an iroh leg (ADR-0086). One leg composes
        \\glowcap_iroh_netlayer_new, its readiness_fd and drain_ready, the
        \\_start_connect / _finish_connect lifecycle, _conn_try_read /
        \\_conn_try_write, then _conn_release and
        \\glowcap_iroh_netlayer_release. There is no channel object over them,
        \\because the wait a channel needs is your own reactor's, and only the
        \\caller can hold it.
        \\
        \\Lifetime: release every connection before the netlayer that minted it.
        \\Threading: a connection is single-owner like a peer; serialize calls on
        \\one onto one thread. Run the netlayer's readiness wait (your poll on the
        \\fd) and drain_ready on one thread per netlayer, serialized against
        \\glowcap_iroh_netlayer_release.
    );

    try b.appendSlice(gpa,
        \\
        \\/* An iroh netlayer: one bound QUIC endpoint plus the sidecar runtime
        \\   driving it. Created by glowcap_iroh_netlayer_new; released by
        \\   glowcap_iroh_netlayer_release after every connection is released. */
        \\typedef struct GlowcapIrohNetlayer GlowcapIrohNetlayer;
        \\/* One QUIC connection carrying one OCapN session. Created by
        \\   glowcap_iroh_netlayer_finish_connect or claimed with
        \\   glowcap_iroh_netlayer_try_accept; released by
        \\   glowcap_iroh_conn_release. */
        \\typedef struct GlowcapIrohConn GlowcapIrohConn;
        \\
        \\/* Reachability postures for glowcap_iroh_netlayer_new. The caller always
        \\   passes one; there is no default. A glowcap peer never turns on relays
        \\   or a discovery service as a hidden implementation detail; the host
        \\   chooses, in the open, how the endpoint becomes reachable.
        \\     DIRECT             relay-less, lookup-less; dial by id plus
        \\                        explicit address hints (loopback/LAN).
        \\     DISCOVERY          number-0 relays + DNS/pkarr discovery; a peer is
        \\                        dialable by id alone over the internet, with
        \\                        hole-punching and NAT traversal.
        \\     DISCOVERY_NO_RELAY DNS/pkarr discovery without relays.
        \\     LOCAL_DISCOVERY    in-process shared address book; resolves by id
        \\                        alone with no relay, DNS, or hints. For tests
        \\                        and same-process embeddings, never the internet. */
        \\
    );
    // Reflected from the Zig module (which mirrors the resident's enum), so
    // the header cannot disagree with the values the archive accepts.
    try b.print(gpa, "#define GLOWCAP_IROH_REACH_DIRECT {d}u\n", .{c.GLOWCAP_IROH_REACH_DIRECT});
    try b.print(gpa, "#define GLOWCAP_IROH_REACH_DISCOVERY {d}u\n", .{c.GLOWCAP_IROH_REACH_DISCOVERY});
    try b.print(gpa, "#define GLOWCAP_IROH_REACH_DISCOVERY_NO_RELAY {d}u\n", .{c.GLOWCAP_IROH_REACH_DISCOVERY_NO_RELAY});
    try b.print(gpa, "#define GLOWCAP_IROH_REACH_LOCAL_DISCOVERY {d}u\n", .{c.GLOWCAP_IROH_REACH_LOCAL_DISCOVERY});
    try b.print(gpa, "#define GLOWCAP_IROH_NODE_ID_BYTES {d}u\n", .{c.GLOWCAP_IROH_NODE_ID_BYTES});
    try b.print(gpa, "#define GLOWCAP_IROH_MAX_DIRECT_ADDRESS_BYTES {d}u\n", .{c.GLOWCAP_IROH_MAX_DIRECT_ADDRESS_BYTES});
    try b.print(gpa, "#define GLOWCAP_IROH_READ_CHUNK_BYTES {d}u\n", .{c.GLOWCAP_IROH_READ_CHUNK_BYTES});
    try b.appendSlice(gpa,
        \\
        \\/* The posture a Host redeems a hint-less handoff give under until the
        \\   embedder sets one: DISCOVERY, the maximal-reach choice. The netlayer
        \\   constructor still takes no default; this names the redeem knob's one
        \\   starting value so every consumer initializes from the same fact. */
        \\
    );
    try b.print(gpa, "#define GLOWCAP_IROH_REACH_REDEEM_DEFAULT {d}u\n", .{c.GLOWCAP_IROH_REACH_REDEEM_DEFAULT});
    try b.appendSlice(gpa,
        \\
        \\/* Readiness event bits (ADR-0057). The netlayer's loop serves many
        \\   connections from one host thread: park on the readiness fd from
        \\   glowcap_iroh_netlayer_readiness_fd, and when it signals, drain records
        \\   with glowcap_iroh_netlayer_drain_ready, claim accepts with
        \\   glowcap_iroh_netlayer_try_accept, and drive each ready connection with
        \\   the non-blocking glowcap_iroh_conn_try_read / _try_write (raw bytes you
        \\   frame with a GlowcapHost session, as for TCP). No call parks on a specific
        \\   connection, so releasing one never races a read. The would-block code
        \\   is the shared GLOWCAP_ERR_WOULD_BLOCK from glowcap_ocapn.h. */
        \\
    );
    try b.print(gpa, "#define GLOWCAP_IROH_EV_READABLE {d}u\n", .{c.GLOWCAP_IROH_EV_READABLE});
    try b.print(gpa, "#define GLOWCAP_IROH_EV_WRITABLE {d}u\n", .{c.GLOWCAP_IROH_EV_WRITABLE});
    try b.print(gpa, "#define GLOWCAP_IROH_EV_CLOSED {d}u\n", .{c.GLOWCAP_IROH_EV_CLOSED});
    try b.print(gpa, "#define GLOWCAP_IROH_EV_ACCEPT {d}u\n", .{c.GLOWCAP_IROH_EV_ACCEPT});
    try b.print(gpa, "#define GLOWCAP_IROH_EV_CONNECT {d}u\n", .{c.GLOWCAP_IROH_EV_CONNECT});
    try b.appendSlice(gpa,
        \\
        \\/* One readiness record from glowcap_iroh_netlayer_drain_ready. subject
        \\   is zero for accept, the caller request id for EV_CONNECT, and otherwise
        \\   the stable identity returned by glowcap_iroh_conn_id. */
        \\typedef struct GlowcapIrohReadyEvent {
        \\  uintptr_t subject;
        \\  uint32_t events;
        \\} GlowcapIrohReadyEvent;
        \\
        \\/* One iroh endpoint's configuration, passed to glowcap_iroh_netlayer_new /
        \\   _new_in. reachability is mandatory (one of GLOWCAP_IROH_REACH_*; an unknown
        \\   value is refused). connect_timeout_ms is the per-endpoint stream-
        \\   establishment deadline in milliseconds — the dial's connect + first-stream
        \\   open and each accepted stream ride it — with 0 meaning glowcap's thirty seconds. Every 0 here is
        \\   glowcap's number, never the QUIC stack's own, a distinction that matters most
        \\   for idle_timeout_ms, where glowcap's replaces a longer one the stack would
        \\   otherwise use.
        \\   idle_timeout_ms bounds how long a connection survives without a packet from
        \\   the far end, which decides how quickly a peer that was killed rather than
        \\   closed stops counting as present: such a peer sends nothing, and UDP has no
        \\   equivalent of the FIN a dying TCP process gets from the operating system, so
        \\   nothing else ends the connection. 0 keeps glowcap's fifteen seconds; read a live
        \\   session as presence and you want a shorter one of your own.
        \\   Zero-initialize the whole struct before filling the fields you set (e.g.
        \\   `GlowcapIrohConfig cfg = {0};`), so a field added in a later version
        \\   defaults to 0 rather than reading stack garbage. */
        \\typedef struct GlowcapIrohConfig {
        \\  uint32_t reachability;
        \\  uint64_t connect_timeout_ms;
        \\  uint64_t idle_timeout_ms;
        \\  uint32_t worker_threads;
        \\} GlowcapIrohConfig;
        \\
        \\
    );

    const optional_diagnostic_doc = "out_error/out_error_len optionally capture this call's diagnostic before an\noff-thread runtime regains control: omit all three diagnostic arguments, or\nprovide out_error_len. It receives the full length; out_error receives at most\nerror_cap - 1 bytes and is NUL-terminated when error_cap is nonzero.";
    try emitFn(&b, gpa, "glowcap_iroh_archive_fingerprint", &.{}, "Return the exact callable-surface fingerprint. Compare it with the binding-generated GLOWCAP_IROH_ARCHIVE_FINGERPRINT before any other call.");
    try emitFn(&b, gpa, "glowcap_iroh_netlayer_new", &.{ "secret_seed", "secret_seed_len", "config", "out_netlayer", "out_error", "error_cap", "out_error_len" }, "Create an iroh netlayer (one bound endpoint) allocating through the library\nallocator. secret_seed/secret_seed_len is either a 32-byte Ed25519 secret key\n(borrowed) or empty (secret_seed_len == 0) for a fresh random key; any other\nlength is GLOWCAP_ERR_INVALID_ARGUMENT. config carries the mandatory reachability\n(GLOWCAP_IROH_REACH_*; an unknown value or a NULL config is\nGLOWCAP_ERR_INVALID_ARGUMENT / GLOWCAP_ERR_NULL_POINTER) and the optional\nconnect_timeout_ms (0 = glowcap's own default). Binds the endpoint and arms the\nreadiness loop, so the netlayer is immediately driveable through\nglowcap_iroh_netlayer_readiness_fd; GLOWCAP_ERR_IO if the endpoint cannot bind or\nthe loop cannot arm. Release with glowcap_iroh_netlayer_release after releasing\nevery connection made from it.\n\n" ++ optional_diagnostic_doc);
    try emitFn(&b, gpa, "glowcap_iroh_netlayer_new_in", &.{ "context", "secret_seed", "secret_seed_len", "config", "out_netlayer", "out_error", "error_cap", "out_error_len" }, "As glowcap_iroh_netlayer_new, allocating the netlayer, endpoint, and every\nper-connection buffer through context.\n\n" ++ optional_diagnostic_doc);
    try emitFn(&b, gpa, "glowcap_iroh_netlayer_close", &.{"netlayer"}, "Close the endpoint without releasing the handle: subsequent dials fail and the\nreadiness loop winds down. Idempotent. The shutdown lever for a host whose\nreadiness wait parks on another thread.");
    try emitFn(&b, gpa, "glowcap_iroh_netlayer_release", &.{ "netlayer", "out_error", "error_cap", "out_error_len" }, "Release the netlayer, its endpoint, and the runtime. Every connection made\nfrom it must already be released. NULL is a no-op.\n\n" ++ optional_diagnostic_doc);
    try emitFn(&b, gpa, "glowcap_iroh_netlayer_node_id", &.{ "netlayer", "out", "cap", "out_len" }, "Write this endpoint's id as lowercase hex into out, and the byte count into\nout_len. cap must be at least GLOWCAP_IROH_NODE_ID_BYTES or the call is\nGLOWCAP_ERR_BUFFER_TOO_SMALL. No terminator is written.");
    try emitFn(&b, gpa, "glowcap_iroh_netlayer_direct_addrs", &.{ "netlayer", "out", "cap", "out_len" }, "Write this endpoint's comma-separated direct socket addresses into out (the\nhint string a partner passes to glowcap_iroh_netlayer_start_connect) and the\nbyte count into out_len. A null output is allowed only with cap == 0 to query\nthe size. A short buffer writes the required byte count and returns\nGLOWCAP_ERR_BUFFER_TOO_SMALL. A list larger than\nGLOWCAP_IROH_MAX_DIRECT_ADDRESS_BYTES is invalid. No terminator is written.");
    try emitFn(&b, gpa, "glowcap_iroh_conn_release", &.{"conn"}, "Close the connection and free the handle; do not use conn afterward. A later\nreadiness record may still carry its stable id; the host drops it after removing\nits own id-to-connection row. No call parks on the connection, so this free\ncannot race a read.");
    try emitFn(&b, gpa, "glowcap_iroh_conn_id", &.{"conn"}, "Return this connection's stable readiness identity, unique for the netlayer's\nlifetime and never derived from the handle allocation address. Returns 0 for a\nNULL handle.");
    try emitFn(&b, gpa, "glowcap_iroh_conn_remote_node_id", &.{ "conn", "out", "cap", "out_len" }, "Write the far end's QUIC-verified endpoint id into out as lowercase hex, and the\nbyte count into out_len. Compare it with the partner's CapTP location before\ncalling the durable name proved. cap must be at least GLOWCAP_IROH_NODE_ID_BYTES\nor the call is GLOWCAP_ERR_BUFFER_TOO_SMALL. No terminator is written. A missing\nproof is GLOWCAP_ERR_IO with out_len untouched, never success with a zero length.");

    try emitFn(&b, gpa, "glowcap_iroh_netlayer_readiness_fd", &.{"netlayer"}, "The netlayer's single read-only OS readiness fd — the borrowed read end of the\nsidecar's wakeup channel, readable whenever fresh readiness records are pending.\nRegister it once with your poller (poll/epoll/kqueue, or a runtime's reactor);\nwhen it signals, call glowcap_iroh_netlayer_drain_ready. The fd is owned by the\nnetlayer and valid until glowcap_iroh_netlayer_release — do not close it; dup it\nif your runtime needs its own copy. Negative only for a null handle.");
    try emitFn(&b, gpa, "glowcap_iroh_netlayer_drain_ready", &.{ "netlayer", "out_events", "out_cap", "out_count" }, "Clear the fd's coalesced wake bytes, then drain pending readiness records into\nout_events (out_cap entries, caller-owned) without blocking: GLOWCAP_OK with the\ndrained count (0 when none) in out_count, or a GLOWCAP_ERR_* on fault (out_count\nuntouched). Call it when readiness_fd signals, then again until it drains fewer\nthan out_cap records (more may be queued than one call drains), before re-parking\non the fd. A record for a connection already released still carries only its\nstable id, so the host can discard it without dereferencing freed storage. The\ndrain touches only the endpoint, never a per-connection buffer. Run it on one\nthread per netlayer, serialized against glowcap_iroh_netlayer_release.");
    try emitFn(&b, gpa, "glowcap_iroh_netlayer_try_accept", &.{ "netlayer", "out_conn" }, "Claim one accepted connection (already non-blocking) into out_conn, returning\nGLOWCAP_OK, or GLOWCAP_ERR_WOULD_BLOCK when none is pending. Drive it after\ndrain_ready reports an accept record. Release with glowcap_iroh_conn_release.");
    try emitFn(&b, gpa, "glowcap_iroh_netlayer_start_connect", &.{ "netlayer", "request_id", "node_id", "node_id_len", "addr_hints", "addr_hints_len" }, "Admit one outbound dial without blocking. request_id is nonzero and unique among\nthis netlayer's live requests. GLOWCAP_OK promises exactly one EV_CONNECT record\ncarrying request_id; a synchronous error promises no event. The borrowed target\nbytes are parsed before return.");
    try emitFn(&b, gpa, "glowcap_iroh_netlayer_finish_connect", &.{ "netlayer", "request_id", "out_conn" }, "Consume one terminal dial after EV_CONNECT. GLOWCAP_OK transfers the owned\nconnection to out_conn; a failure returns its GLOWCAP_ERR_* classification and\nrecords iroh's own text for the fault (the refusing relay, the silent address,\nthe QUIC close reason) in glowcap_iroh_last_error. The result can be consumed\nonly once. Release a successful connection with glowcap_iroh_conn_release.");
    try emitFn(&b, gpa, "glowcap_iroh_netlayer_cancel_connect", &.{ "netlayer", "request_id" }, "Cancel one admitted dial. Its sole EV_CONNECT still arrives and must be finished,\nwhich consumes the endpoint-owned terminal result.");
    try emitFn(&b, gpa, "glowcap_iroh_conn_try_read", &.{ "conn", "buf", "len", "out_read" }, "Non-blocking read of raw inbound bytes into buf: GLOWCAP_OK with the byte count\nin out_read, GLOWCAP_ERR_WOULD_BLOCK when nothing is buffered yet,\nGLOWCAP_ERR_CLOSED on a clean end of stream, or GLOWCAP_ERR_IO on a fault\n(out_read untouched on any non-OK return). GLOWCAP_IROH_READ_CHUNK_BYTES is the\ntransport-owned read-buffer cap mirrored by the bindings. Feed these bytes to a\nGlowcapHost session, the same shape the TCP path uses.");
    try emitFn(&b, gpa, "glowcap_iroh_conn_try_write", &.{ "conn", "buf", "len", "out_written" }, "Non-blocking write of len raw bytes from buf: GLOWCAP_OK with the count written\n(possibly a prefix) in out_written, GLOWCAP_ERR_WOULD_BLOCK when the outbound\nbuffer has no room (retry after the next writable record), or GLOWCAP_ERR_IO on\na fault (out_written untouched on any non-OK return).");

    try emitFn(&b, gpa, "glowcap_iroh_transport_provider", &.{ "netlayer", "out_provider" }, "Fill out_provider with this runtime's one-entry iroh package. Install it with\nglowcap_driver_add_provider. The driver acquires the provider lease through\nretain and releases it after all transport use retires; release the iroh runtime\nafter the driver is released.");

    try emitFn(&b, gpa, "glowcap_iroh_last_error", &.{ "out_buf", "cap" }, "Copy the calling thread's last iroh-transport error into out_buf, the iroh\nsibling of glowcap_last_error, reading libglowcap_net_transport_iroh's own per-thread slot. A\nglowcap_iroh_* call that returns GLOWCAP_ERR_IO records its concrete cause here.\nCopies at most cap-1 bytes and NUL-terminates when cap>0; out_buf NULL or cap 0\nqueries the length. Returns the full message length, or 0 when none is set." ++ header_emit.last_error_freshness_doc);
    try emitFn(&b, gpa, "glowcap_iroh_clear_last_error", &.{}, "Clear the calling thread's iroh-transport last-error slot.");

    try b.appendSlice(gpa,
        \\
        \\#ifdef __cplusplus
        \\}
        \\#endif
        \\
        \\#endif /* GLOWCAP_NET_TRANSPORT_IROH_H */
        \\
    );

    try E.assertAllEmitted(&b, "gen-header-net-transport-iroh");
    return b.toOwnedSlice(gpa);
}
