/* Generated from src/c_abi/net_transport/iroh/mod.zig by tools/header_gen_iroh.zig.
   Do not edit by hand: run `zig build gen-header-net-transport-iroh`.
   Function signatures are reflected from the Zig source, so this header
   cannot drift from the implementation.

   The iroh transport's public C ABI: a separate artifact
   (libpancake_net_transport_iroh) that links the Rust iroh sidecar
   (ADR-0055). It is a companion, not a superset: it exports only the
   pancake_iroh_* family and shares no core symbol with libpancake_ocapn,
   so a consumer links BOTH archives and includes BOTH headers. The
   shared frame, peer, and context vocabulary lives in pancake_ocapn.h
   (included below) and the archives agree on its layout; only the two
   iroh handles and the pancake_iroh_* prototypes are declared here. The
   iroh family has its own last-error slot, read through
   pancake_iroh_last_error rather than pancake_ocapn's pancake_last_error.

   This is NOT transports/iroh/include/pancake_iroh_sidecar.h, which is
   the sidecar's internal byte-level seam (pancake_iroh_sidecar_connect,
   pancake_iroh_sidecar_conn_read, ...). This is the frame-level public
   surface (pancake_iroh_netlayer_*, pancake_iroh_conn_try_read, ...). */
#ifndef PANCAKE_NET_TRANSPORT_IROH_H
#define PANCAKE_NET_TRANSPORT_IROH_H

#include <stddef.h>
#include <stdint.h>
#include "pancake_ocapn.h"

