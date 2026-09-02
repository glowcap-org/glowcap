/* glowcap_iroh_sidecar.h — the C seam of the iroh netlayer sidecar (ADR-0055).
 *
 * Hand-written. The implementation is transports/iroh/src/lib.rs (a Rust
 * staticlib over the iroh crate, emitting libglowcap_iroh_sidecar.a); the
 * consumer is the Zig sidecar owner src/net/transport/iroh/sidecar.zig. The
 * explicitly blocking calls (connect_blocking/accept/conn_read/conn_write)
 * block the calling thread. Evented connect, accept, and stream I/O report
 * terminal/readiness state over one fd so a single loop thread multiplexes
 * many connections. The endpoint owns the private tokio runtime driving both
 * surfaces. No call panics across this boundary; failures come back as null
 * handles or negative return values.
 *
 * This is the private byte-level seam. It is deliberately prefixed
 * glowcap_iroh_sidecar_* so it shares no symbol prefix with the public
 * frame-level ABI (glowcap_iroh_netlayer_*, in include/glowcap_net_transport_iroh.h): the
 * two link into one library without colliding.
 *
 * Lifetime order: free every connection before its endpoint, and free the
 * endpoint last. Handles are owned by exactly one caller and are not
 * reference-counted.
 */

#ifndef GLOWCAP_IROH_SIDECAR_H
#define GLOWCAP_IROH_SIDECAR_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Reachability postures for glowcap_iroh_sidecar_endpoint_new. The caller
 * always passes one — there is no default. A glowcap peer never turns on relays
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
#define GLOWCAP_IROH_REACH_DIRECT 0u
#define GLOWCAP_IROH_REACH_DISCOVERY 1u
#define GLOWCAP_IROH_REACH_DISCOVERY_NO_RELAY 2u
#define GLOWCAP_IROH_REACH_LOCAL_DISCOVERY 3u

/* The event-driven surface (ADR-0057). An endpoint serves many connections
 * from one host thread: the loop polls one readiness fd, drains
 * (subject, events) records, and drives non-blocking byte I/O. WOULD_BLOCK is
 * the try_read/try_write sentinel, distinct from 0 (clean end of stream) and
 * -1 (error). EV_ACCEPT uses subject 0; EV_CONNECT uses the caller's request
 * id; connection I/O uses a stable endpoint-scoped connection id. */
#define GLOWCAP_IROH_WOULD_BLOCK ((intptr_t)-2)
#define GLOWCAP_IROH_EV_READABLE 1u
#define GLOWCAP_IROH_EV_WRITABLE 2u
#define GLOWCAP_IROH_EV_CLOSED 4u
#define GLOWCAP_IROH_EV_ACCEPT 8u
#define GLOWCAP_IROH_EV_CONNECT 16u

/* One drained readiness record. subject is 0 for EV_ACCEPT, the caller request
 * id for EV_CONNECT, and otherwise glowcap_iroh_sidecar_conn_id(conn). The Zig
 * resident reads the identical layout, so this struct is kept in lockstep with
 * the Rust GlowcapIrohReadyEvent and the resident's ReadyEvent. */
typedef struct glowcap_iroh_sidecar_ready_event {
  size_t subject;
  uint32_t events;
} glowcap_iroh_sidecar_ready_event;

/* An iroh endpoint: a bound QUIC socket pair plus the tokio runtime driving
 * it. Created by glowcap_iroh_sidecar_endpoint_new; released by
 * glowcap_iroh_sidecar_endpoint_free. */
typedef struct glowcap_iroh_sidecar_endpoint glowcap_iroh_sidecar_endpoint;

/* One QUIC connection carrying one bidirectional stream — the OCapN session's
 * byte channel. Created by glowcap_iroh_sidecar_connect_blocking,
 * glowcap_iroh_sidecar_endpoint_finish_connect, or the bounded accept;
 * released by glowcap_iroh_sidecar_conn_free. */
typedef struct glowcap_iroh_sidecar_conn glowcap_iroh_sidecar_conn;

