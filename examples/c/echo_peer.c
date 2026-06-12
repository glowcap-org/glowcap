/* An in-process echo conversation between two peers, driven entirely through
   pancake.h. This is the reference shape of a C event loop: pump bytes with
   recv_stream, advance with step, drain with take_outbound, and route events
   by peek_event into the typed polls. No sockets — the two peers exchange
   their frames through plain memory, which is exactly what the sans-I/O
   contract promises a host can do. */

#include "pancake.h"

#include <stdio.h>
#include <string.h>

/* Move every queued outbound frame from one peer into the other. The sender
   owns each frame until release; the receiver consumes the bytes through
   recv_stream, the stream-input primitive a socket loop would also use. */
static int pump(PancakePeer *from, PancakePeer *to) {
    for (;;) {
        PancakeManagedFrame frame;
        int32_t rc = pancake_peer_take_outbound(from, &frame);
        if (rc == PANCAKE_ERR_WOULD_BLOCK) {
            return PANCAKE_OK; /* queue drained */
        }
        if (rc != PANCAKE_OK) {
            return rc;
        }

        /* Feed the frame's bytes as a byte stream: recv_stream consumes one
           whole frame per call and reports how many bytes it took. */
        size_t offset = 0;
        while (offset < frame.len) {
            size_t consumed = 0;
            rc = pancake_peer_recv_stream(to, frame.bytes + offset, frame.len - offset, &consumed);
            if (rc == PANCAKE_ERR_WOULD_BLOCK) {
                break; /* partial frame: a socket loop would read more */
            }
            if (rc != PANCAKE_OK) {
                pancake_managed_frame_release(&frame);
                return rc;
            }
            offset += consumed;
        }
        pancake_managed_frame_release(&frame);

        rc = pancake_peer_step(to);
        if (rc != PANCAKE_OK) {
            return rc;
        }
    }
}

/* Encode pending work on both peers and shuttle frames both ways until both
   queues are quiet. */
static int settle(PancakePeer *a, PancakePeer *b) {
    for (int i = 0; i < 8; i++) {
        int rc = pancake_peer_step(a);
        if (rc != PANCAKE_OK) {
            return rc;
        }
        rc = pancake_peer_step(b);
        if (rc != PANCAKE_OK) {
            return rc;
        }
        rc = pump(a, b);
        if (rc != PANCAKE_OK) {
            return rc;
        }
        rc = pump(b, a);
        if (rc != PANCAKE_OK) {
            return rc;
        }
    }
    return PANCAKE_OK;
}

int main(void) {
    /* Two already-open fixture peers: the host publishes, the client calls.
       A real connection would use pancake_peer_new and the keyed
       pancake_peer_start_session handshake first. */
    PancakePeer *host = NULL;
    PancakePeer *client = NULL;
    if (pancake_peer_new_raw_open(&host) != PANCAKE_OK ||
        pancake_peer_new_raw_open(&client) != PANCAKE_OK) {
        return 1;
    }

    /* A raw-open fixture skips the handshake, so install the well-known
       bootstrap export the open transition would have registered. A peer that
       handshakes gets this for free. */
    if (pancake_peer_register_export(host, PANCAKE_BOOTSTRAP_POSITION) != PANCAKE_OK) {
        return 1;
    }

    /* The host publishes an echo capability behind the name "echo". The
       library answers the client's bootstrap fetch for it automatically. */
    uint64_t echo_export = 0;
    if (pancake_peer_register_bootstrap_cap(host, (const uint8_t *)"echo", 4, &echo_export) != PANCAKE_OK) {
        return 1;
    }

    /* The client asks for it by name: one call registers the bootstrap
       import, allocates the question id, and queues the canonical fetch. */
    uint64_t fetch_answer = 0;
    if (pancake_peer_send_bootstrap_fetch(client, (const uint8_t *)"echo", 4, &fetch_answer) != PANCAKE_OK) {
        return 1;
    }
    if (settle(client, host) != PANCAKE_OK) {
        return 1;
    }

    /* The fetch settles as a typed resolve carrying the capability. */
    if (pancake_peer_peek_event(client) != PANCAKE_EVENT_RESOLVE) {
        return 1;
    }
    PancakeResolve fetched;
    if (pancake_peer_poll_event_resolve(client, &fetched) != PANCAKE_OK) {
        return 1;
    }
    if (fetched.answer != fetch_answer ||
        fetched.resolution_kind != PANCAKE_RESOLUTION_FULFILL ||
        fetched.fulfill.kind != PANCAKE_ARG_REFERENCE) {
        pancake_resolve_release(&fetched);
        return 1;
    }
    PancakeReference echo_cap = fetched.fulfill.reference;
    pancake_resolve_release(&fetched);
    printf("fetched \"echo\" as import %llu\n", (unsigned long long)echo_cap.id);

    /* Call it: deliver ["hello"] and ask for a reply on a fresh answer. */
    uint64_t call_answer = 0;
    if (pancake_peer_next_answer(client, &call_answer) != PANCAKE_OK) {
        return 1;
    }
    PancakeArgument hello;
    memset(&hello, 0, sizeof hello);
    hello.kind = PANCAKE_ARG_STRING;
    hello.bytes = (const uint8_t *)"hello";
    hello.bytes_len = 5;
    if (pancake_peer_send_deliver(client, &echo_cap, &hello, 1, 1, call_answer) != PANCAKE_OK) {
        return 1;
    }
    if (settle(client, host) != PANCAKE_OK) {
        return 1;
    }

    /* The host's event loop: route by kind, take each typed deliver, and serve
       the one addressed to the echo export (the bootstrap fetch also surfaces
       as a deliver event; the library already answered it). */
    PancakeDeliver call;
    for (;;) {
        if (pancake_peer_peek_event(host) != PANCAKE_EVENT_DELIVER) {
            return 1;
        }
        if (pancake_peer_poll_event_deliver(host, &call) != PANCAKE_OK) {
            return 1;
        }
        if (call.target.kind == PANCAKE_REF_NEAR && call.target.id == echo_export) {
            break;
        }
        pancake_deliver_release(&call);
    }
    if (call.args_len < 1 || call.has_answer == 0) {
        pancake_deliver_release(&call);
        return 1;
    }
    printf("host echoing \"%.*s\"\n", (int)call.args[0].bytes_len, (const char *)call.args[0].bytes);
    int32_t rc = pancake_peer_send_resolve(host, call.answer, PANCAKE_RESOLUTION_FULFILL, &call.args[0], NULL, 0);
    pancake_deliver_release(&call);
    if (rc != PANCAKE_OK) {
        return 1;
    }
    if (settle(host, client) != PANCAKE_OK) {
        return 1;
    }

    /* The reply lands on the client as a resolve keyed on the call's answer. */
    PancakeResolve reply;
    if (pancake_peer_poll_event_resolve(client, &reply) != PANCAKE_OK) {
        return 1;
    }
    int ok = reply.answer == call_answer &&
        reply.resolution_kind == PANCAKE_RESOLUTION_FULFILL &&
        reply.fulfill.kind == PANCAKE_ARG_STRING &&
        reply.fulfill.bytes_len == 5 &&
        memcmp(reply.fulfill.bytes, "hello", 5) == 0;
    if (ok) {
        printf("round trip: \"%.*s\"\n", (int)reply.fulfill.bytes_len, (const char *)reply.fulfill.bytes);
    }
    pancake_resolve_release(&reply);

    pancake_peer_release(client);
    pancake_peer_release(host);
    return ok ? 0 : 1;
}
