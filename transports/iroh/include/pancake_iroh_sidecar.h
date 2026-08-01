/* pancake_iroh_sidecar.h — the C seam of the iroh netlayer sidecar (ADR-0055).
 *
 * Hand-written. The implementation is transports/iroh/src/lib.rs (a Rust
 * staticlib over the iroh crate, emitting libpancake_iroh_sidecar.a); the
 * consumer is the Zig resident src/net/transport/iroh.zig. The explicitly
 * explicitly blocking calls (connect_blocking/accept/conn_read/conn_write)
 * block the calling thread. Evented connect, accept, and stream I/O report
 * terminal/readiness state over one fd so a single loop thread multiplexes
 * many connections. The endpoint owns the private tokio runtime driving both
 * surfaces. No call panics across this boundary; failures come back as null
 * handles or negative return values.
 *
 * This is the private byte-level seam. It is deliberately prefixed
 * pancake_iroh_sidecar_* so it shares no symbol prefix with the public
 * frame-level ABI (pancake_iroh_netlayer_*, in include/pancake_net_transport_iroh.h): the
 * two link into one library without colliding.
 *
 * Lifetime order: free every connection before its endpoint, and free the
 * endpoint last. Handles are owned by exactly one caller and are not
 * reference-counted.
 */

#ifndef PANCAKE_IROH_SIDECAR_H
#define PANCAKE_IROH_SIDECAR_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Reachability postures for pancake_iroh_sidecar_endpoint_new. The caller
 * always passes one — there is no default. A pancake peer never turns on relays
 * or a discovery service as a hidden implementation detail; the host chooses,
 * in the open, how the endpoint becomes reachable.
 *
 *   DIRECT             relay-less, lookup-less. Dial by id plus explicit
 *                      address hints (loopback/LAN).
 *   DISCOVERY          the number-0 relays and DNS/pkarr discovery: a peer is
 *                      dialable by id alone over the public internet, with
 *                      hole-punching and NAT traversal.
 *   DISCOVERY_NO_RELAY DNS/pkarr discovery without relays (publishes direct
 *                      addresses; no relay fallback).
 *   LOCAL_DISCOVERY    an in-process shared address book: every endpoint in
 *                      this mode publishes its own address and resolves peers
 *                      by id alone, with no relay, DNS, or address hints. For
 *                      tests and same-process embeddings, never the internet. */
#define PANCAKE_IROH_REACH_DIRECT 0u
#define PANCAKE_IROH_REACH_DISCOVERY 1u
#define PANCAKE_IROH_REACH_DISCOVERY_NO_RELAY 2u
#define PANCAKE_IROH_REACH_LOCAL_DISCOVERY 3u

/* The event-driven surface (ADR-0057). An endpoint serves many connections
 * from one host thread: the loop polls one readiness fd, drains
 * (subject, events) records, and drives non-blocking byte I/O. WOULD_BLOCK is
 * the try_read/try_write sentinel, distinct from 0 (clean end of stream) and
 * -1 (error). EV_ACCEPT uses subject 0; EV_CONNECT uses the caller's request
 * id; connection I/O uses a stable endpoint-scoped connection id. */
#define PANCAKE_IROH_WOULD_BLOCK ((intptr_t)-2)
#define PANCAKE_IROH_EV_READABLE 1u
#define PANCAKE_IROH_EV_WRITABLE 2u
#define PANCAKE_IROH_EV_CLOSED 4u
#define PANCAKE_IROH_EV_ACCEPT 8u
#define PANCAKE_IROH_EV_CONNECT 16u

/* One drained readiness record. subject is 0 for EV_ACCEPT, the caller request
 * id for EV_CONNECT, and otherwise pancake_iroh_sidecar_conn_id(conn). The Zig
 * resident reads the identical layout, so this struct is kept in lockstep with
 * the Rust PancakeIrohReadyEvent and the resident's ReadyEvent. */
typedef struct pancake_iroh_sidecar_ready_event {
  size_t subject;
  uint32_t events;
} pancake_iroh_sidecar_ready_event;

/* An iroh endpoint: a bound QUIC socket pair plus the tokio runtime driving
 * it. Created by pancake_iroh_sidecar_endpoint_new; released by
 * pancake_iroh_sidecar_endpoint_free. */
