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
   pancake_tcp_* prototypes are declared here. The TCP archive has its own
   last-error slot, read through pancake_tcp_last_error rather than
   pancake_ocapn's pancake_last_error. */
#ifndef PANCAKE_NET_TRANSPORT_TCP_H
#define PANCAKE_NET_TRANSPORT_TCP_H

#include <stddef.h>
#include <stdint.h>
#include "pancake_ocapn.h"
#include "pancake_transport_provider.h"

#ifdef __cplusplus
extern "C" {
#endif
/* Orientation: the low-level endpoint API is blocking, cleartext TCP for
   a byte-fed PancakeHost. The same archive also owns the complete native
   TCP provider package: tcp, keyed-tcp, and noise-tcp. Read a frame with
   pancake_tcp_conn_read_frame, feed its bytes to the Host, and
   write Host output with pancake_tcp_conn_write_frame. The netlayer owns
   the I/O backend; create
   it, make connections/listeners from it, then release it after every
   endpoint made from it is released. There is no TLS. */

/* A TCP netlayer: the one owned I/O backend the endpoints run on.
   Created by pancake_tcp_netlayer_new; released by
   pancake_tcp_netlayer_release after every endpoint is released. */
typedef struct PancakeTcpNetlayer PancakeTcpNetlayer;
/* One blocking TCP connection carrying one OCapN session, framed on the
   netlayer's codec. One read and one write may run concurrently; calls in
   the same direction are serialized by the archive. Created by
   pancake_tcp_connect or pancake_tcp_accept; released by
   pancake_tcp_conn_release. */
typedef struct PancakeTcpConn PancakeTcpConn;
/* A bound TCP listener. Created by pancake_tcp_listen; released by
   pancake_tcp_listener_release. */
typedef struct PancakeTcpListener PancakeTcpListener;
/* Per-stream TCP policy. A zeroed value disables keepalive. Otherwise
   every field is required and positive. */
typedef struct PancakeTcpStreamOptions {
  uint32_t keepalive_idle_sec;
  uint32_t keepalive_interval_sec;
  uint32_t keepalive_count;
} PancakeTcpStreamOptions;
/* Defaults inherited by connections from this netlayer. */
typedef struct PancakeTcpConfig {
  PancakeTcpStreamOptions stream;
} PancakeTcpConfig;
/* Per-operation override carried through PancakeTransportOperationOptions. */
typedef struct PancakeTcpOperationOptions {
  PancakeTcpStreamOptions stream;
} PancakeTcpOperationOptions;
/* Return the exact callable-surface fingerprint of this archive. A dynamic loader must compare it with the binding-generated PANCAKE_TCP_ARCHIVE_FINGERPRINT before calling any other pancake_tcp_* function. */
uint64_t pancake_tcp_archive_fingerprint(void);
/* Create the netlayer handle that owns the blocking I/O backend, allocating
   through the library allocator. `config` is required and supplies inherited
   stream defaults. Release with pancake_tcp_netlayer_release after releasing
   every endpoint made from it. */
int32_t pancake_tcp_netlayer_new(const PancakeTcpConfig *config, PancakeTcpNetlayer **out_netlayer);
/* Create a netlayer whose backend and per-connection buffers allocate through
   `context`, with the same required configuration. */
int32_t pancake_tcp_netlayer_new_in(PancakeContext *context, const PancakeTcpConfig *config, PancakeTcpNetlayer **out_netlayer);
/* Fill out_provider with this runtime's complete TCP package: tcp, keyed-tcp,
   and noise-tcp. Install it once with pancake_driver_add_provider. The driver
   acquires the provider lease through retain and releases it after all transport
   use retires; release the TCP runtime only after the driver is released. */
int32_t pancake_tcp_transport_provider(PancakeTcpNetlayer *netlayer, PancakeTransportProvider *out_provider);
/* Seal connect admission and request cancellation of a connect already in
   progress, without freeing netlayer. Call this before joining a foreign thread
   inside pancake_tcp_connect. Idempotent. */
void pancake_tcp_netlayer_shutdown(PancakeTcpNetlayer *netlayer);
/* Release the netlayer and its I/O backend after every connection and listener
   made from it is released. First stop new calls, invoke shutdown, and join the
   embedding's operation leases; release must not race call initiation. */
void pancake_tcp_netlayer_release(PancakeTcpNetlayer *netlayer);
/* Connect to host:port and return an owned connection framing on `codec`,
   refusing inbound frames over max_frame_bytes. `options == NULL` inherits the
   netlayer's stream defaults; a nonnull zeroed value disables keepalive for this
   connection. Blocking; `host` is borrowed. PANCAKE_ERR_INVALID_ARGUMENT for a
   bad option, codec, frame cap, or address; PANCAKE_ERR_IO when the dial fails.
   Release with pancake_tcp_conn_release.

   out_error/out_error_len optionally capture this call's diagnostic before an
   off-thread runtime regains control: omit all three diagnostic arguments, or
   provide out_error_len. It receives the full length; out_error receives at most
   error_cap - 1 bytes and is NUL-terminated when error_cap is nonzero. */
int32_t pancake_tcp_connect(PancakeTcpNetlayer *netlayer, const uint8_t *host, size_t host_len, uint16_t port, const PancakeTcpStreamOptions *options, uint32_t codec, size_t max_frame_bytes, PancakeTcpConn **out_conn, uint8_t *out_error, size_t error_cap, size_t *out_error_len);
/* Bind and listen on host:port (port 0 picks an OS-chosen port; read it back
   with pancake_tcp_listener_port). Release with pancake_tcp_listener_release. */
int32_t pancake_tcp_listen(PancakeTcpNetlayer *netlayer, const uint8_t *host, size_t host_len, uint16_t port, PancakeTcpListener **out_listener);
/* The OS-resolved local port of a listener (useful after binding to port 0). */
int32_t pancake_tcp_listener_port(PancakeTcpListener *listener, uint16_t *out_port);
/* Return the borrowed listening descriptor. Park an external reactor on it and
   call pancake_tcp_accept after it is readable. Readiness is advisory: serialize
   accept consumers when the reactor must not park. The listener owns the fd; do
   not close it or use it after pancake_tcp_listener_release. */
int32_t pancake_tcp_listener_readiness_fd(PancakeTcpListener *listener, int32_t *out_fd);
/* Block until a client connects, returning an owned connection framing on
   `codec`. `options` has the same inherit-or-override contract as
   pancake_tcp_connect.

   out_error/out_error_len optionally capture this call's diagnostic before an
   off-thread runtime regains control: omit all three diagnostic arguments, or
   provide out_error_len. It receives the full length; out_error receives at most
   error_cap - 1 bytes and is NUL-terminated when error_cap is nonzero. */
int32_t pancake_tcp_accept(PancakeTcpListener *listener, const PancakeTcpStreamOptions *options, uint32_t codec, size_t max_frame_bytes, PancakeTcpConn **out_conn, uint8_t *out_error, size_t error_cap, size_t *out_error_len);
/* Block for one whole frame as an owned managed frame. Returns PANCAKE_ERR_CLOSED
   on graceful EOF, PANCAKE_ERR_IO on a socket fault.

   out_error/out_error_len optionally capture this call's diagnostic before an
   off-thread runtime regains control: omit all three diagnostic arguments, or
   provide out_error_len. It receives the full length; out_error receives at most
   error_cap - 1 bytes and is NUL-terminated when error_cap is nonzero. */
int32_t pancake_tcp_conn_read_frame(PancakeTcpConn *conn, PancakeManagedFrame *out_frame, uint8_t *out_error, size_t error_cap, size_t *out_error_len);
/* Write one frame's borrowed bytes and flush. Returns PANCAKE_ERR_CLOSED after
   shutdown begins.

   out_error/out_error_len optionally capture this call's diagnostic before an
   off-thread runtime regains control: omit all three diagnostic arguments, or
   provide out_error_len. It receives the full length; out_error receives at most
   error_cap - 1 bytes and is NUL-terminated when error_cap is nonzero. */
int32_t pancake_tcp_conn_write_frame(PancakeTcpConn *conn, const PancakeFrame *frame, uint8_t *out_error, size_t error_cap, size_t *out_error_len);
/* Seal native admission and interrupt blocked reads and writes without freeing
   the connection. May race operations; join the embedding's leases before release.
   Idempotent. Returns PANCAKE_ERR_IO when the socket cannot be interrupted; the
   transport last-error slot names the cause. */
int32_t pancake_tcp_conn_shutdown(PancakeTcpConn *conn);
/* After stopping new calls, invoke shutdown, join admitted operations, and free
   the handle. Returns the shutdown outcome after completing the ownership sweep.
   Release must not race call initiation.

   out_error/out_error_len optionally capture this call's diagnostic before an
   off-thread runtime regains control: omit all three diagnostic arguments, or
   provide out_error_len. It receives the full length; out_error receives at most
   error_cap - 1 bytes and is NUL-terminated when error_cap is nonzero. */
int32_t pancake_tcp_conn_release(PancakeTcpConn *conn, uint8_t *out_error, size_t error_cap, size_t *out_error_len);
/* Seal native accept admission and interrupt a blocked accept without freeing the
   listener. May race operations; join the embedding's leases before release.
   Idempotent; the listener's pre-opened wake channel makes this operation infallible. */
void pancake_tcp_listener_shutdown(PancakeTcpListener *listener);
/* After stopping new calls, invoking shutdown, and joining the embedding's
   operation leases, close and free the listener. Release must not race call initiation. */
void pancake_tcp_listener_release(PancakeTcpListener *listener);
/* Copy the calling thread's last TCP-transport error into out_buf, the tcp
   sibling of pancake_last_error, reading this archive's own per-thread slot. A
   pancake_tcp_* call that returns PANCAKE_ERR_IO records its concrete cause here.
   Copies at most cap-1 bytes and NUL-terminates when cap>0; out_buf NULL or cap 0
   queries the length. Returns the full message length, or 0 when none is set. Every status-returning call clears the slot before validation; read it immediately after a failing call, and treat zero length as no additional detail. */
size_t pancake_tcp_last_error(uint8_t *out_buf, size_t cap);
/* Clear the calling thread's TCP-transport last-error slot. */
void pancake_tcp_clear_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* PANCAKE_NET_TRANSPORT_TCP_H */
