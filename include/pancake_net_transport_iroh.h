/* Generated from src/c_abi/net_transport/iroh/mod.zig by tools/gen/header/iroh.zig.
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
   the sidecar's internal byte-level seam (pancake_iroh_sidecar_connect_blocking,
   pancake_iroh_sidecar_conn_read, ...). This is the frame-level public
   surface (pancake_iroh_netlayer_*, pancake_iroh_conn_try_read, ...). */
#ifndef PANCAKE_NET_TRANSPORT_IROH_H
#define PANCAKE_NET_TRANSPORT_IROH_H

#include <stddef.h>
#include <stdint.h>
#include "pancake_ocapn.h"
#include "pancake_transport_provider.h"

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
   bytes yourself, feeding a PancakeHost session and writing its
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

   Those same calls are the raw byte channel a byte-transparent relay
   needs for an iroh leg (ADR-0086). One leg composes
   pancake_iroh_netlayer_new, its readiness_fd and drain_ready, the
   _start_connect / _finish_connect lifecycle, _conn_try_read /
   _conn_try_write, then _conn_release and
   pancake_iroh_netlayer_release. There is no channel object over them,
   because the wait a channel needs is your own reactor's, and only the
   caller can hold it.

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
   pancake_iroh_netlayer_finish_connect or claimed with
   pancake_iroh_netlayer_try_accept; released by
   pancake_iroh_conn_release. */
typedef struct PancakeIrohConn PancakeIrohConn;

/* Reachability postures for pancake_iroh_netlayer_new. The caller always
   passes one; there is no default. A pancake peer never turns on relays
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

/* The posture a Host redeems a hint-less handoff give under until the
   embedder sets one: DISCOVERY, the maximal-reach choice. The netlayer
   constructor still takes no default; this names the redeem knob's one
   starting value so every consumer initializes from the same fact. */
#define PANCAKE_IROH_REACH_REDEEM_DEFAULT 1u

/* Readiness event bits (ADR-0057). The netlayer's loop serves many
   connections from one host thread: park on the readiness fd from
   pancake_iroh_netlayer_readiness_fd, and when it signals, drain records
   with pancake_iroh_netlayer_drain_ready, claim accepts with
   pancake_iroh_netlayer_try_accept, and drive each ready connection with
   the non-blocking pancake_iroh_conn_try_read / _try_write (raw bytes you
   frame with a PancakeHost session, as for TCP). No call parks on a specific
   connection, so releasing one never races a read. The would-block code
   is the shared PANCAKE_ERR_WOULD_BLOCK from pancake_ocapn.h. */
#define PANCAKE_IROH_EV_READABLE 1u
#define PANCAKE_IROH_EV_WRITABLE 2u
#define PANCAKE_IROH_EV_CLOSED 4u
#define PANCAKE_IROH_EV_ACCEPT 8u
#define PANCAKE_IROH_EV_CONNECT 16u

/* One readiness record from pancake_iroh_netlayer_drain_ready. subject
   is zero for accept, the caller request id for EV_CONNECT, and otherwise
   the stable identity returned by pancake_iroh_conn_id. */
typedef struct PancakeIrohReadyEvent {
  uintptr_t subject;
  uint32_t events;
} PancakeIrohReadyEvent;

/* One iroh endpoint's configuration, passed to pancake_iroh_netlayer_new /
   _new_in. reachability is mandatory (one of PANCAKE_IROH_REACH_*; an unknown
   value is refused). connect_timeout_ms is the per-endpoint stream-
   establishment deadline in milliseconds — the dial's connect + first-stream
   open and each accepted stream ride it — with 0 meaning pancake's thirty seconds. Every 0 here is
   pancake's number, never the QUIC stack's own, a distinction that matters most
   for idle_timeout_ms, where pancake's replaces a longer one the stack would
   otherwise use.
   idle_timeout_ms bounds how long a connection survives without a packet from
   the far end, which decides how quickly a peer that was killed rather than
   closed stops counting as present: such a peer sends nothing, and UDP has no
   equivalent of the FIN a dying TCP process gets from the operating system, so
   nothing else ends the connection. 0 keeps pancake's fifteen seconds; read a live
   session as presence and you want a shorter one of your own.
   Zero-initialize the whole struct before filling the fields you set (e.g.
   `PancakeIrohConfig cfg = {0};`), so a field added in a later version
   defaults to 0 rather than reading stack garbage. */
typedef struct PancakeIrohConfig {
  uint32_t reachability;
  uint64_t connect_timeout_ms;
  uint64_t idle_timeout_ms;
  uint32_t worker_threads;
} PancakeIrohConfig;