typedef struct pancake_iroh_sidecar_endpoint pancake_iroh_sidecar_endpoint;

/* One QUIC connection carrying one bidirectional stream — the OCapN session's
 * byte channel. Created by pancake_iroh_sidecar_connect_blocking,
 * pancake_iroh_sidecar_endpoint_finish_connect, or
 * pancake_iroh_sidecar_accept; released by pancake_iroh_sidecar_conn_free. */
typedef struct pancake_iroh_sidecar_conn pancake_iroh_sidecar_conn;

/* Create an endpoint and bind its UDP sockets. `secret_seed32` is either NULL
 * (a fresh random Ed25519 endpoint key is generated) or a pointer to exactly
 * 32 bytes of secret key material the caller keeps owning. `reachability` is
 * one of PANCAKE_IROH_REACH_* and is mandatory — it decides whether the
 * endpoint uses relays or a discovery service, and there is no default. An
 * unknown value returns NULL. `connect_timeout_ms` is the per-endpoint
 * stream-establishment deadline in milliseconds (0 = the built-in default) that
 * bounds every dial connect + first-stream open and each accepted stream on
 * this endpoint. Returns an owned handle, or NULL on failure. Blocks until the
 * sockets are bound. */
pancake_iroh_sidecar_endpoint *pancake_iroh_sidecar_endpoint_new(const uint8_t *secret_seed32,
                                                                 uint32_t reachability,
                                                                 uint64_t connect_timeout_ms);

/* Write this endpoint's id — its Ed25519 public key, the dialable designator —
 * into `out` as lowercase hex (64 bytes; iroh's canonical string form, parsed
 * back by either connect surface). No terminator is written. Returns the byte
 * count written, or -1 when `out_cap` is too small. Borrows the handle. */
intptr_t pancake_iroh_sidecar_endpoint_node_id(const pancake_iroh_sidecar_endpoint *ep,
                                               uint8_t *out, size_t out_cap);

/* Write this endpoint's directly dialable socket addresses into `out` as a
 * comma-separated UTF-8 list (e.g. "127.0.0.1:5000,[::1]:5001"). Wildcard
 * bindings are reported in loopback form so the list is dialable on the local
 * host. This is the hint string a partner passes to either connect surface.
 * No terminator is written. Returns the byte count written, or -1 when
 * `out_cap` is too small. Borrows the handle. */
intptr_t pancake_iroh_sidecar_endpoint_direct_addrs(const pancake_iroh_sidecar_endpoint *ep,
                                                     uint8_t *out, size_t out_cap);

/* Dial a remote endpoint by id and open the session's one bidirectional
 * stream. `node_id`/`node_id_len` view the partner's id string; `addr_hints`/
 * `addr_hints_len` view its comma-separated direct-address list. An empty hint
 * list dials by id alone when the endpoint was bound with a discovery posture
 * (DISCOVERY, DISCOVERY_NO_RELAY, or LOCAL_DISCOVERY); a DIRECT endpoint needs
 * the hints. Both views are
 * borrowed for the call only. Blocks until the QUIC connection is up. The
 * returned stream is lazy: the dialer must write first, which OCapN
 * guarantees (the dialer sends op:start-session). Returns an owned handle,
 * or NULL on failure. The endpoint must outlive the connection.
 *
 * `out_code` (when non-NULL) receives a dial classification: 0 on success,
 * then on failure 1 = invalid (malformed id/hint), 2 = timed out, 3 =
 * unreachable (the QUIC connection could not be established), 4 = lost (up,
 * then the stream failed). iroh has no connection-refused: a dead port never
 * answers, so it times out. */
pancake_iroh_sidecar_conn *pancake_iroh_sidecar_connect_blocking(
    pancake_iroh_sidecar_endpoint *ep,
    const uint8_t *node_id, size_t node_id_len,
    const uint8_t *addr_hints, size_t addr_hints_len,
    int32_t *out_code);

/* Block until a partner dials this endpoint, then accept its connection and
 * its first bidirectional stream. Returns only once the dialer has written
 * its first bytes (QUIC bi streams are lazy; OCapN's dialer writes
 * op:start-session immediately). Returns an owned handle, or NULL on failure
 * or when the endpoint closes. The endpoint must outlive the connection. */
