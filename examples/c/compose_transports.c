/* Composition proof for the à-la-carte C ABI archives (ADR-0059). A single C
   program includes all three headers — the sans-io ocapn base plus the TCP and
   in-process transport companions — and links the composed archive set
   (libpancake_ocapn + libpancake_net_transport_tcp +
   libpancake_net_transport_inproc). It builds one of every handle the families
   own — a context, a peer, a TCP netlayer, an in-process netlayer — and tears
   them down. The point is not the conversation (echo_peer.c proves that); it is
   that the three archives compose: their shared frame/context vocabulary agrees
   by header layout, each transport carries its own pancake_<family>_last_error
   slot, and no symbol collides at link time. If this links and runs, embedding
   the lower layers as local symbols inside each archive stays symbol-disjoint
   across the whole set. */

#include "pancake_ocapn.h"
#include "pancake_net_transport_tcp.h"
#include "pancake_net_transport_inproc.h"

#include <stdio.h>

int main(void) {
    PancakeContext *ctx = NULL;
    if (pancake_context_new(&ctx) != PANCAKE_OK) {
        fprintf(stderr, "compose: pancake_context_new failed\n");
        return 1;
    }

    PancakePeer *peer = NULL;
    if (pancake_peer_new_in(ctx, &peer) != PANCAKE_OK) {
        fprintf(stderr, "compose: pancake_peer_new_in failed\n");
        pancake_context_release(ctx);
        return 1;
    }

    PancakeTcpNetlayer *tcp = NULL;
    if (pancake_tcp_netlayer_new_in(ctx, &tcp) != PANCAKE_OK) {
        fprintf(stderr, "compose: pancake_tcp_netlayer_new_in failed: ");
        char buf[256];
        size_t n = pancake_tcp_last_error(buf, sizeof buf);
        fprintf(stderr, "%.*s\n", (int)n, buf);
        pancake_peer_release(peer);
        pancake_context_release(ctx);
        return 1;
    }

    PancakeInprocNetlayer *inproc = NULL;
    if (pancake_inproc_netlayer_new_in(ctx, &inproc) != PANCAKE_OK) {
        fprintf(stderr, "compose: pancake_inproc_netlayer_new_in failed: ");
        char buf[256];
        size_t n = pancake_inproc_last_error(buf, sizeof buf);
        fprintf(stderr, "%.*s\n", (int)n, buf);
        pancake_tcp_netlayer_release(tcp);
        pancake_peer_release(peer);
        pancake_context_release(ctx);
        return 1;
    }

    PancakeInprocListener *listener = NULL;
    const char designator[] = "compose-proof";
    int rc = pancake_inproc_listen(inproc, (const uint8_t *)designator,
                                   sizeof designator - 1, &listener);
    if (rc != PANCAKE_OK) {
        fprintf(stderr, "compose: pancake_inproc_listen failed: ");
        char buf[256];
        size_t n = pancake_inproc_last_error(buf, sizeof buf);
        fprintf(stderr, "%.*s\n", (int)n, buf);
        pancake_inproc_netlayer_release(inproc);
        pancake_tcp_netlayer_release(tcp);
        pancake_peer_release(peer);
        pancake_context_release(ctx);
        return 1;
    }

    pancake_inproc_listener_release(listener);
    pancake_inproc_netlayer_release(inproc);
    pancake_tcp_netlayer_release(tcp);
    pancake_peer_release(peer);
    pancake_context_release(ctx);

    printf("compose: ocapn + tcp + inproc archives composed and resolved\n");
    return 0;
}
