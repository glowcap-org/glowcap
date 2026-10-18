/* Generated from src/c_abi/net_transport/inproc/mod.zig by tools/gen/header/net_inproc.zig.
   Do not edit by hand: run `zig build gen-header-net-transport-inproc`.
   Function signatures are reflected from the Zig source, so this header
   cannot drift from the implementation.

   The in-process transport's public C ABI: a separate archive
   (libglowcap_net_transport_inproc) from libglowcap_ocapn (ADR-0059). It
   is a companion, not a superset: it exports only the glowcap_inproc_*
   family and shares no core symbol with libglowcap_ocapn, so a consumer
   links BOTH archives and includes BOTH headers. The shared frame, peer,
   and context vocabulary lives in glowcap_ocapn.h (included below) and
   the archives agree on its layout; only the three in-process handles and
   the glowcap_inproc_* prototypes are declared here. The in-process
   family has its own last-error slot, read through
   glowcap_inproc_last_error rather than glowcap_ocapn's
   glowcap_last_error. */
#ifndef GLOWCAP_NET_TRANSPORT_INPROC_H
#define GLOWCAP_NET_TRANSPORT_INPROC_H

#include <stddef.h>
#include <stdint.h>
#include "glowcap_ocapn.h"

#ifdef __cplusplus
extern "C" {
#endif
/* Orientation: the socket-free sibling of the TCP endpoints (glowcap_net_transport_tcp.h):
   two peers in one process wired by in-process pipes and no kernel transport.
   The listener exposes a wake descriptor for foreign reactors. The same
   host-owns-the-peer frame shuttle and
   netlayer lifecycle (create the netlayer, make connections/listeners from
   it, release them, then release it), but a listener binds to a string
   designator (any opaque token, not a host:port) and a dialer names that
   designator. This is the path a binding's smoke test dials to run a full
   OCapN conversation without touching a socket. Blocking; in-process only. */

/* An in-process netlayer: the switchboard plus the one owned I/O backend
   its pipes block on. Created by glowcap_inproc_netlayer_new; released by
   glowcap_inproc_netlayer_release after every endpoint is released. */
typedef struct GlowcapInprocNetlayer GlowcapInprocNetlayer;
/* One in-process connection carrying one OCapN session, framed on the
   netlayer's codec. One read and one write may run concurrently; calls in
   the same direction are serialized by the archive. Created by
   glowcap_inproc_connect or glowcap_inproc_accept; released by
   glowcap_inproc_conn_release. */
typedef struct GlowcapInprocConn GlowcapInprocConn;
/* A bound in-process listener. Created by glowcap_inproc_listen; released
   by glowcap_inproc_listener_release. */
typedef struct GlowcapInprocListener GlowcapInprocListener;

/* Return the exact callable-surface fingerprint. Compare it with the binding-generated GLOWCAP_INPROC_ARCHIVE_FINGERPRINT before any other call. */
uint64_t glowcap_inproc_archive_fingerprint(void);
/* Create the in-process netlayer handle that owns the switchboard and its I/O
   backend, allocating through the library allocator. Release with
   glowcap_inproc_netlayer_release after releasing every endpoint made from it. */
int32_t glowcap_inproc_netlayer_new(GlowcapInprocNetlayer **out_netlayer);
/* Create an in-process netlayer whose switchboard, backend, and per-connection
   buffers allocate through `context`. */
int32_t glowcap_inproc_netlayer_new_in(GlowcapContext *context, GlowcapInprocNetlayer **out_netlayer);
/* Release the in-process netlayer. Every connection and listener made from it
   must already be released. */
void glowcap_inproc_netlayer_release(GlowcapInprocNetlayer *netlayer);
/* Dial the listener bound at `designator` and return an owned connection
   framing on `codec`, refusing inbound frames over max_frame_bytes.
   `designator` is borrowed. GLOWCAP_ERR_INVALID_ARGUMENT for a bad codec or a
   zero frame cap; GLOWCAP_ERR_IO when no listener is bound there. Release with
   glowcap_inproc_conn_release.

   out_error/out_error_len optionally capture this call's diagnostic before an
   off-thread runtime regains control: omit all three diagnostic arguments, or
   provide out_error_len. It receives the full length; out_error receives at most
   error_cap - 1 bytes and is NUL-terminated when error_cap is nonzero. */
int32_t glowcap_inproc_connect(GlowcapInprocNetlayer *netlayer, const uint8_t *designator, size_t designator_len, uint32_t codec, size_t max_frame_bytes, GlowcapInprocConn **out_conn, uint8_t *out_error, size_t error_cap, size_t *out_error_len);
/* Bind an in-process listener on `designator` (any opaque token; borrowed).
   GLOWCAP_ERR_INVALID_ARGUMENT for an empty designator; GLOWCAP_ERR_IO when it is
   already bound. Release with glowcap_inproc_listener_release. */
int32_t glowcap_inproc_listen(GlowcapInprocNetlayer *netlayer, const uint8_t *designator, size_t designator_len, GlowcapInprocListener **out_listener);
/* Return the borrowed wake descriptor nudged when a dial is queued. Park an
   external reactor on it before glowcap_inproc_accept. The listener owns the fd;
   do not close it or use it after glowcap_inproc_listener_release. */
int32_t glowcap_inproc_listener_readiness_fd(GlowcapInprocListener *listener, int32_t *out_fd);
/* Block until a dialer connects, returning an owned connection framing on
   `codec`. Same argument and release contract as glowcap_inproc_connect.

   out_error/out_error_len optionally capture this call's diagnostic before an
   off-thread runtime regains control: omit all three diagnostic arguments, or
   provide out_error_len. It receives the full length; out_error receives at most
   error_cap - 1 bytes and is NUL-terminated when error_cap is nonzero. */
int32_t glowcap_inproc_accept(GlowcapInprocListener *listener, uint32_t codec, size_t max_frame_bytes, GlowcapInprocConn **out_conn, uint8_t *out_error, size_t error_cap, size_t *out_error_len);
/* Block for one whole frame as an owned managed frame. Returns
   GLOWCAP_ERR_CLOSED on graceful EOF.

   out_error/out_error_len optionally capture this call's diagnostic before an
   off-thread runtime regains control: omit all three diagnostic arguments, or
   provide out_error_len. It receives the full length; out_error receives at most
   error_cap - 1 bytes and is NUL-terminated when error_cap is nonzero. */
int32_t glowcap_inproc_conn_read_frame(GlowcapInprocConn *conn, GlowcapManagedFrame *out_frame, uint8_t *out_error, size_t error_cap, size_t *out_error_len);
/* Write one frame's borrowed bytes into the partner's pipe. Returns
   GLOWCAP_ERR_CLOSED after shutdown begins.

   out_error/out_error_len optionally capture this call's diagnostic before an
   off-thread runtime regains control: omit all three diagnostic arguments, or
   provide out_error_len. It receives the full length; out_error receives at most
   error_cap - 1 bytes and is NUL-terminated when error_cap is nonzero. */
int32_t glowcap_inproc_conn_write_frame(GlowcapInprocConn *conn, const GlowcapFrame *frame, uint8_t *out_error, size_t error_cap, size_t *out_error_len);
/* Seal admission and interrupt blocked reads and writes without freeing
   the connection. May race operations; join the embedding's leases before release.
   Idempotent. */
void glowcap_inproc_conn_shutdown(GlowcapInprocConn *conn);
/* After stopping new calls, invoking shutdown, and joining the embedding's
   operation leases, close and free the handle. Release must not race call initiation. */
void glowcap_inproc_conn_release(GlowcapInprocConn *conn);
/* Seal accept admission and wake a blocked accept without freeing the
   listener. May race operations; join the embedding's leases before release. Idempotent. */
void glowcap_inproc_listener_shutdown(GlowcapInprocListener *listener);
/* After stopping new calls, invoking shutdown, and joining the embedding's
   operation leases, close and free the listener. Release must not race call
   initiation.

   out_error/out_error_len optionally capture this call's diagnostic before an
   off-thread runtime regains control: omit all three diagnostic arguments, or
   provide out_error_len. It receives the full length; out_error receives at most
   error_cap - 1 bytes and is NUL-terminated when error_cap is nonzero. */
int32_t glowcap_inproc_listener_release(GlowcapInprocListener *listener, uint8_t *out_error, size_t error_cap, size_t *out_error_len);
/* Copy the calling thread's last in-process-transport error into out_buf, the
   inproc sibling of glowcap_last_error, reading this archive's own per-thread
   slot. A glowcap_inproc_* call that returns a cause-bearing code records it
   here. Copies at most cap-1 bytes and NUL-terminates when cap>0; out_buf NULL or
   cap 0 queries the length. Returns the full message length, or 0 when none is
   set. Every status-returning call clears the slot before validation; read it immediately after a failing call, and treat zero length as no additional detail. */
size_t glowcap_inproc_last_error(uint8_t *out_buf, size_t cap);
/* Clear the calling thread's in-process-transport last-error slot. */
void glowcap_inproc_clear_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* GLOWCAP_NET_TRANSPORT_INPROC_H */
