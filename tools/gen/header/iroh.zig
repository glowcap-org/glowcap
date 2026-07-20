//! Generates `include/pancake_net_transport_iroh.h` from the Zig
//! `c_abi_net_transport_iroh` source.
//!
//! The public iroh transport C ABI is a separate archive from
//! `libpancake_ocapn` (ADR-0055, ADR-0059), so it gets its own header. As with
//! `tools/gen/header/ocapn.zig`, the function signatures are *reflected* from the real
//! `src/c_abi/net_transport/iroh/mod.zig` exports, so the header cannot disagree
//! with the implementation, and the prose lives here.
//! `zig build gen-header-net-transport-iroh-check` is the staleness gate;
//! `zig build gen-header-net-transport-iroh` is the fixer. Both run cargo-free:
//! the generator reflects types only and links the sidecar stubs
//! (`tools/gen/stub/iroh_sidecar.zig`).
//!
//! The shared frame/peer/context vocabulary (`PancakeFrame`,
//! `PancakeManagedFrame`, `PancakeContext`) is declared in `pancake_ocapn.h`,
//! which this header includes; only the two iroh handles and the
//! `pancake_iroh_*` prototypes are new here.

const std = @import("std");
const c = @import("c_abi_net_transport_iroh");
const header_emit = @import("header_emit.zig");

// Force sidecar stubs so reflection-only gen links cargo-free.
comptime {
    _ = @import("iroh_sidecar_stub");
}

pub const header_path = "include/pancake_net_transport_iroh.h";
pub const step_name = "gen-header-net-transport-iroh";

// Every prototype the header emits, in order. `emitFn` refuses a name missing
// here; the comptime guard below holds the table against the real
// `c_abi_net_transport_iroh` declarations in both directions, so a new
// `pub export fn pancake_iroh_*`
// cannot silently miss the header while the gate stays green.
const emitted_fn_names = [_][]const u8{
    "pancake_iroh_netlayer_new",
    "pancake_iroh_netlayer_new_in",
    "pancake_iroh_netlayer_close",
    "pancake_iroh_netlayer_release",
    "pancake_iroh_netlayer_node_id",
    "pancake_iroh_netlayer_direct_addrs",
    "pancake_iroh_conn_release",
    "pancake_iroh_netlayer_readiness_fd",
    "pancake_iroh_netlayer_drain_ready",
    "pancake_iroh_netlayer_try_accept",
    "pancake_iroh_netlayer_try_connect",
    "pancake_iroh_conn_try_read",
    "pancake_iroh_conn_try_write",
    "pancake_iroh_last_error",
    "pancake_iroh_clear_last_error",
};

// The reflection machinery is shared with the other header generators; this
// `Spec` binds it to `libpancake_net_transport_iroh`. No function-pointer
// typedefs and no `#define`s, so it supplies only the module and the table.
const Spec = struct {
    pub const c = @import("c_abi_net_transport_iroh");
    pub const emitted_fns: []const []const u8 = &emitted_fn_names;
};
const E = header_emit.Emit(Spec);
const Buf = header_emit.Buf;
const emitDoc = header_emit.emitDoc;
const emitFn = E.emitFn;

// Coverage guard, both directions: every `pub export fn pancake_iroh_*` in
// `c_abi_net_transport_iroh` must be listed, and every listed name must be real.
comptime {
    E.guardFns("c_abi_net_transport_iroh", "pancake_iroh_");
}