#ifdef __cplusplus
extern "C" {
#endif
/* Orientation: the iroh transport is the host-driven netlayer boundary's
   encrypted-QUIC sibling of the TCP endpoints in pancake_net_transport_tcp.h.
   It has one I/O model: an event-driven readiness loop, armed when the
   netlayer is created, that serves many connections from one host thread.
   The netlayer hands back a single OS readiness fd
   (pancake_iroh_netlayer_readiness_fd); register it with your poller, and
   when it signals, drain the pending records with
   pancake_iroh_netlayer_drain_ready, claim accepts with
   pancake_iroh_netlayer_try_accept, and move raw bytes with the
   non-blocking pancake_iroh_conn_try_read / _try_write. You frame those
   bytes yourself, feeding a PancakePeer's stream input and writing its
   outbound frames back — the same shape the TCP consumer uses. No call ever
   parks on a specific connection, so releasing one never races a read.

   The one difference from TCP is addressing: there is no host:port. A
   partner is dialed by its endpoint id — the canonical lowercase-hex
   designator pancake_iroh_netlayer_node_id prints. Whether you also need a
   direct-address hint string from pancake_iroh_netlayer_direct_addrs
   depends on the reachability the netlayer was created with: a
   PANCAKE_IROH_REACH_DIRECT endpoint dials by id plus hints, while a
   discovery endpoint resolves the partner by id alone. Carry both in the
   OCapN locator a peer signs (transport "iroh", the id as designator, the
   hints under "direct-addresses").

   Lifetime: release every connection before the netlayer that minted it.
   Threading: a connection is single-owner like a peer; serialize calls on
   one onto one thread. Run the netlayer's readiness wait (your poll on the
   fd) and drain_ready on one thread per netlayer, serialized against
   pancake_iroh_netlayer_release. */

/* An iroh netlayer: one bound QUIC endpoint plus the sidecar runtime
   driving it. Created by pancake_iroh_netlayer_new; released by
   pancake_iroh_netlayer_release after every connection is released. */
typedef struct PancakeIrohNetlayer PancakeIrohNetlayer;
/* One QUIC connection carrying one OCapN session. Created by
   pancake_iroh_netlayer_try_connect or claimed with
   pancake_iroh_netlayer_try_accept; released by
   pancake_iroh_conn_release. */
typedef struct PancakeIrohConn PancakeIrohConn;

/* Reachability postures for pancake_iroh_netlayer_new. The caller always
   passes one — there is no default. A pancake peer never turns on relays
   or a discovery service as a hidden implementation detail; the host
   chooses, in the open, how the endpoint becomes reachable.
     DIRECT             relay-less, lookup-less; dial by id plus
                        explicit address hints (loopback/LAN).
     DISCOVERY          number-0 relays + DNS/pkarr discovery; a peer is
                        dialable by id alone over the internet, with
                        hole-punching and NAT traversal.
     DISCOVERY_NO_RELAY DNS/pkarr discovery without relays.
     LOCAL_DISCOVERY    in-process shared address book; resolves by id
                        alone with no relay, DNS, or hints. For tests
                        and same-process embeddings, never the internet. */
#define PANCAKE_IROH_REACH_DIRECT 0u
#define PANCAKE_IROH_REACH_DISCOVERY 1u
#define PANCAKE_IROH_REACH_DISCOVERY_NO_RELAY 2u
#define PANCAKE_IROH_REACH_LOCAL_DISCOVERY 3u

/* Readiness event bits (ADR-0057). The netlayer's loop serves many
   connections from one host thread: park on the readiness fd from
   pancake_iroh_netlayer_readiness_fd, and when it signals, drain records
   with pancake_iroh_netlayer_drain_ready, claim accepts with
   pancake_iroh_netlayer_try_accept, and drive each ready connection with
   the non-blocking pancake_iroh_conn_try_read / _try_write (raw bytes you
   frame with a PancakePeer, as for TCP). No call parks on a specific
   connection, so releasing one never races a read. The would-block code
   is the shared PANCAKE_ERR_WOULD_BLOCK from pancake_ocapn.h. */
#define PANCAKE_IROH_EV_READABLE 1u
#define PANCAKE_IROH_EV_WRITABLE 2u
#define PANCAKE_IROH_EV_CLOSED 4u
#define PANCAKE_IROH_EV_ACCEPT 8u

/* One readiness record from pancake_iroh_netlayer_drain_ready: the
   connection that became ready and the PANCAKE_IROH_EV_* bitset. conn is
   NULL for an accept record (claim it with
   pancake_iroh_netlayer_try_accept) and otherwise the PancakeIrohConn to
   drive. */
typedef struct PancakeIrohReadyEvent {
  PancakeIrohConn *conn;
  uint32_t events;
} PancakeIrohReadyEvent;

/* Create an iroh netlayer (one bound endpoint) allocating through the library
   allocator. secret_seed/secret_seed_len is either a 32-byte Ed25519 secret key
   (borrowed) or empty (secret_seed_len == 0) for a fresh random key; any other
   length is PANCAKE_ERR_INVALID_ARGUMENT. reachability is one of
   PANCAKE_IROH_REACH_* and is mandatory — it decides whether the endpoint uses
   relays or a discovery service, with no default; an unknown value is
   PANCAKE_ERR_INVALID_ARGUMENT. Binds the endpoint and arms the readiness loop, so
   the netlayer is immediately driveable through pancake_iroh_netlayer_readiness_fd;
   PANCAKE_ERR_IO (see pancake_iroh_last_error) if the endpoint cannot bind or the
   loop cannot arm. Release with pancake_iroh_netlayer_release after releasing
   every connection made from it. */
int32_t pancake_iroh_netlayer_new(const uint8_t *secret_seed, size_t secret_seed_len, uint32_t reachability, PancakeIrohNetlayer **out_netlayer);
/* As pancake_iroh_netlayer_new, allocating the netlayer, endpoint, and every
   per-connection buffer through context. */
int32_t pancake_iroh_netlayer_new_in(PancakeContext *context, const uint8_t *secret_seed, size_t secret_seed_len, uint32_t reachability, PancakeIrohNetlayer **out_netlayer);
/* Close the endpoint without releasing the handle: subsequent dials fail and the
   readiness loop winds down. Idempotent. The shutdown lever for a host whose
   readiness wait parks on another thread. */
void pancake_iroh_netlayer_close(PancakeIrohNetlayer *netlayer);
/* Release the netlayer, its endpoint, and the runtime. Every connection made
   from it must already be released. NULL is a no-op. */
void pancake_iroh_netlayer_release(PancakeIrohNetlayer *netlayer);
/* Write this endpoint's id — its Ed25519 public key, the dialable designator —
   into out as lowercase hex, and the byte count into out_len. cap must be at
   least the id length (64) or the call is PANCAKE_ERR_INVALID_ARGUMENT. No
   terminator is written. */
int32_t pancake_iroh_netlayer_node_id(PancakeIrohNetlayer *netlayer, uint8_t *out, size_t cap, size_t *out_len);
/* Write this endpoint's comma-separated direct socket addresses into out (the
   hint string a partner passes to pancake_iroh_netlayer_try_connect) and the byte
   count into out_len. A buffer too small is PANCAKE_ERR_INVALID_ARGUMENT; an
   endpoint with no direct addresses writes zero bytes and returns PANCAKE_OK. No
   terminator is written. */
int32_t pancake_iroh_netlayer_direct_addrs(PancakeIrohNetlayer *netlayer, uint8_t *out, size_t cap, size_t *out_len);
/* Close the connection and free the handle; do not use conn afterward. The
   connection also prunes itself from its netlayer's readiness routing so a later
   record naming it routes to nothing. No call parks on the connection, so this
   free cannot race a read. */
void pancake_iroh_conn_release(PancakeIrohConn *conn);
/* The netlayer's single OS readiness fd — the borrowed read end of the sidecar's
   wakeup channel, readable whenever fresh readiness records are pending. Register
   it once with your poller (poll/epoll/kqueue, or a runtime's reactor); when it
   signals, call pancake_iroh_netlayer_drain_ready. The fd is owned by the netlayer
   and valid until pancake_iroh_netlayer_release — do not close it; dup it if your
   runtime needs its own copy. Negative only for a null handle. */
int32_t pancake_iroh_netlayer_readiness_fd(PancakeIrohNetlayer *netlayer);
/* Drain the pending readiness records into out_events (out_cap entries,
   caller-owned) without blocking, returning the count (0 when none) or a negative
   PANCAKE_ERR_* on fault. Call it when readiness_fd signals, then again until it
   returns fewer than out_cap records (more may be queued than one call drains),
   before re-parking on the fd. Records for connections already released are
   skipped, so a host may release a connection at any time without racing this
   call — the drain touches only the endpoint, never a per-connection buffer. Run
   it on one thread per netlayer, serialized against pancake_iroh_netlayer_release. */
intptr_t pancake_iroh_netlayer_drain_ready(PancakeIrohNetlayer *netlayer, PancakeIrohReadyEvent *out_events, size_t out_cap);
/* Claim one accepted connection (already non-blocking) into out_conn, returning
   PANCAKE_OK, or PANCAKE_ERR_WOULD_BLOCK when none is pending. Drive it after
   drain_ready reports an accept record. Release with pancake_iroh_conn_release. */
int32_t pancake_iroh_netlayer_try_accept(PancakeIrohNetlayer *netlayer, PancakeIrohConn **out_conn);
/* Dial a partner by endpoint id and return a connection driven by this netlayer's
   readiness loop. node_id is the partner's canonical id; addr_hints is its
   comma-separated direct-address list (empty cannot dial a DIRECT netlayer, which
   runs no lookup service, but suffices for a discovery posture); both are borrowed.
   The dial itself blocks the calling thread (run it off your event loop);
   subsequent conn_try_read / conn_try_write are non-blocking. Release with
   pancake_iroh_conn_release. */
int32_t pancake_iroh_netlayer_try_connect(PancakeIrohNetlayer *netlayer, const uint8_t *node_id, size_t node_id_len, const uint8_t *addr_hints, size_t addr_hints_len, PancakeIrohConn **out_conn);
/* Non-blocking read of raw inbound bytes into buf: the byte count (>0),
   PANCAKE_ERR_WOULD_BLOCK when nothing is buffered yet, PANCAKE_ERR_CLOSED on a
   clean end of stream, or PANCAKE_ERR_IO on a fault. You frame these bytes
   yourself (feed them to a PancakePeer's stream input), the same shape the TCP
   path uses. */
intptr_t pancake_iroh_conn_try_read(PancakeIrohConn *conn, uint8_t *buf, size_t len);
/* Non-blocking write of len raw bytes from buf: the count written (the whole
   slice, all-or-nothing), PANCAKE_ERR_WOULD_BLOCK when the outbound buffer is at
   its bound (retry the same bytes after the next writable record), or
   PANCAKE_ERR_IO on a fault. */
intptr_t pancake_iroh_conn_try_write(PancakeIrohConn *conn, const uint8_t *buf, size_t len);
/* Copy the calling thread's last iroh-transport error into out_buf — the iroh
   sibling of pancake_last_error, reading libpancake_net_transport_iroh's own per-thread slot. A
   pancake_iroh_* call that returns PANCAKE_ERR_IO records its concrete cause here.
   Copies at most cap-1 bytes and NUL-terminates when cap>0; out_buf NULL or cap 0
   queries the length. Returns the full message length, or 0 when none is set. */
size_t pancake_iroh_last_error(uint8_t *out_buf, size_t cap);
/* Clear the calling thread's iroh-transport last-error slot. */
void pancake_iroh_clear_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* PANCAKE_NET_TRANSPORT_IROH_H */
