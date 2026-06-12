/* Generated from src/c_abi/iroh.zig by tools/header_gen_iroh.zig.
   Do not edit by hand: run `zig build gen-header-iroh`. Function
   signatures are reflected from the Zig source, so this header cannot
   drift from the implementation.

   The iroh transport's public C ABI: a separate artifact
   (libpancake_iroh) from libpancake, because it links the Rust iroh
   sidecar (ADR-0055). The artifact is a superset — it carries the
   whole libpancake surface too — so a consumer loads one library and
   includes both this header and pancake.h. The shared frame, peer, and
   context vocabulary lives in pancake.h; only the two iroh handles and
   the pancake_iroh_* prototypes are declared here.

   This is NOT transports/iroh/include/pancake_iroh_sidecar.h, which is
   the sidecar's internal byte-level seam (pancake_iroh_sidecar_connect,
   pancake_iroh_sidecar_conn_read, ...). This is the frame-level public
   surface (pancake_iroh_netlayer_*, pancake_iroh_conn_read_frame, ...). */
#ifndef PANCAKE_IROH_H
#define PANCAKE_IROH_H

#include <stddef.h>
#include <stdint.h>
#include "pancake.h"

#ifdef __cplusplus
extern "C" {
#endif
/* Orientation: the iroh transport is the host-driven netlayer boundary's
   encrypted-QUIC sibling of the blocking TCP endpoints in pancake.h. The
   host owns the peer: dial or accept a connection, then loop reading a
   whole frame (pancake_iroh_conn_read_frame), feeding it to a PancakePeer,
   stepping, and writing the peer's outbound frames back
   (pancake_iroh_conn_write_frame).

   The one difference from TCP is addressing: there is no host:port. A
   partner is dialed by its endpoint id — the canonical lowercase-hex
   designator pancake_iroh_netlayer_node_id prints. Whether you also need a
   direct-address hint string from pancake_iroh_netlayer_direct_addrs
   depends on the reachability the netlayer was created with: a
   PANCAKE_IROH_REACH_DIRECT endpoint dials by id plus hints, while a
   discovery endpoint resolves the partner by id alone. Carry both in the
   OCapN locator a peer signs (transport "iroh", the id as designator, the
   hints under "direct-addresses").

   Lifetime: release every connection before the netlayer that minted it.
   Threading: a connection is single-owner like a peer; serialize calls on
   one onto one thread. Every call blocks the calling thread (the endpoint
   runs its own runtime), so run accept loops and per-connection pumps on
   your own threads (or a binding's non-blocking FFI). */

/* An iroh netlayer: one bound QUIC endpoint plus the sidecar runtime
   driving it. Created by pancake_iroh_netlayer_new; released by
   pancake_iroh_netlayer_release after every connection is released. */
typedef struct PancakeIrohNetlayer PancakeIrohNetlayer;
/* One QUIC connection carrying one OCapN session, framed on the
   netlayer's codec. Created by pancake_iroh_netlayer_connect or
   _accept; released by pancake_iroh_conn_release. */
typedef struct PancakeIrohConn PancakeIrohConn;

/* Reachability postures for pancake_iroh_netlayer_new. The caller always
   passes one — there is no default. A pancake peer never turns on relays
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

/* Create an iroh netlayer (one bound endpoint) allocating through the library
   allocator. secret_seed/secret_seed_len is either a 32-byte Ed25519 secret key
   (borrowed) or empty (secret_seed_len == 0) for a fresh random key; any other
   length is PANCAKE_ERR_INVALID_ARGUMENT. reachability is one of
   PANCAKE_IROH_REACH_* and is mandatory — it decides whether the endpoint uses
   relays or a discovery service, with no default; an unknown value is
   PANCAKE_ERR_INVALID_ARGUMENT. PANCAKE_ERR_IO (see pancake_last_error) if the
   endpoint cannot bind. Release with pancake_iroh_netlayer_release after
   releasing every connection made from it. */
int32_t pancake_iroh_netlayer_new(const uint8_t *secret_seed, size_t secret_seed_len, uint32_t reachability, PancakeIrohNetlayer **out_netlayer);
/* As pancake_iroh_netlayer_new, allocating the netlayer, endpoint, and every
   per-connection buffer through context. */
int32_t pancake_iroh_netlayer_new_in(PancakeContext *context, const uint8_t *secret_seed, size_t secret_seed_len, uint32_t reachability, PancakeIrohNetlayer **out_netlayer);
/* Close the endpoint without releasing the handle: a blocked
   pancake_iroh_netlayer_accept returns PANCAKE_ERR_IO and later dials fail.
   Idempotent. The shutdown lever for a host whose accept loop parks on another
   thread. */
void pancake_iroh_netlayer_close(PancakeIrohNetlayer *netlayer);
/* Release the netlayer, its endpoint, and the runtime. Every connection made
   from it must already be released. NULL is a no-op. */
void pancake_iroh_netlayer_release(PancakeIrohNetlayer *netlayer);
/* Write this endpoint's id — its Ed25519 public key, the dialable designator —
   into out as lowercase hex, and the byte count into out_len. cap must be at
   least the id length (64) or the call is PANCAKE_ERR_INVALID_ARGUMENT. No
   terminator is written. */
int32_t pancake_iroh_netlayer_node_id(PancakeIrohNetlayer *netlayer, uint8_t *out, size_t cap, size_t *out_len);
/* Write this endpoint's comma-separated direct socket addresses into out (the
   hint string a partner passes to pancake_iroh_netlayer_connect) and the byte
   count into out_len. A buffer too small is PANCAKE_ERR_INVALID_ARGUMENT; an
   endpoint with no direct addresses writes zero bytes and returns PANCAKE_OK. No
   terminator is written. */
int32_t pancake_iroh_netlayer_direct_addrs(PancakeIrohNetlayer *netlayer, uint8_t *out, size_t cap, size_t *out_len);
/* Dial a partner by endpoint id and return an owned connection framing on codec,
   refusing inbound frames over max_frame_bytes. node_id is the partner's
   canonical id; addr_hints is its comma-separated direct-address list (it may be
   empty when the netlayer has a discovery posture, which resolves the partner by
   id; a DIRECT netlayer needs it); both are borrowed for the
   call. Blocking. PANCAKE_ERR_INVALID_ARGUMENT for a bad codec, a zero frame
   cap, or a malformed id/hint; PANCAKE_ERR_IO (see pancake_last_error) when the
   dial fails. Release with pancake_iroh_conn_release. */
int32_t pancake_iroh_netlayer_connect(PancakeIrohNetlayer *netlayer, const uint8_t *node_id, size_t node_id_len, const uint8_t *addr_hints, size_t addr_hints_len, uint32_t codec, size_t max_frame_bytes, PancakeIrohConn **out_conn);
/* Block until a partner dials this endpoint, returning an owned connection
   framing on codec. Same argument and release contract as
   pancake_iroh_netlayer_connect. PANCAKE_ERR_IO when the endpoint is closed (the
   shutdown lever) or the accept faults. */
int32_t pancake_iroh_netlayer_accept(PancakeIrohNetlayer *netlayer, uint32_t codec, size_t max_frame_bytes, PancakeIrohConn **out_conn);
/* Block for one whole frame as an owned managed frame (release it, or hand it to
   pancake_peer_feed_owned). PANCAKE_ERR_CLOSED on graceful end of stream,
   PANCAKE_ERR_IO on a QUIC fault, PANCAKE_ERR_MALFORMED / PANCAKE_ERR_FRAME_TOO_LARGE
   for a bad frame. */
int32_t pancake_iroh_conn_read_frame(PancakeIrohConn *conn, PancakeManagedFrame *out_frame);
/* Write one frame's borrowed bytes and flush. PANCAKE_ERR_IO on a QUIC fault. */
int32_t pancake_iroh_conn_write_frame(PancakeIrohConn *conn, const PancakeFrame *frame);
/* Close the connection and free the handle; do not use conn afterward. */
void pancake_iroh_conn_release(PancakeIrohConn *conn);

#ifdef __cplusplus
}
#endif

#endif /* PANCAKE_IROH_H */
