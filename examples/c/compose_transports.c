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
    /* Single-exit cleanup: every failure branch jumps to one teardown that
       releases whatever was actually acquired. The alternative — re-typing a
       longer release ladder in each branch — is where C leaks come from. */
    int rc = 1;
    PancakeContext *ctx = NULL;
    PancakePeer *peer = NULL;
    PancakeTcpNetlayer *tcp = NULL;
    PancakeInprocNetlayer *inproc = NULL;
    PancakeInprocListener *listener = NULL;
    char err[256];

    if (pancake_context_new(&ctx) != PANCAKE_OK) {
        fprintf(stderr, "compose: pancake_context_new failed\n");
        goto out;
    }
    if (pancake_peer_new_in(ctx, &peer) != PANCAKE_OK) {
        fprintf(stderr, "compose: pancake_peer_new_in failed\n");
        goto out;
    }

    /* Each transport archive carries its own last-error slot, so the diagnostic
       is read through the family whose call failed. */
    if (pancake_tcp_netlayer_new_in(ctx, &tcp) != PANCAKE_OK) {
        size_t n = pancake_tcp_last_error(err, sizeof err);
        fprintf(stderr, "compose: pancake_tcp_netlayer_new_in failed: %.*s\n", (int)n, err);
        goto out;
    }
    if (pancake_inproc_netlayer_new_in(ctx, &inproc) != PANCAKE_OK) {
        size_t n = pancake_inproc_last_error(err, sizeof err);
        fprintf(stderr, "compose: pancake_inproc_netlayer_new_in failed: %.*s\n", (int)n, err);
        goto out;
    }

    const char designator[] = "compose-proof";
    if (pancake_inproc_listen(inproc, (const uint8_t *)designator,
                              sizeof designator - 1, &listener) != PANCAKE_OK) {
        size_t n = pancake_inproc_last_error(err, sizeof err);
        fprintf(stderr, "compose: pancake_inproc_listen failed: %.*s\n", (int)n, err);
        goto out;
    }

    printf("compose: ocapn + tcp + inproc archives composed and resolved\n");
    rc = 0;

out:
    if (listener) pancake_inproc_listener_release(listener);
    if (inproc) pancake_inproc_netlayer_release(inproc);
    if (tcp) pancake_tcp_netlayer_release(tcp);
    if (peer) pancake_peer_release(peer);
    if (ctx) pancake_context_release(ctx);
    return rc;
}