/* One endpoint's configuration, passed by pointer so a new setting is a field
 * rather than a wider signature every caller has to agree on. `reachability` is
 * one of GLOWCAP_IROH_REACH_* and is mandatory — it decides whether the
 * endpoint uses relays or a discovery service, and there is no default. An
 * unknown value returns NULL.
 *
 * `connect_timeout_ms` is the per-endpoint stream-establishment deadline in
 * milliseconds that bounds every dial connect + first-stream open and each
 * accepted stream on this endpoint.
 *
 * `idle_timeout_ms` is how long a connection survives with nothing arriving on
 * it, and so how quickly a peer that was killed rather than closed stops
 * counting as connected: such a peer sends nothing, and UDP has no equivalent
 * of the FIN a dying TCP process gets from the operating system, so nothing
 * else ends the connection. There is no keep-alive beside it; the sidecar
 * derives the heartbeat from this timeout so the two cannot be put out of step.
 *
 * `worker_threads` sizes this endpoint's private tokio runtime; 0 selects the
 * sidecar default. It is an endpoint cost, not a per-connection cost.
 *
 * 0 means the built-in default for either timeout or the worker count. */
typedef struct glowcap_iroh_sidecar_endpoint_config {
  uint32_t reachability;
  uint64_t connect_timeout_ms;
  uint64_t idle_timeout_ms;
  uint32_t worker_threads;
} glowcap_iroh_sidecar_endpoint_config;

/* Create an endpoint and bind its UDP sockets. `secret_seed32` is either NULL
 * (a fresh random Ed25519 endpoint key is generated) or a pointer to exactly
 * 32 bytes of secret key material the caller keeps owning. `config` is
 * mandatory; a NULL one returns NULL. Returns an owned handle, or NULL on
 * failure. Blocks until the sockets are bound. */
glowcap_iroh_sidecar_endpoint *glowcap_iroh_sidecar_endpoint_new(
    const uint8_t *secret_seed32,
    const glowcap_iroh_sidecar_endpoint_config *config);

/* Write this endpoint's id — its Ed25519 public key, the dialable designator —
 * into `out` as lowercase hex (64 bytes; iroh's canonical string form, parsed
 * back by either connect surface). No terminator is written. Returns the
 * complete byte count and copies only when `out_cap` is large enough; a
 * zero-capacity call is the size query. Borrows the handle. */
intptr_t glowcap_iroh_sidecar_endpoint_node_id(const glowcap_iroh_sidecar_endpoint *ep,
                                               uint8_t *out, size_t out_cap);

/* Write this endpoint's directly dialable socket addresses into `out` as a
 * comma-separated UTF-8 list (e.g. "127.0.0.1:5000,[::1]:5001"). Wildcard
 * bindings are reported in loopback form so the list is dialable on the local
 * host. This is the hint string a partner passes to either connect surface.
 * No terminator is written. Returns the complete byte count and copies only
 * when `out_cap` is large enough; a zero-capacity call is the size query.
 * Borrows the handle. */
