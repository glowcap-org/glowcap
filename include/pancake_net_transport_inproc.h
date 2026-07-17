/* Generated from src/c_abi/net_transport/inproc/mod.zig by tools/gen/header/net_inproc.zig.
   Do not edit by hand: run `zig build gen-header-net-transport-inproc`.
   Function signatures are reflected from the Zig source, so this header
   cannot drift from the implementation.

   The in-process transport's public C ABI: a separate archive
   (libpancake_net_transport_inproc) from libpancake_ocapn (ADR-0059). It
   is a companion, not a superset: it exports only the pancake_inproc_*
   family and shares no core symbol with libpancake_ocapn, so a consumer
   links BOTH archives and includes BOTH headers. The shared frame, peer,
   and context vocabulary lives in pancake_ocapn.h (included below) and
   the archives agree on its layout; only the three in-process handles and
   the pancake_inproc_* prototypes are declared here. The in-process
   family has its own last-error slot, read through
   pancake_inproc_last_error rather than pancake_ocapn's
   pancake_last_error. */
#ifndef PANCAKE_NET_TRANSPORT_INPROC_H
#define PANCAKE_NET_TRANSPORT_INPROC_H

#include <stddef.h>
#include <stdint.h>
#include "pancake_ocapn.h"

#ifdef __cplusplus
extern "C" {
#endif
/* Orientation: the socket-free sibling of the TCP endpoints (pancake_net_transport_tcp.h):
   two peers in one process wired by in-process pipes, no kernel transport
   and no file descriptors. Same host-owns-the-peer frame shuttle and same
   netlayer lifecycle — create the netlayer, make connections/listeners from
   it, release them, then release it — but a listener binds to a string
   designator (any opaque token, not a host:port) and a dialer names that
   designator. This is the path a binding's smoke test dials to run a full
   OCapN conversation without touching a socket. Blocking; in-process only. */

/* An in-process netlayer: the switchboard plus the one owned I/O backend
   its pipes block on. Created by pancake_inproc_netlayer_new; released by
   pancake_inproc_netlayer_release after every endpoint is released. */
typedef struct PancakeInprocNetlayer PancakeInprocNetlayer;
/* One in-process connection carrying one OCapN session, framed on the
   netlayer's codec. Created by pancake_inproc_connect or
   pancake_inproc_accept; released by pancake_inproc_conn_release. */
typedef struct PancakeInprocConn PancakeInprocConn;
/* A bound in-process listener. Created by pancake_inproc_listen; released
   by pancake_inproc_listener_release. */
typedef struct PancakeInprocListener PancakeInprocListener;

/* Create the in-process netlayer handle that owns the switchboard and its I/O
   backend, allocating through the library allocator. Release with
   pancake_inproc_netlayer_release after releasing every endpoint made from it. */
int32_t pancake_inproc_netlayer_new(PancakeInprocNetlayer **out_netlayer);
/* Create an in-process netlayer whose switchboard, backend, and per-connection
   buffers allocate through `context`. */
int32_t pancake_inproc_netlayer_new_in(PancakeContext *context, PancakeInprocNetlayer **out_netlayer);
/* Release the in-process netlayer. Every connection and listener made from it
   must already be released. */
void pancake_inproc_netlayer_release(PancakeInprocNetlayer *netlayer);
/* Dial the listener bound at `designator` and return an owned connection
   framing on `codec`, refusing inbound frames over max_frame_bytes.
   `designator` is borrowed. PANCAKE_ERR_INVALID_ARGUMENT for a bad codec or a
   zero frame cap; PANCAKE_ERR_IO (see pancake_inproc_last_error) when no listener
   is bound there. Release with pancake_inproc_conn_release. */
int32_t pancake_inproc_connect(PancakeInprocNetlayer *netlayer, const uint8_t *designator, size_t designator_len, uint32_t codec, size_t max_frame_bytes, PancakeInprocConn **out_conn);
/* Bind an in-process listener on `designator` (any opaque token; borrowed).
   PANCAKE_ERR_INVALID_ARGUMENT for an empty or already-bound designator. Release
   with pancake_inproc_listener_release. */
int32_t pancake_inproc_listen(PancakeInprocNetlayer *netlayer, const uint8_t *designator, size_t designator_len, PancakeInprocListener **out_listener);
/* Block until a dialer connects, returning an owned connection framing on
   `codec`. Same argument and release contract as pancake_inproc_connect. */
int32_t pancake_inproc_accept(PancakeInprocListener *listener, uint32_t codec, size_t max_frame_bytes, PancakeInprocConn **out_conn);
/* Block for one whole frame as an owned managed frame. Returns
   PANCAKE_ERR_CLOSED on graceful EOF. */
int32_t pancake_inproc_conn_read_frame(PancakeInprocConn *conn, PancakeManagedFrame *out_frame);
/* Write one frame's borrowed bytes into the partner's pipe. */
int32_t pancake_inproc_conn_write_frame(PancakeInprocConn *conn, const PancakeFrame *frame);
/* Close the connection and free the handle; do not use `conn` afterward. */
void pancake_inproc_conn_release(PancakeInprocConn *conn);
/* Close the listener and free the handle; do not use `listener` afterward. */
void pancake_inproc_listener_release(PancakeInprocListener *listener);
/* Copy the calling thread's last in-process-transport error into out_buf, the
   inproc sibling of pancake_last_error, reading this archive's own per-thread
   slot. A pancake_inproc_* call that returns a cause-bearing code records it
   here. Copies at most cap-1 bytes and NUL-terminates when cap>0; out_buf NULL or
   cap 0 queries the length. Returns the full message length, or 0 when none is
   set. */
size_t pancake_inproc_last_error(uint8_t *out_buf, size_t cap);
/* Clear the calling thread's in-process-transport last-error slot. */
void pancake_inproc_clear_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* PANCAKE_NET_TRANSPORT_INPROC_H */
