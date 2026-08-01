/* Generated from src/c_abi/net_transport/tcp/mod.zig by tools/gen/header/net_tcp.zig.
   Do not edit by hand: run `zig build gen-header-net-transport-tcp`.
   Function signatures are reflected from the Zig source, so this header
   cannot drift from the implementation.

   The TCP transport's public C ABI: a separate archive
   (libpancake_net_transport_tcp) from libpancake_ocapn (ADR-0059). It is
   a companion, not a superset: it exports only the pancake_tcp_* family
   and shares no core symbol with libpancake_ocapn, so a consumer links
   BOTH archives and includes BOTH headers. The shared frame and
   context vocabulary lives in pancake_ocapn.h (included below) and the
   archives agree on its layout; only the three TCP handles and the
   pancake_tcp_* prototypes are declared here. The TCP family has its own
   last-error slot, read through pancake_tcp_last_error rather than
   pancake_ocapn's pancake_last_error. */
#ifndef PANCAKE_NET_TRANSPORT_TCP_H
#define PANCAKE_NET_TRANSPORT_TCP_H

#include <stddef.h>
#include <stdint.h>
#include "pancake_ocapn.h"

#ifdef __cplusplus
extern "C" {
#endif
/* Orientation: blocking, cleartext TCP for a byte-fed PancakeHost. Read a
   frame with pancake_tcp_conn_read_frame, feed its bytes to the Host, and
   write Host output with pancake_tcp_conn_write_frame. The netlayer owns
   the I/O backend; create
   it, make connections/listeners from it, then release it after every
   endpoint made from it is released. There is no TLS. */

/* A TCP netlayer: the one owned I/O backend the endpoints run on.
   Created by pancake_tcp_netlayer_new; released by
   pancake_tcp_netlayer_release after every endpoint is released. */
typedef struct PancakeTcpNetlayer PancakeTcpNetlayer;
/* One blocking TCP connection carrying one OCapN session, framed on the
   netlayer's codec. Created by pancake_tcp_connect or pancake_tcp_accept;
   released by pancake_tcp_conn_release. */
typedef struct PancakeTcpConn PancakeTcpConn;
/* A bound TCP listener. Created by pancake_tcp_listen; released by
   pancake_tcp_listener_release. */
typedef struct PancakeTcpListener PancakeTcpListener;
/* Create the netlayer handle that owns the blocking I/O backend, allocating
   through the library allocator. Release with pancake_tcp_netlayer_release
   after releasing every endpoint made from it. */
int32_t pancake_tcp_netlayer_new(PancakeTcpNetlayer **out_netlayer);
/* Create a netlayer whose backend and per-connection buffers allocate through
   `context`. */
int32_t pancake_tcp_netlayer_new_in(PancakeContext *context, PancakeTcpNetlayer **out_netlayer);
/* Release the netlayer and its I/O backend. Every connection and listener
   made from it must already be released. */
void pancake_tcp_netlayer_release(PancakeTcpNetlayer *netlayer);
/* Connect to host:port and return an owned connection framing on `codec`,
   refusing inbound frames over max_frame_bytes. Blocking; `host` is borrowed.
   PANCAKE_ERR_INVALID_ARGUMENT for a bad codec, a zero frame cap, or an
   unparseable address; PANCAKE_ERR_IO (see pancake_tcp_last_error) when the
   dial fails. Release with pancake_tcp_conn_release. */
int32_t pancake_tcp_connect(PancakeTcpNetlayer *netlayer, const uint8_t *host, size_t host_len, uint16_t port, uint32_t codec, size_t max_frame_bytes, PancakeTcpConn **out_conn);
/* Bind and listen on host:port (port 0 picks an OS-chosen port; read it back
   with pancake_tcp_listener_port). Release with pancake_tcp_listener_release. */
int32_t pancake_tcp_listen(PancakeTcpNetlayer *netlayer, const uint8_t *host, size_t host_len, uint16_t port, PancakeTcpListener **out_listener);
/* The OS-resolved local port of a listener (useful after binding to port 0). */
int32_t pancake_tcp_listener_port(PancakeTcpListener *listener, uint16_t *out_port);
/* Block until a client connects, returning an owned connection framing on
   `codec`. Same argument and release contract as pancake_tcp_connect. */
int32_t pancake_tcp_accept(PancakeTcpListener *listener, uint32_t codec, size_t max_frame_bytes, PancakeTcpConn **out_conn);
/* Block for one whole frame as an owned managed frame. Returns PANCAKE_ERR_CLOSED
   on graceful EOF, PANCAKE_ERR_IO on a socket fault. */
int32_t pancake_tcp_conn_read_frame(PancakeTcpConn *conn, PancakeManagedFrame *out_frame);
/* Write one frame's borrowed bytes and flush. */
int32_t pancake_tcp_conn_write_frame(PancakeTcpConn *conn, const PancakeFrame *frame);
/* Close the connection and free the handle; do not use `conn` afterward. */
void pancake_tcp_conn_release(PancakeTcpConn *conn);
/* Close the listener and free the handle; do not use `listener` afterward. */
void pancake_tcp_listener_release(PancakeTcpListener *listener);
/* Copy the calling thread's last TCP-transport error into out_buf, the tcp
   sibling of pancake_last_error, reading this archive's own per-thread slot. A
   pancake_tcp_* call that returns PANCAKE_ERR_IO records its concrete cause here.
   Copies at most cap-1 bytes and NUL-terminates when cap>0; out_buf NULL or cap 0
   queries the length. Returns the full message length, or 0 when none is set. */
size_t pancake_tcp_last_error(uint8_t *out_buf, size_t cap);
/* Clear the calling thread's TCP-transport last-error slot. */
void pancake_tcp_clear_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* PANCAKE_NET_TRANSPORT_TCP_H */