/// Build the full header text. Caller owns the returned bytes.
pub fn generate(gpa: std.mem.Allocator) ![]u8 {
    var b: Buf = .empty;
    errdefer b.deinit(gpa);

    try b.appendSlice(gpa,
        \\/* Generated from src/c_abi/net_transport/iroh/mod.zig by tools/gen/header/iroh.zig.
        \\   Do not edit by hand: run `zig build gen-header-net-transport-iroh`.
        \\   Function signatures are reflected from the Zig source, so this header
        \\   cannot drift from the implementation.
        \\
        \\   The iroh transport's public C ABI: a separate artifact
        \\   (libpancake_net_transport_iroh) that links the Rust iroh sidecar
        \\   (ADR-0055). It is a companion, not a superset: it exports only the
        \\   pancake_iroh_* family and shares no core symbol with libpancake_ocapn,
        \\   so a consumer links BOTH archives and includes BOTH headers. The
        \\   shared frame, peer, and context vocabulary lives in pancake_ocapn.h
        \\   (included below) and the archives agree on its layout; only the two
        \\   iroh handles and the pancake_iroh_* prototypes are declared here. The
        \\   iroh family has its own last-error slot, read through
        \\   pancake_iroh_last_error rather than pancake_ocapn's pancake_last_error.
        \\
        \\   This is NOT transports/iroh/include/pancake_iroh_sidecar.h, which is
        \\   the sidecar's internal byte-level seam (pancake_iroh_sidecar_connect,
        \\   pancake_iroh_sidecar_conn_read, ...). This is the frame-level public
        \\   surface (pancake_iroh_netlayer_*, pancake_iroh_conn_try_read, ...). */
        \\#ifndef PANCAKE_NET_TRANSPORT_IROH_H
        \\#define PANCAKE_NET_TRANSPORT_IROH_H
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
        \\Orientation: the iroh transport is the host-driven netlayer boundary's
        \\encrypted-QUIC sibling of the TCP endpoints in pancake_net_transport_tcp.h.
        \\It has one I/O model: an event-driven readiness loop, armed when the
        \\netlayer is created, that serves many connections from one host thread.
        \\The netlayer hands back a single OS readiness fd
        \\(pancake_iroh_netlayer_readiness_fd); register it with your poller, and
        \\when it signals, drain the pending records with
        \\pancake_iroh_netlayer_drain_ready, claim accepts with
        \\pancake_iroh_netlayer_try_accept, and move raw bytes with the
        \\non-blocking pancake_iroh_conn_try_read / _try_write. You frame those
        \\bytes yourself, feeding a PancakePeer's stream input and writing its
        \\outbound frames back — the same shape the TCP consumer uses. No call ever
        \\parks on a specific connection, so releasing one never races a read.
        \\
        \\The one difference from TCP is addressing: there is no host:port. A
        \\partner is dialed by its endpoint id — the canonical lowercase-hex
        \\designator pancake_iroh_netlayer_node_id prints. Whether you also need a
        \\direct-address hint string from pancake_iroh_netlayer_direct_addrs
        \\depends on the reachability the netlayer was created with: a
        \\PANCAKE_IROH_REACH_DIRECT endpoint dials by id plus hints, while a
        \\discovery endpoint resolves the partner by id alone. Carry both in the
        \\OCapN locator a peer signs (transport "iroh", the id as designator, the
        \\hints under "direct-addresses").
        \\
        \\Lifetime: release every connection before the netlayer that minted it.
        \\Threading: a connection is single-owner like a peer; serialize calls on
        \\one onto one thread. Run the netlayer's readiness wait (your poll on the
        \\fd) and drain_ready on one thread per netlayer, serialized against
        \\pancake_iroh_netlayer_release.
    );

    try b.appendSlice(gpa,
        \\
        \\/* An iroh netlayer: one bound QUIC endpoint plus the sidecar runtime
        \\   driving it. Created by pancake_iroh_netlayer_new; released by
        \\   pancake_iroh_netlayer_release after every connection is released. */
        \\typedef struct PancakeIrohNetlayer PancakeIrohNetlayer;
        \\/* One QUIC connection carrying one OCapN session. Created by
        \\   pancake_iroh_netlayer_try_connect or claimed with
        \\   pancake_iroh_netlayer_try_accept; released by
        \\   pancake_iroh_conn_release. */
        \\typedef struct PancakeIrohConn PancakeIrohConn;
        \\
        \\/* Reachability postures for pancake_iroh_netlayer_new. The caller always
        \\   passes one; there is no default. A pancake peer never turns on relays
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
    try b.print(gpa, "#define PANCAKE_IROH_REACH_DIRECT {d}u\n", .{c.PANCAKE_IROH_REACH_DIRECT});
    try b.print(gpa, "#define PANCAKE_IROH_REACH_DISCOVERY {d}u\n", .{c.PANCAKE_IROH_REACH_DISCOVERY});
    try b.print(gpa, "#define PANCAKE_IROH_REACH_DISCOVERY_NO_RELAY {d}u\n", .{c.PANCAKE_IROH_REACH_DISCOVERY_NO_RELAY});
    try b.print(gpa, "#define PANCAKE_IROH_REACH_LOCAL_DISCOVERY {d}u\n", .{c.PANCAKE_IROH_REACH_LOCAL_DISCOVERY});
    try b.appendSlice(gpa,
        \\
        \\/* The posture a Host redeems a hint-less handoff give under until the
        \\   embedder sets one: DISCOVERY, the maximal-reach choice. The netlayer
        \\   constructor still takes no default; this names the redeem knob's one
        \\   starting value so every consumer initializes from the same fact. */
        \\
    );
    try b.print(gpa, "#define PANCAKE_IROH_REACH_REDEEM_DEFAULT {d}u\n", .{c.PANCAKE_IROH_REACH_REDEEM_DEFAULT});
    try b.appendSlice(gpa,
        \\
        \\/* Readiness event bits (ADR-0057). The netlayer's loop serves many
        \\   connections from one host thread: park on the readiness fd from
        \\   pancake_iroh_netlayer_readiness_fd, and when it signals, drain records
        \\   with pancake_iroh_netlayer_drain_ready, claim accepts with
        \\   pancake_iroh_netlayer_try_accept, and drive each ready connection with
        \\   the non-blocking pancake_iroh_conn_try_read / _try_write (raw bytes you
        \\   frame with a PancakePeer, as for TCP). No call parks on a specific
        \\   connection, so releasing one never races a read. The would-block code
        \\   is the shared PANCAKE_ERR_WOULD_BLOCK from pancake_ocapn.h. */
        \\
    );
    try b.print(gpa, "#define PANCAKE_IROH_EV_READABLE {d}u\n", .{c.PANCAKE_IROH_EV_READABLE});
    try b.print(gpa, "#define PANCAKE_IROH_EV_WRITABLE {d}u\n", .{c.PANCAKE_IROH_EV_WRITABLE});
    try b.print(gpa, "#define PANCAKE_IROH_EV_CLOSED {d}u\n", .{c.PANCAKE_IROH_EV_CLOSED});
    try b.print(gpa, "#define PANCAKE_IROH_EV_ACCEPT {d}u\n", .{c.PANCAKE_IROH_EV_ACCEPT});
    try b.appendSlice(gpa,
        \\
        \\/* One readiness record from pancake_iroh_netlayer_drain_ready: the
        \\   connection that became ready and the PANCAKE_IROH_EV_* bitset. conn is
        \\   NULL for an accept record (claim it with
        \\   pancake_iroh_netlayer_try_accept) and otherwise the PancakeIrohConn to
        \\   drive. */
        \\typedef struct PancakeIrohReadyEvent {
        \\  PancakeIrohConn *conn;
        \\  uint32_t events;
        \\} PancakeIrohReadyEvent;
        \\
        \\/* One iroh endpoint's configuration, passed to pancake_iroh_netlayer_new /
        \\   _new_in. reachability is mandatory (one of PANCAKE_IROH_REACH_*; an unknown
        \\   value is refused). connect_timeout_ms is the per-endpoint stream-
        \\   establishment deadline in milliseconds — the dial's connect + first-stream
        \\   open and each accepted stream ride it — with 0 meaning the built-in default.
        \\   Zero-initialize the whole struct before filling the fields you set (e.g.
        \\   `PancakeIrohConfig cfg = {0};`), so a field added in a later version
        \\   defaults to 0 rather than reading stack garbage. */
        \\typedef struct PancakeIrohConfig {
        \\  uint32_t reachability;
        \\  uint64_t connect_timeout_ms;
        \\} PancakeIrohConfig;
        \\
        \\
    );

    try emitFn(&b, gpa, "pancake_iroh_netlayer_new", &.{ "secret_seed", "secret_seed_len", "config", "out_netlayer" }, "Create an iroh netlayer (one bound endpoint) allocating through the library\nallocator. secret_seed/secret_seed_len is either a 32-byte Ed25519 secret key\n(borrowed) or empty (secret_seed_len == 0) for a fresh random key; any other\nlength is PANCAKE_ERR_INVALID_ARGUMENT. config carries the mandatory reachability\n(PANCAKE_IROH_REACH_*; an unknown value or a NULL config is\nPANCAKE_ERR_INVALID_ARGUMENT / PANCAKE_ERR_NULL_POINTER) and the optional\nconnect_timeout_ms (0 = the built-in default). Binds the endpoint and arms the\nreadiness loop, so the netlayer is immediately driveable through\npancake_iroh_netlayer_readiness_fd; PANCAKE_ERR_IO (see pancake_iroh_last_error)\nif the endpoint cannot bind or the loop cannot arm. Release with\npancake_iroh_netlayer_release after releasing every connection made from it.");
    try emitFn(&b, gpa, "pancake_iroh_netlayer_new_in", &.{ "context", "secret_seed", "secret_seed_len", "config", "out_netlayer" }, "As pancake_iroh_netlayer_new, allocating the netlayer, endpoint, and every\nper-connection buffer through context.");
    try emitFn(&b, gpa, "pancake_iroh_netlayer_close", &.{"netlayer"}, "Close the endpoint without releasing the handle: subsequent dials fail and the\nreadiness loop winds down. Idempotent. The shutdown lever for a host whose\nreadiness wait parks on another thread.");
    try emitFn(&b, gpa, "pancake_iroh_netlayer_release", &.{"netlayer"}, "Release the netlayer, its endpoint, and the runtime. Every connection made\nfrom it must already be released. NULL is a no-op.");
    try emitFn(&b, gpa, "pancake_iroh_netlayer_node_id", &.{ "netlayer", "out", "cap", "out_len" }, "Write this endpoint's id — its Ed25519 public key, the dialable designator —\ninto out as lowercase hex, and the byte count into out_len. cap must be at\nleast the id length (64) or the call is PANCAKE_ERR_BUFFER_TOO_SMALL. No\nterminator is written.");
    try emitFn(&b, gpa, "pancake_iroh_netlayer_direct_addrs", &.{ "netlayer", "out", "cap", "out_len" }, "Write this endpoint's comma-separated direct socket addresses into out (the\nhint string a partner passes to pancake_iroh_netlayer_try_connect) and the byte\ncount into out_len. A buffer too small is PANCAKE_ERR_BUFFER_TOO_SMALL; an\nendpoint with no direct addresses writes zero bytes and returns PANCAKE_OK. No\nterminator is written.");
    try emitFn(&b, gpa, "pancake_iroh_conn_release", &.{"conn"}, "Close the connection and free the handle; do not use conn afterward. The\nconnection also prunes itself from its netlayer's readiness routing so a later\nrecord naming it routes to nothing. No call parks on the connection, so this\nfree cannot race a read.");

    try emitFn(&b, gpa, "pancake_iroh_netlayer_readiness_fd", &.{"netlayer"}, "The netlayer's single OS readiness fd — the borrowed read end of the sidecar's\nwakeup channel, readable whenever fresh readiness records are pending. Register\nit once with your poller (poll/epoll/kqueue, or a runtime's reactor); when it\nsignals, call pancake_iroh_netlayer_drain_ready. The fd is owned by the netlayer\nand valid until pancake_iroh_netlayer_release — do not close it; dup it if your\nruntime needs its own copy. Negative only for a null handle.");
    try emitFn(&b, gpa, "pancake_iroh_netlayer_drain_ready", &.{ "netlayer", "out_events", "out_cap", "out_count" }, "Drain the pending readiness records into out_events (out_cap entries,\ncaller-owned) without blocking: PANCAKE_OK with the drained count (0 when none)\nin out_count, or a PANCAKE_ERR_* on fault (out_count untouched). Call it when\nreadiness_fd signals, then again until it drains fewer than out_cap records\n(more may be queued than one call drains), before re-parking on the fd. Records\nfor connections already released are skipped, so a host may release a connection\nat any time without racing this call — the drain touches only the endpoint,\nnever a per-connection buffer. Run it on one thread per netlayer, serialized\nagainst pancake_iroh_netlayer_release.");
    try emitFn(&b, gpa, "pancake_iroh_netlayer_try_accept", &.{ "netlayer", "out_conn" }, "Claim one accepted connection (already non-blocking) into out_conn, returning\nPANCAKE_OK, or PANCAKE_ERR_WOULD_BLOCK when none is pending. Drive it after\ndrain_ready reports an accept record. Release with pancake_iroh_conn_release.");
    try emitFn(&b, gpa, "pancake_iroh_netlayer_try_connect", &.{ "netlayer", "node_id", "node_id_len", "addr_hints", "addr_hints_len", "out_conn" }, "Dial a partner by endpoint id and return a connection driven by this netlayer's\nreadiness loop. node_id is the partner's canonical id; addr_hints is its\ncomma-separated direct-address list (empty cannot dial a DIRECT netlayer, which\nruns no lookup service, but suffices for a discovery posture); both are borrowed.\nThe dial itself blocks the calling thread (run it off your event loop);\nsubsequent conn_try_read / conn_try_write are non-blocking. Release with\npancake_iroh_conn_release.");
    try emitFn(&b, gpa, "pancake_iroh_conn_try_read", &.{ "conn", "buf", "len", "out_read" }, "Non-blocking read of raw inbound bytes into buf: PANCAKE_OK with the byte count\nin out_read, PANCAKE_ERR_WOULD_BLOCK when nothing is buffered yet,\nPANCAKE_ERR_CLOSED on a clean end of stream, or PANCAKE_ERR_IO on a fault\n(out_read untouched on any non-OK return). You frame these bytes yourself (feed\nthem to a PancakePeer's stream input), the same shape the TCP path uses.");
    try emitFn(&b, gpa, "pancake_iroh_conn_try_write", &.{ "conn", "buf", "len", "out_written" }, "Non-blocking write of len raw bytes from buf: PANCAKE_OK with the count written\n(the whole slice, all-or-nothing) in out_written, PANCAKE_ERR_WOULD_BLOCK when\nthe outbound buffer is at its bound (retry the same bytes after the next\nwritable record), or PANCAKE_ERR_IO on a fault (out_written untouched on any\nnon-OK return).");

    try emitFn(&b, gpa, "pancake_iroh_last_error", &.{ "out_buf", "cap" }, "Copy the calling thread's last iroh-transport error into out_buf, the iroh\nsibling of pancake_last_error, reading libpancake_net_transport_iroh's own per-thread slot. A\npancake_iroh_* call that returns PANCAKE_ERR_IO records its concrete cause here.\nCopies at most cap-1 bytes and NUL-terminates when cap>0; out_buf NULL or cap 0\nqueries the length. Returns the full message length, or 0 when none is set.");
    try emitFn(&b, gpa, "pancake_iroh_clear_last_error", &.{}, "Clear the calling thread's iroh-transport last-error slot.");

    try b.appendSlice(gpa,
        \\
        \\#ifdef __cplusplus
        \\}
        \\#endif
        \\
        \\#endif /* PANCAKE_NET_TRANSPORT_IROH_H */
        \\
    );

    try E.assertAllEmitted(&b, "gen-header-net-transport-iroh");
    return b.toOwnedSlice(gpa);
}
