/* Generated from src/c_abi/net_transport/tcp/mod.zig by tools/header_gen_net_tcp.zig.
   Do not edit by hand: run `zig build gen-header-net-transport-tcp`.
   Function signatures are reflected from the Zig source, so this header
   cannot drift from the implementation.

   The TCP transport's public C ABI: a separate archive
   (libpancake_net_transport_tcp) from libpancake_ocapn (ADR-0059). It is
   a companion, not a superset: it exports only the pancake_tcp_* family
   and shares no core symbol with libpancake_ocapn, so a consumer links
   BOTH archives and includes BOTH headers. The shared frame, peer, and
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
/* Orientation: the host-driven netlayer boundary for C, over blocking,
   cleartext TCP. The host owns the peer and shuttles whole frames: read a
   frame (pancake_tcp_conn_read_frame), feed it to a PancakePeer from
   pancake_ocapn.h, step, and write the peer's outbound frames back
   (pancake_tcp_conn_write_frame). The netlayer owns the I/O backend; create
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
/* An owning OCapN session over one blocking TCP connection: the C
   spelling of the native-Zig Connection (ADR-0062). Created by
   pancake_tcp_session_connect, which dials and runs the keyed
   handshake; released by pancake_tcp_session_release. */
typedef struct PancakeTcpSession PancakeTcpSession;
/* An outstanding eventual-send's answer: the questioner half of promise
   pipelining (ADR-0007). Returned by pancake_tcp_session_send and
   pancake_tcp_session_send_pipelined; pipeline against it, await it with
   pancake_tcp_session_settle, and release it with
   pancake_tcp_promise_release. */
typedef struct PancakeTcpPromise PancakeTcpPromise;

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
/* Owning session (ADR-0062): the higher-level twin of the host-driven frame
   surface above. Where pancake_tcp_conn_* hands you whole frames to shuttle
   through a PancakePeer by hand, a PancakeTcpSession owns the peer, both
   buffers, and the bound vat, and offers the same blocking fetch/call the
   native-Zig Connection does, marshalling pancake_ocapn.h's shared
   PancakeReference/PancakeArgument vocabulary into the PancakeSettled
   outcome declared below. This is the TCP archive's own entry, not a driver
   default; the inproc and iroh archives can grow the same shape. */

typedef struct PancakeSettled {
    /* PANCAKE_RESOLUTION_FULFILL selects `fulfill`, _BREAK selects `break_message` */
    uint32_t resolution_kind;
    /* the fulfilled value; live only when resolution_kind is _FULFILL */
    PancakeArgument fulfill;
    /* the break reason bytes; live only when resolution_kind is _BREAK */
    const uint8_t *break_message;
    size_t break_message_len;
    /* owning arena the views alias; freed by pancake_tcp_settled_release. Only the owning session mints a PancakeSettled, so it is declared here, not in pancake_ocapn.h */
    void *owner;
} PancakeSettled;

/* Dial host:port, run the ephemeral keyed handshake, and return an owning
   session framing on `codec` and refusing inbound frames over max_frame_bytes,
   the C twin of driver.connect(&.{tcp}, ., .ephemeral, .). Blocking; `host`
   is borrowed. PANCAKE_ERR_INVALID_ARGUMENT for a bad codec, a zero frame cap,
   or an unparseable address; PANCAKE_ERR_IO (see pancake_tcp_last_error) when
   the dial fails. Release with pancake_tcp_session_release. */
int32_t pancake_tcp_session_connect(PancakeTcpNetlayer *netlayer, const uint8_t *host, size_t host_len, uint16_t port, uint32_t codec, size_t max_frame_bytes, PancakeTcpSession **out_session);
/* Fetch the partner's published capability `name`, writing the resolved far
   object reference into out_reference. Blocking. PANCAKE_ERR_BROKEN when the
   partner answers with a break (pancake_tcp_last_error names it),
   PANCAKE_ERR_UNSUPPORTED_VALUE when it fulfils with a non-capability,
   PANCAKE_ERR_CLOSED when the partner left. `name` is borrowed. */