pancake_iroh_sidecar_conn *pancake_iroh_sidecar_accept(pancake_iroh_sidecar_endpoint *ep);

/* As pancake_iroh_sidecar_accept, but return NULL when timeout_ms elapses.
 * Private blocking-listener primitive; does not arm or drain readiness. */
pancake_iroh_sidecar_conn *pancake_iroh_sidecar_accept_timeout(
    pancake_iroh_sidecar_endpoint *ep, int32_t timeout_ms);

/* Read up to `len` bytes into `buf`, blocking until at least one byte
 * arrives. Returns the byte count (> 0), 0 at clean end of stream (the
 * partner finished its send side or closed the connection cleanly), or -1 on
 * error. Borrows the handle; `buf` is caller-owned. */
intptr_t pancake_iroh_sidecar_conn_read(pancake_iroh_sidecar_conn *conn, uint8_t *buf, size_t len);

/* Write all `len` bytes from `buf`, blocking until the QUIC flow-control
 * window accepts them. Returns `len` on success or -1 on error. Borrows the
 * handle; `buf` is caller-owned and fully consumed before return. */
intptr_t pancake_iroh_sidecar_conn_write(pancake_iroh_sidecar_conn *conn, const uint8_t *buf, size_t len);

/* Report stream health after writes. QUIC transmits written bytes eagerly, so
 * there is nothing buffered to push; returns 0 while the connection is alive
 * and -1 once it is closed or lost. Borrows the handle. */
int32_t pancake_iroh_sidecar_conn_flush(pancake_iroh_sidecar_conn *conn);

/* Gracefully close: finish the send stream (the partner reads a clean end of
 * stream) and queue a QUIC close. Idempotent. Borrows the handle; the handle
 * stays valid until pancake_iroh_sidecar_conn_free. */
void pancake_iroh_sidecar_conn_close(pancake_iroh_sidecar_conn *conn);

/* Release a connection handle, closing the connection first if still open.
 * NULL is a no-op. The handle is invalid afterward. */
void pancake_iroh_sidecar_conn_free(pancake_iroh_sidecar_conn *conn);

/* ── The event-driven scale superset (ADR-0057) ──────────────────────────── */

/* The OS readiness fd for this endpoint's scale surface: the read end of a
 * self-pipe the sidecar nudges whenever a connection (or the acceptor) becomes
 * ready. The completion loop registers this read-only fd once and polls it; on
 * wake it calls pancake_iroh_sidecar_endpoint_drain_ready. Returns -1 if the
 * readiness channel could not be created. Borrows the handle; the fd is owned by
 * the endpoint and valid until pancake_iroh_sidecar_endpoint_free. */
int32_t pancake_iroh_sidecar_endpoint_readiness_fd(const pancake_iroh_sidecar_endpoint *ep);

/* Drain pending readiness records into the caller's buffer. `out` points at
 * `out_cap` records; the call writes up to that many and returns the count
 * (>= 0), or -1 on error. The call clears coalesced fd bytes before draining
 * authoritative records. No allocation per call. If more remain queued than
 * fit, the endpoint re-nudges its readiness fd so the loop wakes again to drain
 * the rest. Borrows the handle. */
intptr_t pancake_iroh_sidecar_endpoint_drain_ready(const pancake_iroh_sidecar_endpoint *ep,
                                                   pancake_iroh_sidecar_ready_event *out,
                                                   size_t out_cap);

/* Admit one outbound dial without blocking. request_id is nonzero and unique
 * among this endpoint's live requests. The borrowed target is parsed before
 * return. A zero result promises exactly one EV_CONNECT carrying request_id;
 * a nonzero rejection owes no event. */
int32_t pancake_iroh_sidecar_endpoint_start_connect(
    pancake_iroh_sidecar_endpoint *ep, size_t request_id,
    const uint8_t *node_id, size_t node_id_len,
    const uint8_t *addr_hints, size_t addr_hints_len);