/* Return the exact callable-surface fingerprint. Compare it with the binding-generated PANCAKE_IROH_ARCHIVE_FINGERPRINT before any other call. */
uint64_t pancake_iroh_archive_fingerprint(void);
/* Create an iroh netlayer (one bound endpoint) allocating through the library
   allocator. secret_seed/secret_seed_len is either a 32-byte Ed25519 secret key
   (borrowed) or empty (secret_seed_len == 0) for a fresh random key; any other
   length is PANCAKE_ERR_INVALID_ARGUMENT. config carries the mandatory reachability
   (PANCAKE_IROH_REACH_*; an unknown value or a NULL config is
   PANCAKE_ERR_INVALID_ARGUMENT / PANCAKE_ERR_NULL_POINTER) and the optional
   connect_timeout_ms (0 = pancake's own default). Binds the endpoint and arms the
   readiness loop, so the netlayer is immediately driveable through
   pancake_iroh_netlayer_readiness_fd; PANCAKE_ERR_IO if the endpoint cannot bind or
   the loop cannot arm. Release with pancake_iroh_netlayer_release after releasing
   every connection made from it.

   out_error/out_error_len optionally capture this call's diagnostic before an
   off-thread runtime regains control: omit all three diagnostic arguments, or
   provide out_error_len. It receives the full length; out_error receives at most
   error_cap - 1 bytes and is NUL-terminated when error_cap is nonzero. */
int32_t pancake_iroh_netlayer_new(const uint8_t *secret_seed, size_t secret_seed_len, const PancakeIrohConfig *config, PancakeIrohNetlayer **out_netlayer, uint8_t *out_error, size_t error_cap, size_t *out_error_len);
/* As pancake_iroh_netlayer_new, allocating the netlayer, endpoint, and every
   per-connection buffer through context.

   out_error/out_error_len optionally capture this call's diagnostic before an
   off-thread runtime regains control: omit all three diagnostic arguments, or
   provide out_error_len. It receives the full length; out_error receives at most
   error_cap - 1 bytes and is NUL-terminated when error_cap is nonzero. */
int32_t pancake_iroh_netlayer_new_in(PancakeContext *context, const uint8_t *secret_seed, size_t secret_seed_len, const PancakeIrohConfig *config, PancakeIrohNetlayer **out_netlayer, uint8_t *out_error, size_t error_cap, size_t *out_error_len);
/* Close the endpoint without releasing the handle: subsequent dials fail and the
   readiness loop winds down. Idempotent. The shutdown lever for a host whose
   readiness wait parks on another thread. */
void pancake_iroh_netlayer_close(PancakeIrohNetlayer *netlayer);
/* Release the netlayer, its endpoint, and the runtime. Every connection made
   from it must already be released. NULL is a no-op.

   out_error/out_error_len optionally capture this call's diagnostic before an
   off-thread runtime regains control: omit all three diagnostic arguments, or
   provide out_error_len. It receives the full length; out_error receives at most
   error_cap - 1 bytes and is NUL-terminated when error_cap is nonzero. */
int32_t pancake_iroh_netlayer_release(PancakeIrohNetlayer *netlayer, uint8_t *out_error, size_t error_cap, size_t *out_error_len);
/* Write this endpoint's id — its Ed25519 public key, the dialable designator —
   into out as lowercase hex, and the byte count into out_len. cap must be at
   least the id length (64) or the call is PANCAKE_ERR_BUFFER_TOO_SMALL. No
   terminator is written. */
int32_t pancake_iroh_netlayer_node_id(PancakeIrohNetlayer *netlayer, uint8_t *out, size_t cap, size_t *out_len);
/* Write this endpoint's comma-separated direct socket addresses into out (the
   hint string a partner passes to pancake_iroh_netlayer_start_connect) and the
   byte count into out_len. A buffer too small is PANCAKE_ERR_BUFFER_TOO_SMALL; an
   endpoint with no direct addresses writes zero bytes and returns PANCAKE_OK. No
   terminator is written. */
int32_t pancake_iroh_netlayer_direct_addrs(PancakeIrohNetlayer *netlayer, uint8_t *out, size_t cap, size_t *out_len);
/* Close the connection and free the handle; do not use conn afterward. A later
   readiness record may still carry its stable id; the host drops it after removing
   its own id-to-connection row. No call parks on the connection, so this free
   cannot race a read. */
void pancake_iroh_conn_release(PancakeIrohConn *conn);
/* Return this connection's stable readiness identity, unique for the netlayer's
   lifetime and never derived from the handle allocation address. Returns 0 for a
   NULL handle. */
size_t pancake_iroh_conn_id(PancakeIrohConn *conn);
/* Write the far end's QUIC-verified endpoint id into out as lowercase hex, and the
   byte count into out_len. The TLS handshake authenticated the key at the other end
   of this connection, on an accepted connection exactly as on a dialed one, so the
   host that owns the connection may say so about it. The spelling is the designator
   pancake_iroh_netlayer_node_id prints: compare it against the location a partner's
   CapTP hello claims, and treat an equal pair — and only an equal pair — as a proved
   durable name. cap must be at least the id length (64) or the call is
   PANCAKE_ERR_BUFFER_TOO_SMALL. No terminator is written. A connection whose remote
   cannot be read (the handle is gone, or the sidecar faulted) is PANCAKE_ERR_IO (see
   pancake_iroh_last_error) with out_len untouched; the call never returns PANCAKE_OK
   with a zero length, so a missing proof cannot be mistaken for a designator. */
