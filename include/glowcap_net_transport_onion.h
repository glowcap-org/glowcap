/* Generated from src/c_abi/net_transport/onion/mod.zig by tools/gen/header/net_onion.zig.
   Do not edit by hand: run `zig build gen-header-net-transport-onion`.
   Function signatures are reflected from the Zig source, so this header
   cannot drift from the implementation.

   The onion transport's public C ABI: a separate archive
   (libglowcap_net_transport_onion) from libglowcap_ocapn (ADR-0059). It is
   a companion, not a superset: it exports only the glowcap_onion_* family
   and shares no core symbol with libglowcap_ocapn, so a consumer links
   BOTH archives and includes BOTH headers. The shared frame, peer, and
   context vocabulary lives in glowcap_ocapn.h (included below) and the
   archives agree on its layout; only the onion handles, the configuration
   struct, and the glowcap_onion_* prototypes are declared here. The onion
   family has its own last-error slot, read through
   glowcap_onion_last_error rather than glowcap_ocapn's
   glowcap_last_error. */
#ifndef GLOWCAP_NET_TRANSPORT_ONION_H
#define GLOWCAP_NET_TRANSPORT_ONION_H

#include <stddef.h>
#include <stdint.h>
#include "glowcap_ocapn.h"
#include "glowcap_transport_provider.h"