intptr_t glowcap_iroh_sidecar_endpoint_direct_addrs(const glowcap_iroh_sidecar_endpoint *ep,
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
glowcap_iroh_sidecar_conn *glowcap_iroh_sidecar_connect_blocking(
    glowcap_iroh_sidecar_endpoint *ep,
    const uint8_t *node_id, size_t node_id_len,
    const uint8_t *addr_hints, size_t addr_hints_len,
    int32_t *out_code);

/* Wait at most timeout_ms for a partner connection and first bidirectional
 * stream. Returns only after the dialer has written its first bytes (QUIC bi
 * streams are lazy; OCapN's dialer writes op:start-session immediately), or
 * NULL with out_code set to the same classification connect_blocking uses:
 * 2 for a bounded timeout, 1 for a null endpoint or negative timeout, and 4
 * for endpoint close, panic, or stream-handle construction failure. out_code
 * is mandatory. Private resident-listener primitive; does not arm or drain
 * readiness. */
glowcap_iroh_sidecar_conn *glowcap_iroh_sidecar_accept_timeout(
    glowcap_iroh_sidecar_endpoint *ep, int32_t timeout_ms,
    int32_t *out_code);

/* Write the connection's QUIC-authenticated remote endpoint id — the 32-byte
 * Ed25519 public key TLS verified during the handshake — into `out_key32`
 * (caller-owned, at least 32 bytes). The transport-layer peer proof the
 * driver installs as pre-feed CapTP hello policy on accept paths (ADR-0097).
 * Returns 0 on success, -1 on failure. Borrows the handle. */
int32_t glowcap_iroh_sidecar_conn_remote_node_id(const glowcap_iroh_sidecar_conn *conn, uint8_t *out_key32);

/* Read up to `len` bytes into `buf`, blocking until at least one byte
 * arrives. Returns the byte count (> 0), 0 at clean end of stream (the
 * partner finished its send side or closed the connection cleanly), or -1 on
 * error. Borrows the handle; `buf` is caller-owned. */
intptr_t glowcap_iroh_sidecar_conn_read(glowcap_iroh_sidecar_conn *conn, uint8_t *buf, size_t len);

/* Write all `len` bytes from `buf`, blocking until the QUIC flow-control
 * window accepts them. Returns `len` on success or -1 on error. Borrows the
 * handle; `buf` is caller-owned and fully consumed before return. */
intptr_t glowcap_iroh_sidecar_conn_write(glowcap_iroh_sidecar_conn *conn, const uint8_t *buf, size_t len);

/* Report stream health after writes. QUIC transmits written bytes eagerly, so
 * there is nothing buffered to push; returns 0 while the connection is alive
 * and -1 once it is closed or lost. Borrows the handle. */
int32_t glowcap_iroh_sidecar_conn_flush(glowcap_iroh_sidecar_conn *conn);

/* Gracefully close. A blocking-surface connection finishes its send stream and
 * closes QUIC. A readiness-surface connection marks its writer closed so the
 * writer drains admitted bytes and finishes the stream asynchronously, without
 * parking the caller's reactor thread. Idempotent. Borrows the handle; the
 * handle stays valid until glowcap_iroh_sidecar_conn_free. */
void glowcap_iroh_sidecar_conn_close(glowcap_iroh_sidecar_conn *conn);

/* Release a connection handle, closing it first if still open. A
 * readiness-surface connection transfers any admitted final write batch to its
 * writer task, which drains asynchronously; release never joins that task on
 * the caller's reactor thread. NULL is a no-op. The handle is invalid afterward. */
void glowcap_iroh_sidecar_conn_free(glowcap_iroh_sidecar_conn *conn);

/* ── The event-driven scale superset (ADR-0057) ──────────────────────────── */

/* The OS readiness fd for this endpoint's scale surface: the read end of a
 * self-pipe the sidecar nudges whenever a connection (or the acceptor) becomes
 * ready. The completion loop registers this read-only fd once and polls it; on
 * wake it calls glowcap_iroh_sidecar_endpoint_drain_ready. Returns -1 if the
 * readiness channel could not be created. Borrows the handle; the fd is owned by
 * the endpoint and valid until glowcap_iroh_sidecar_endpoint_free. */
int32_t glowcap_iroh_sidecar_endpoint_readiness_fd(const glowcap_iroh_sidecar_endpoint *ep);

/* Drain pending readiness records into the caller's buffer. `out` points at
 * `out_cap` records; the call writes up to that many and returns the count
 * (>= 0), or -1 on error. The call clears coalesced fd bytes before draining
 * authoritative records. No allocation per call. If more remain queued than
 * fit, the endpoint re-nudges its readiness fd so the loop wakes again to drain
 * the rest. Borrows the handle. */
intptr_t glowcap_iroh_sidecar_endpoint_drain_ready(const glowcap_iroh_sidecar_endpoint *ep,
                                                   glowcap_iroh_sidecar_ready_event *out,
                                                   size_t out_cap);

/* Admit one outbound dial without blocking. request_id is nonzero and unique
 * among this endpoint's live requests. The borrowed target is parsed before
 * return. A zero result promises exactly one EV_CONNECT carrying request_id;
 * a nonzero rejection owes no event. */
int32_t glowcap_iroh_sidecar_endpoint_start_connect(
    glowcap_iroh_sidecar_endpoint *ep, size_t request_id,
    const uint8_t *node_id, size_t node_id_len,
    const uint8_t *addr_hints, size_t addr_hints_len);

/* Consume one terminal dial result after EV_CONNECT. On success, writes one
 * owned connection to out_conn. Returns 0 on success, 1 invalid, 2 timed out,
 * 3 unreachable, 4 lost, 5 canceled, or 6 if called before completion. */
int32_t glowcap_iroh_sidecar_endpoint_finish_connect(
    glowcap_iroh_sidecar_endpoint *ep, size_t request_id,
    glowcap_iroh_sidecar_conn **out_conn);

/* Cancel an admitted dial. The winning pending-to-canceled transition emits
 * the request's sole EV_CONNECT; canceling a terminal request is idempotent. */
int32_t glowcap_iroh_sidecar_endpoint_cancel_connect(
    glowcap_iroh_sidecar_endpoint *ep, size_t request_id);

/* Start the non-blocking acceptor: incoming connections surface through
 * glowcap_iroh_sidecar_endpoint_try_accept and EV_ACCEPT readiness events
 * instead of the blocking accept. Idempotent. Returns 0 on success, -1 if the
 * readiness channel could not be created. Borrows the handle. */
int32_t glowcap_iroh_sidecar_endpoint_set_nonblocking_accept(glowcap_iroh_sidecar_endpoint *ep);

/* Claim one connection the acceptor has pulled off the wire, or NULL when none
 * is waiting (the non-blocking accept: NULL is WOULD_BLOCK, not failure — retry
 * on the next EV_ACCEPT). The returned handle is a fresh blocking connection;
 * the loop calls glowcap_iroh_sidecar_conn_set_nonblocking on it. Returns an
 * owned handle or NULL. The endpoint must outlive the connection. */
glowcap_iroh_sidecar_conn *glowcap_iroh_sidecar_endpoint_try_accept(glowcap_iroh_sidecar_endpoint *ep);

/* Move a connection onto the endpoint's readiness surface: the reader and writer
 * tasks take its streams, and from here try_read/try_write replace the blocking
 * conn_read/conn_write. Idempotent. Returns 0 on success, -1 if the readiness
 * channel is unavailable or the streams were already taken. `ep` must be the
 * endpoint that minted `conn`. Borrows both handles. */
int32_t glowcap_iroh_sidecar_conn_set_nonblocking(glowcap_iroh_sidecar_endpoint *ep,
                                                  glowcap_iroh_sidecar_conn *conn);

/* Stable readiness identity, unique for the endpoint's lifetime and never
 * derived from the handle's allocation address. */
size_t glowcap_iroh_sidecar_conn_id(const glowcap_iroh_sidecar_conn *conn);

/* Non-blocking read: copy up to `len` buffered inbound bytes into `buf`. Returns
 * the byte count (> 0), 0 at clean end of stream, -1 on error, or
 * GLOWCAP_IROH_WOULD_BLOCK when no bytes are buffered yet. The connection must
 * have been moved to the readiness surface. Borrows the handle. */
intptr_t glowcap_iroh_sidecar_conn_try_read(glowcap_iroh_sidecar_conn *conn, uint8_t *buf, size_t len);

/* Non-blocking write: copy the prefix that fits into the bounded outbound
 * buffer for the writer task. Returns the admitted byte count, -1 if the
 * connection is closed, or GLOWCAP_IROH_WOULD_BLOCK when no outbound room
 * remains (re-arm on the next EV_WRITABLE). The connection must have been moved
 * to the readiness surface. Borrows the handle. */
intptr_t glowcap_iroh_sidecar_conn_try_write(glowcap_iroh_sidecar_conn *conn, const uint8_t *buf, size_t len);

/* Close the endpoint without releasing its handle: an in-flight bounded accept
 * returns NULL, subsequent dials fail, and queued connection closes are
 * delivered. Idempotent. Borrows the handle; the handle stays valid until
 * glowcap_iroh_sidecar_endpoint_free. */
void glowcap_iroh_sidecar_endpoint_close(glowcap_iroh_sidecar_endpoint *ep);

/* Release an endpoint handle. Blocks while iroh delivers queued connection
 * closes, then shuts the runtime down. Free every connection minted from this
 * endpoint first. NULL is a no-op. */
/* Consumes ep and returns 0 after clean shutdown, or -1 when teardown panicked.
 * No panic crosses the archive boundary. */
int32_t glowcap_iroh_sidecar_endpoint_free(glowcap_iroh_sidecar_endpoint *ep);

#ifdef __cplusplus
}
#endif

#endif /* GLOWCAP_IROH_SIDECAR_H */