int32_t pancake_iroh_conn_remote_node_id(PancakeIrohConn *conn, uint8_t *out, size_t cap, size_t *out_len);
/* The netlayer's single read-only OS readiness fd — the borrowed read end of the
   sidecar's wakeup channel, readable whenever fresh readiness records are pending.
   Register it once with your poller (poll/epoll/kqueue, or a runtime's reactor);
   when it signals, call pancake_iroh_netlayer_drain_ready. The fd is owned by the
   netlayer and valid until pancake_iroh_netlayer_release — do not close it; dup it
   if your runtime needs its own copy. Negative only for a null handle. */
int32_t pancake_iroh_netlayer_readiness_fd(PancakeIrohNetlayer *netlayer);
/* Clear the fd's coalesced wake bytes, then drain pending readiness records into
   out_events (out_cap entries, caller-owned) without blocking: PANCAKE_OK with the
   drained count (0 when none) in out_count, or a PANCAKE_ERR_* on fault (out_count
   untouched). Call it when readiness_fd signals, then again until it drains fewer
   than out_cap records (more may be queued than one call drains), before re-parking
   on the fd. A record for a connection already released still carries only its
   stable id, so the host can discard it without dereferencing freed storage. The
   drain touches only the endpoint, never a per-connection buffer. Run it on one
   thread per netlayer, serialized against pancake_iroh_netlayer_release. */
int32_t pancake_iroh_netlayer_drain_ready(PancakeIrohNetlayer *netlayer, PancakeIrohReadyEvent *out_events, size_t out_cap, size_t *out_count);
/* Claim one accepted connection (already non-blocking) into out_conn, returning
   PANCAKE_OK, or PANCAKE_ERR_WOULD_BLOCK when none is pending. Drive it after
   drain_ready reports an accept record. Release with pancake_iroh_conn_release. */
int32_t pancake_iroh_netlayer_try_accept(PancakeIrohNetlayer *netlayer, PancakeIrohConn **out_conn);
/* Admit one outbound dial without blocking. request_id is nonzero and unique among
   this netlayer's live requests. PANCAKE_OK promises exactly one EV_CONNECT record
   carrying request_id; a synchronous error promises no event. The borrowed target
   bytes are parsed before return. */
int32_t pancake_iroh_netlayer_start_connect(PancakeIrohNetlayer *netlayer, size_t request_id, const uint8_t *node_id, size_t node_id_len, const uint8_t *addr_hints, size_t addr_hints_len);
/* Consume one terminal dial after EV_CONNECT. PANCAKE_OK transfers the owned
   connection to out_conn; a failure returns its PANCAKE_ERR_* classification. The
   result can be consumed only once. Release a successful connection with
   pancake_iroh_conn_release. */
int32_t pancake_iroh_netlayer_finish_connect(PancakeIrohNetlayer *netlayer, size_t request_id, PancakeIrohConn **out_conn);
/* Cancel one admitted dial. Its sole EV_CONNECT still arrives and must be finished,
   which consumes the endpoint-owned terminal result. */
int32_t pancake_iroh_netlayer_cancel_connect(PancakeIrohNetlayer *netlayer, size_t request_id);
/* Non-blocking read of raw inbound bytes into buf: PANCAKE_OK with the byte count
   in out_read, PANCAKE_ERR_WOULD_BLOCK when nothing is buffered yet,
   PANCAKE_ERR_CLOSED on a clean end of stream, or PANCAKE_ERR_IO on a fault
   (out_read untouched on any non-OK return). Feed these bytes to a PancakeHost
   session, the same shape the TCP path uses. */
int32_t pancake_iroh_conn_try_read(PancakeIrohConn *conn, uint8_t *buf, size_t len, size_t *out_read);
/* Non-blocking write of len raw bytes from buf: PANCAKE_OK with the count written
   (possibly a prefix) in out_written, PANCAKE_ERR_WOULD_BLOCK when the outbound
   buffer has no room (retry after the next writable record), or PANCAKE_ERR_IO on
   a fault (out_written untouched on any non-OK return). */
int32_t pancake_iroh_conn_try_write(PancakeIrohConn *conn, const uint8_t *buf, size_t len, size_t *out_written);
/* Fill out_provider with this runtime's one-entry iroh package. Install it with
   pancake_driver_add_provider. The driver acquires the provider lease through
   retain and releases it after all transport use retires; release the iroh runtime
   after the driver is released. */
int32_t pancake_iroh_transport_provider(PancakeIrohNetlayer *netlayer, PancakeTransportProvider *out_provider);
/* Copy the calling thread's last iroh-transport error into out_buf, the iroh
   sibling of pancake_last_error, reading libpancake_net_transport_iroh's own per-thread slot. A
   pancake_iroh_* call that returns PANCAKE_ERR_IO records its concrete cause here.
   Copies at most cap-1 bytes and NUL-terminates when cap>0; out_buf NULL or cap 0
   queries the length. Returns the full message length, or 0 when none is set. Every status-returning call clears the slot before validation; read it immediately after a failing call, and treat zero length as no additional detail. */
size_t pancake_iroh_last_error(uint8_t *out_buf, size_t cap);
/* Clear the calling thread's iroh-transport last-error slot. */
void pancake_iroh_clear_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* PANCAKE_NET_TRANSPORT_IROH_H */