#ifdef __cplusplus
extern "C" {
#endif
/* Orientation: onion is the one netlayer the OCapN draft standardizes, and the
   one upstream Spritely Goblins ships, so it is where a glowcap peer and a
   Goblins vat meet on ground neither invented. A locator is
   ocapn://<serviceid>.onion, and the designator this API takes is that bare
   service id: 56 base32 characters with no .onion suffix.

   glowcap starts no Tor. It talks to a daemon the deployment already runs,
   over that daemon's SOCKS endpoint to dial and its control endpoint to host,
   and it never spawns, supervises, or configures one. A netlayer built against
   endpoints nothing is listening on fails at glowcap_onion_netlayer_new's
   first use rather than at some later dial.

   Two limits are worth reading before you rely on this. The service id is an
   ADDRESS, not an identity: Tor proves the far end of the circuit holds the key
   the address encodes, but the CapTP peer is whoever holds the local endpoint
   that service forwards to, so nothing here reports a proved peer. And an
   accepted circuit carries no client identity at all, because Tor tells a
   hidden service nothing about who dialed it, so a partner's claimed location
   on this side is unverified. ADR-0108 derives both.

   Otherwise the shape is the TCP transport's (glowcap_net_transport_tcp.h):
   the host owns the peer, and this family shuttles whole frames. Every call
   that reaches Tor blocks, and a circuit takes seconds rather than
   milliseconds, so size your timeouts for Tor and not for a socket. */

/* An onion netlayer: where Tor listens, how to authenticate to it, and the
   one owned I/O backend its streams block on. Created by
   glowcap_onion_netlayer_new; released by glowcap_onion_netlayer_release
   after every endpoint is released. */
typedef struct GlowcapOnionNetlayer GlowcapOnionNetlayer;
/* One onion connection carrying one OCapN session, framed on the codec its
   constructor named. One read and one write may run concurrently; calls
   in the same direction are serialized by the archive. Created by
   glowcap_onion_connect or glowcap_onion_accept; released by
   glowcap_onion_conn_release. */
typedef struct GlowcapOnionConn GlowcapOnionConn;
/* A live onion service: the control session keeping it published plus the
   local endpoint Tor forwards it to. Created by glowcap_onion_listen;
   released by glowcap_onion_listener_release, which also withdraws the
   service. */
typedef struct GlowcapOnionListener GlowcapOnionListener;

/* How the control endpoint expects to be authenticated. These are the three
   forms a real torrc produces. NONE is what an unauthenticated Unix control
   socket gives, and what upstream Goblins assumes. COOKIE sends the bytes of
   the file CookieAuthFile names, as hexadecimal, and is the common default
   on a distribution's Tor package. PASSWORD sends the cleartext of a
   HashedControlPassword setup. */
#define GLOWCAP_ONION_AUTH_NONE 0u
#define GLOWCAP_ONION_AUTH_COOKIE 1u
#define GLOWCAP_ONION_AUTH_PASSWORD 2u

/* A version 3 onion service id is always exactly this many characters, so a
   caller can size a fixed buffer for glowcap_onion_listen's out-parameter.
   The key cap bounds Tor's ED25519-V3: private-key form with room to
   spare. */
#define GLOWCAP_ONION_SERVICE_ID_LEN 56u
#define GLOWCAP_ONION_SERVICE_KEY_CAP 256u

/* Everything the netlayer needs to reach Tor, and what to ask for when
   hosting. Zero-initialize the whole struct and set the fields you use, so a
   field added later reads as zero rather than as stack contents. Every
   pointer is borrowed for the duration of the constructor call and copied
   into the handle, so you may free your own strings afterwards.

   Each endpoint is either an absolute Unix socket path (starting with '/')
   or a host:port. A relative path is refused rather than guessed at.

   socks is required: a netlayer that cannot dial is not a netlayer.
   control_endpoint empty means dial-only, and glowcap_onion_listen then
   fails rather than pretending to host. auth_secret carries the cookie
   file's bytes or the password's text per auth_kind, and is unread for
   GLOWCAP_ONION_AUTH_NONE. service_key empty asks Tor for a fresh service;
   otherwise pass back the exact bytes an earlier glowcap_onion_listen
   reported. That is how the same onion address comes back across a
   restart. forward empty binds a loopback port and reports it to Tor. */
typedef struct GlowcapOnionConfig {
  const uint8_t *socks;
  size_t socks_len;
  const uint8_t *control_endpoint;
  size_t control_endpoint_len;
  uint32_t auth_kind;
  const uint8_t *auth_secret;
  size_t auth_secret_len;
  const uint8_t *service_key;
  size_t service_key_len;
  const uint8_t *forward;
  size_t forward_len;
} GlowcapOnionConfig;

/* Return the exact callable-surface fingerprint. Compare it with the binding-generated GLOWCAP_ONION_ARCHIVE_FINGERPRINT before any other call. */
uint64_t glowcap_onion_archive_fingerprint(void);
/* Create the onion netlayer handle from `config`, allocating through the library
   allocator. The configuration text is copied in, so your strings need not
   outlive this call. GLOWCAP_ERR_INVALID_ARGUMENT for a missing socks endpoint or
   an unknown auth_kind. Release with glowcap_onion_netlayer_release after
   releasing every endpoint made from it. */
int32_t glowcap_onion_netlayer_new(const GlowcapOnionConfig *config, GlowcapOnionNetlayer **out_netlayer);
/* Create an onion netlayer whose configuration copy, backend, and per-connection
   buffers allocate through `context`. */
int32_t glowcap_onion_netlayer_new_in(GlowcapContext *context, const GlowcapOnionConfig *config, GlowcapOnionNetlayer **out_netlayer);
/* Fill out_provider with this runtime's complete onion package. Install it once
   with glowcap_driver_add_provider. The driver acquires the provider lease through
   retain and releases it after all transport use retires; release the onion
   runtime only after the driver is released. */
int32_t glowcap_onion_transport_provider(GlowcapOnionNetlayer *netlayer, GlowcapTransportProvider *out_provider);
/* Seal connect/listen admission and request cancellation of calls already reaching
   Tor, without freeing netlayer. Call this before joining foreign threads that may
   be inside glowcap_onion_connect or glowcap_onion_listen. Idempotent. */
void glowcap_onion_netlayer_shutdown(GlowcapOnionNetlayer *netlayer);
/* Release the onion netlayer after every connection and listener made from it is
   released. First stop new calls, invoke shutdown, and join the embedding's
   operation leases; release must not race call initiation.

   out_error/out_error_len optionally capture this call's diagnostic before an
   off-thread runtime regains control: omit all three diagnostic arguments, or
   provide out_error_len. It receives the full length; out_error receives at most
   error_cap - 1 bytes and is NUL-terminated when error_cap is nonzero. */
int32_t glowcap_onion_netlayer_release(GlowcapOnionNetlayer *netlayer, uint8_t *out_error, size_t error_cap, size_t *out_error_len);
/* Dial the onion service `service_id` through the configured Tor and return an
   owned connection framing on `codec`, refusing inbound frames over
   max_frame_bytes. `service_id` is the bare 56-character designator, borrowed.
   GLOWCAP_ERR_INVALID_ARGUMENT for a designator that is not a well-formed version
   3 address, which is refused before any socket opens, and for a bad codec or a
   zero frame cap. GLOWCAP_ERR_IO when Tor is not reachable or could not reach the
   service. Blocking: a circuit takes seconds. Release with
   glowcap_onion_conn_release.

   out_error/out_error_len optionally capture this call's diagnostic before an
   off-thread runtime regains control: omit all three diagnostic arguments, or
   provide out_error_len. It receives the full length; out_error receives at most
   error_cap - 1 bytes and is NUL-terminated when error_cap is nonzero. */
int32_t glowcap_onion_connect(GlowcapOnionNetlayer *netlayer, const uint8_t *service_id, size_t service_id_len, uint32_t codec, size_t max_frame_bytes, GlowcapOnionConn **out_conn, uint8_t *out_error, size_t error_cap, size_t *out_error_len);
/* Ask Tor for an onion service and bind its local end. out_service_id receives
   the designator with no NUL terminator, always GLOWCAP_ONION_SERVICE_ID_LEN
   bytes. out_service_key receives the key that restores this exact service, or
   nothing when the service was restored rather than minted; store those bytes and
   pass them back as GlowcapOnionConfig.service_key for a durable onion address.
   The service output pairs are optional; a NULL buffer with a non-NULL length
   queries the length. Requires a configured control endpoint:
   GLOWCAP_ERR_INVALID_ARGUMENT without one. Blocking. Release with
   glowcap_onion_listener_release, which also withdraws the service.

   out_error/out_error_len optionally capture this call's diagnostic before an
   off-thread runtime regains control: omit all three diagnostic arguments, or
   provide out_error_len. It receives the full length; out_error receives at most
   error_cap - 1 bytes and is NUL-terminated when error_cap is nonzero. */
int32_t glowcap_onion_listen(GlowcapOnionNetlayer *netlayer, uint8_t *out_service_id, size_t out_service_id_cap, size_t *out_service_id_len, uint8_t *out_service_key, size_t out_service_key_cap, size_t *out_service_key_len, GlowcapOnionListener **out_listener, uint8_t *out_error, size_t error_cap, size_t *out_error_len);
/* Wait until glowcap_onion_accept would make progress, up to timeout_ms. Writes 1
   into out_ready when the next accept should proceed and 0 on timeout.
   This is what lets a blocking accept loop check a stop flag without closing the
   listener from another thread.

   out_error/out_error_len optionally capture this call's diagnostic before an
   off-thread runtime regains control: omit all three diagnostic arguments, or
   provide out_error_len. It receives the full length; out_error receives at most
   error_cap - 1 bytes and is NUL-terminated when error_cap is nonzero. */
int32_t glowcap_onion_listener_wait(GlowcapOnionListener *listener, int32_t timeout_ms, uint32_t *out_ready, uint8_t *out_error, size_t error_cap, size_t *out_error_len);
/* Hand back the descriptor this listener's circuits arrive on, so your loop can
   poll instead of blocking. Park on it with whatever your loop uses and call
   glowcap_onion_accept once it is readable. Readiness means an accept can make
   progress; it is not a nonblocking guarantee, because another accept consumer or
   a close can consume that state first. Serialize accept consumers when a loop must
   not park. An onion service's forward target is an ordinary local socket, which is
   why this is a real descriptor rather than a synthesized readiness fd. Owned by the
   listener: do not close it, and do not use it after glowcap_onion_listener_release. */
int32_t glowcap_onion_listener_readiness_fd(GlowcapOnionListener *listener, int32_t *out_fd);
/* Hand back the descriptor this connection's bytes flow over. Same contract as
   glowcap_onion_listener_readiness_fd: poll it, and read only when it is readable.
   A whole frame may still need more than one readable turn, in which case the read
   parks for the remainder, so this makes the common case free rather than every
   case. Owned by the connection. */
int32_t glowcap_onion_conn_readiness_fd(GlowcapOnionConn *conn, int32_t *out_fd);
/* Block until Tor forwards a circuit to this service, returning an owned
   connection framing on `codec`. Same argument and release contract as
   glowcap_onion_connect. The partner's claimed location is unverified on this
   side: Tor tells a hidden service nothing about who dialed it.

   out_error/out_error_len optionally capture this call's diagnostic before an
   off-thread runtime regains control: omit all three diagnostic arguments, or
   provide out_error_len. It receives the full length; out_error receives at most
   error_cap - 1 bytes and is NUL-terminated when error_cap is nonzero. */
int32_t glowcap_onion_accept(GlowcapOnionListener *listener, uint32_t codec, size_t max_frame_bytes, GlowcapOnionConn **out_conn, uint8_t *out_error, size_t error_cap, size_t *out_error_len);
/* Block for one whole frame as an owned managed frame. Returns
   GLOWCAP_ERR_CLOSED on graceful EOF.

   out_error/out_error_len optionally capture this call's diagnostic before an
   off-thread runtime regains control: omit all three diagnostic arguments, or
   provide out_error_len. It receives the full length; out_error receives at most
   error_cap - 1 bytes and is NUL-terminated when error_cap is nonzero. */
int32_t glowcap_onion_conn_read_frame(GlowcapOnionConn *conn, GlowcapManagedFrame *out_frame, uint8_t *out_error, size_t error_cap, size_t *out_error_len);
/* Write one frame's borrowed bytes to the partner. Returns GLOWCAP_ERR_CLOSED
   after shutdown begins.

   out_error/out_error_len optionally capture this call's diagnostic before an
   off-thread runtime regains control: omit all three diagnostic arguments, or
   provide out_error_len. It receives the full length; out_error receives at most
   error_cap - 1 bytes and is NUL-terminated when error_cap is nonzero. */
int32_t glowcap_onion_conn_write_frame(GlowcapOnionConn *conn, const GlowcapFrame *frame, uint8_t *out_error, size_t error_cap, size_t *out_error_len);
/* Seal native admission and interrupt blocked reads and writes without freeing
   the connection. May race operations; join the embedding's leases before release.
   Idempotent. Returns GLOWCAP_ERR_IO when the socket cannot be interrupted; the
   transport last-error slot names the cause. */
int32_t glowcap_onion_conn_shutdown(GlowcapOnionConn *conn);
/* After stopping new calls, invoke shutdown, join admitted operations, and free
   the handle. Returns the shutdown outcome after completing the ownership sweep.
   Release must not race call initiation.

   out_error/out_error_len optionally capture this call's diagnostic before an
   off-thread runtime regains control: omit all three diagnostic arguments, or
   provide out_error_len. It receives the full length; out_error receives at most
   error_cap - 1 bytes and is NUL-terminated when error_cap is nonzero. */
int32_t glowcap_onion_conn_release(GlowcapOnionConn *conn, uint8_t *out_error, size_t error_cap, size_t *out_error_len);
/* Seal native accept admission and interrupt a blocked accept without freeing the
   listener or withdrawing its service. May race operations; join the embedding's
   leases before release. Idempotent; the listener's pre-opened wake channel makes
   this operation infallible. */
void glowcap_onion_listener_shutdown(GlowcapOnionListener *listener);
/* After stopping new calls, invoking shutdown, and joining the embedding's
   operation leases, withdraw the service and free the listener. Release must not
   race call initiation. This is the one release in the family with an effect a
   partner can observe: the address stops being published.

   out_error/out_error_len optionally capture this call's diagnostic before an
   off-thread runtime regains control: omit all three diagnostic arguments, or
   provide out_error_len. It receives the full length; out_error receives at most
   error_cap - 1 bytes and is NUL-terminated when error_cap is nonzero. */
int32_t glowcap_onion_listener_release(GlowcapOnionListener *listener, uint8_t *out_error, size_t error_cap, size_t *out_error_len);
/* Copy the calling thread's last onion-transport error into out_buf, the onion
   sibling of glowcap_last_error, reading this archive's own per-thread slot. A
   glowcap_onion_* call that returns a cause-bearing code records it here. Copies
   at most cap-1 bytes and NUL-terminates when cap>0; out_buf NULL or cap 0 queries
   the length. Returns the full message length, or 0 when none is set. Every status-returning call clears the slot before validation; read it immediately after a failing call, and treat zero length as no additional detail. */
size_t glowcap_onion_last_error(uint8_t *out_buf, size_t cap);
/* Clear the calling thread's onion-transport last-error slot. */
void glowcap_onion_clear_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* GLOWCAP_NET_TRANSPORT_ONION_H */
