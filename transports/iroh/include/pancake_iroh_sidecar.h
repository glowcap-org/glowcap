/* pancake_iroh_sidecar.h — the C seam of the iroh netlayer sidecar (ADR-0055).
 *
 * Hand-written. The implementation is transports/iroh/src/lib.rs (a Rust
 * staticlib over the iroh crate, emitting libpancake_iroh_sidecar.a); the
 * consumer is the Zig resident src/net_adapter/iroh.zig. Every call below
 * blocks the calling thread: the endpoint owns a private tokio runtime behind
 * its opaque handle and each call runs to completion against it. No call
 * panics across this boundary; failures come back as null handles or negative
 * return values.
 *
 * This is the private byte-level seam. It is deliberately prefixed
 * pancake_iroh_sidecar_* so it shares no symbol prefix with the public
 * frame-level ABI (pancake_iroh_netlayer_*, in include/pancake_iroh.h): the
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

/* An iroh endpoint: a bound QUIC socket pair plus the tokio runtime driving
 * it. Created by pancake_iroh_sidecar_endpoint_new; released by
 * pancake_iroh_sidecar_endpoint_free. */
typedef struct pancake_iroh_sidecar_endpoint pancake_iroh_sidecar_endpoint;

/* One QUIC connection carrying one bidirectional stream — the OCapN session's
 * byte channel. Created by pancake_iroh_sidecar_connect or
 * pancake_iroh_sidecar_accept; released by pancake_iroh_sidecar_conn_free. */
typedef struct pancake_iroh_sidecar_conn pancake_iroh_sidecar_conn;

/* Create an endpoint and bind its UDP sockets. `secret_seed32` is either NULL
 * (a fresh random Ed25519 endpoint key is generated) or a pointer to exactly
 * 32 bytes of secret key material the caller keeps owning. `reachability` is
 * one of PANCAKE_IROH_REACH_* and is mandatory — it decides whether the
 * endpoint uses relays or a discovery service, and there is no default. An
 * unknown value returns NULL. Returns an owned handle, or NULL on failure.
 * Blocks until the sockets are bound. */
pancake_iroh_sidecar_endpoint *pancake_iroh_sidecar_endpoint_new(const uint8_t *secret_seed32,
                                                                 uint32_t reachability);

/* Write this endpoint's id — its Ed25519 public key, the dialable designator —
 * into `out` as lowercase hex (64 bytes; iroh's canonical string form, parsed
 * back by pancake_iroh_sidecar_connect). No terminator is written. Returns the
 * byte count written, or -1 when `out_cap` is too small. Borrows the handle. */
intptr_t pancake_iroh_sidecar_endpoint_node_id(const pancake_iroh_sidecar_endpoint *ep,
                                               uint8_t *out, size_t out_cap);

/* Write this endpoint's directly dialable socket addresses into `out` as a
 * comma-separated UTF-8 list (e.g. "127.0.0.1:5000,[::1]:5001"). Wildcard
 * bindings are reported in loopback form so the list is dialable on the local
 * host. This is the hint string a partner passes to pancake_iroh_sidecar_connect.
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
 * or NULL on failure. The endpoint must outlive the connection. */
pancake_iroh_sidecar_conn *pancake_iroh_sidecar_connect(pancake_iroh_sidecar_endpoint *ep,
                                                        const uint8_t *node_id, size_t node_id_len,
                                                        const uint8_t *addr_hints, size_t addr_hints_len);

/* Block until a partner dials this endpoint, then accept its connection and
 * its first bidirectional stream. Returns only once the dialer has written
 * its first bytes (QUIC bi streams are lazy; OCapN's dialer writes
 * op:start-session immediately). Returns an owned handle, or NULL on failure
 * or when the endpoint closes. The endpoint must outlive the connection. */
pancake_iroh_sidecar_conn *pancake_iroh_sidecar_accept(pancake_iroh_sidecar_endpoint *ep);

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