int32_t pancake_tcp_session_fetch(PancakeTcpSession *session, const uint8_t *name, size_t name_len, PancakeReference *out_reference);
/* Send verb/args to `target` and block until the reply settles, projecting the
   outcome into out_settled (release with pancake_tcp_settled_release). `target`
   comes from a prior fetch or a received argument; only a near/far object
   reference is callable (else PANCAKE_ERR_INVALID_ARGUMENT). target, verb, and
   args are borrowed. PANCAKE_ERR_CLOSED if the partner left before settling. */
int32_t pancake_tcp_session_call(PancakeTcpSession *session, const PancakeReference *target, const uint8_t *verb, size_t verb_len, const PancakeArgument *args, size_t args_len, PancakeSettled *out_settled);
/* Promise pipelining (ADR-0007), the questioner's half: send without blocking
   and pipeline dependent calls against an answer before it resolves. Where
   pancake_tcp_session_call is one blocking round trip, a batch of
   pancake_tcp_session_send + pancake_tcp_session_send_pipelined queues a
   dependency chain that the first pancake_tcp_session_settle flushes and
   drives as a single round trip. Each call returns a PancakeTcpPromise the
   caller owns and releases exactly once with pancake_tcp_promise_release,
   whether or not it was settled. */

/* Eventual-send verb/args to `target` without blocking, returning the answer in
   out_promise (release with pancake_tcp_promise_release). The non-blocking,
   pipelinable twin of pancake_tcp_session_call: the call is queued, not flushed,
   so a chain of sends leaves together on the next settle. `target` must be a
   near/far object reference (else PANCAKE_ERR_INVALID_ARGUMENT). target, verb,
   and args are borrowed; the send deep-copies what it queues. */
int32_t pancake_tcp_session_send(PancakeTcpSession *session, const PancakeReference *target, const uint8_t *verb, size_t verb_len, const PancakeArgument *args, size_t args_len, PancakeTcpPromise **out_promise);
/* Pipeline verb/args against the answer `promise` — an eventual-send to the
   object that answer will resolve to, sent now without waiting for it. Returns
   the dependent call's own answer in out_promise. Queued, not flushed, like
   pancake_tcp_session_send. `promise` stays valid and must still be released;
   verb and args are borrowed. */
int32_t pancake_tcp_session_send_pipelined(PancakeTcpSession *session, PancakeTcpPromise *promise, const uint8_t *verb, size_t verb_len, const PancakeArgument *args, size_t args_len, PancakeTcpPromise **out_promise);
/* Drive the session until `promise` settles, projecting the outcome into
   out_settled (release with pancake_tcp_settled_release). The first settle
   flushes every queued send/send_pipelined, so a pipelined batch travels as one
   round trip. Settle a given promise once; the handle is still owned and must be
   released with pancake_tcp_promise_release. */
int32_t pancake_tcp_session_settle(PancakeTcpSession *session, PancakeTcpPromise *promise, PancakeSettled *out_settled);
/* Release a settled projection from pancake_tcp_session_call or
   pancake_tcp_session_settle; the fulfill value and break_message views aliasing
   its arena die with it. Idempotent: the struct is cleared, so releasing again
   (or a zero-initialized struct) is a no-op. */
void pancake_tcp_settled_release(PancakeSettled *settled);
/* Release an answer handle from pancake_tcp_session_send or
   pancake_tcp_session_send_pipelined. The boxed promise dies; a settled
   projection it produced (a PancakeSettled) is independent and freed separately. */
void pancake_tcp_promise_release(PancakeTcpPromise *promise);
/* Tear down the session: close the connection (freeing the owned peer and
   buffers) and free the handle. Do not use `session` afterward. */
void pancake_tcp_session_release(PancakeTcpSession *session);
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