/* Consume one terminal dial result after EV_CONNECT. On success, writes one
 * owned connection to out_conn. Returns 0 on success, 1 invalid, 2 timed out,
 * 3 unreachable, 4 lost, 5 canceled, or 6 if called before completion. */
int32_t pancake_iroh_sidecar_endpoint_finish_connect(
    pancake_iroh_sidecar_endpoint *ep, size_t request_id,
    pancake_iroh_sidecar_conn **out_conn);

/* Cancel an admitted dial. The winning pending-to-canceled transition emits
 * the request's sole EV_CONNECT; canceling a terminal request is idempotent. */
int32_t pancake_iroh_sidecar_endpoint_cancel_connect(
    pancake_iroh_sidecar_endpoint *ep, size_t request_id);

/* Start the non-blocking acceptor: incoming connections surface through
 * pancake_iroh_sidecar_endpoint_try_accept and EV_ACCEPT readiness events
 * instead of the blocking accept. Idempotent. Returns 0 on success, -1 if the
 * readiness channel could not be created. Borrows the handle. */
int32_t pancake_iroh_sidecar_endpoint_set_nonblocking_accept(pancake_iroh_sidecar_endpoint *ep);

/* Claim one connection the acceptor has pulled off the wire, or NULL when none
 * is waiting (the non-blocking accept: NULL is WOULD_BLOCK, not failure — retry
 * on the next EV_ACCEPT). The returned handle is a fresh blocking connection;
 * the loop calls pancake_iroh_sidecar_conn_set_nonblocking on it. Returns an
 * owned handle or NULL. The endpoint must outlive the connection. */
pancake_iroh_sidecar_conn *pancake_iroh_sidecar_endpoint_try_accept(pancake_iroh_sidecar_endpoint *ep);

/* Move a connection onto the endpoint's readiness surface: the reader and writer
 * tasks take its streams, and from here try_read/try_write replace the blocking
 * conn_read/conn_write. Idempotent. Returns 0 on success, -1 if the readiness
 * channel is unavailable or the streams were already taken. `ep` must be the
 * endpoint that minted `conn`. Borrows both handles. */
int32_t pancake_iroh_sidecar_conn_set_nonblocking(pancake_iroh_sidecar_endpoint *ep,
                                                  pancake_iroh_sidecar_conn *conn);

/* Stable readiness identity, unique for the endpoint's lifetime and never
 * derived from the handle's allocation address. */
size_t pancake_iroh_sidecar_conn_id(const pancake_iroh_sidecar_conn *conn);

/* Non-blocking read: copy up to `len` buffered inbound bytes into `buf`. Returns
 * the byte count (> 0), 0 at clean end of stream, -1 on error, or
 * PANCAKE_IROH_WOULD_BLOCK when no bytes are buffered yet. The connection must
 * have been moved to the readiness surface. Borrows the handle. */
intptr_t pancake_iroh_sidecar_conn_try_read(pancake_iroh_sidecar_conn *conn, uint8_t *buf, size_t len);

/* Non-blocking write: enqueue all `len` bytes from `buf` for the writer task.
 * Returns `len` on success, -1 if the connection is closed, or
 * PANCAKE_IROH_WOULD_BLOCK when the outbound buffer is at its bound (re-arm on
 * the next EV_WRITABLE). The connection must have been moved to the readiness
 * surface. Borrows the handle. */
intptr_t pancake_iroh_sidecar_conn_try_write(pancake_iroh_sidecar_conn *conn, const uint8_t *buf, size_t len);

/* Close the endpoint without releasing its handle: a blocked
 * pancake_iroh_sidecar_accept returns NULL, subsequent dials fail, and queued
 * connection closes are delivered. Idempotent. Borrows the handle; the handle
 * stays valid until pancake_iroh_sidecar_endpoint_free. */
void pancake_iroh_sidecar_endpoint_close(pancake_iroh_sidecar_endpoint *ep);

/* Release an endpoint handle. Blocks while iroh delivers queued connection
 * closes, then shuts the runtime down. Free every connection minted from this
 * endpoint first. NULL is a no-op. */
void pancake_iroh_sidecar_endpoint_free(pancake_iroh_sidecar_endpoint *ep);

#ifdef __cplusplus
}
#endif

#endif /* PANCAKE_IROH_SIDECAR_H */
