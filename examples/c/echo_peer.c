/* An in-process echo conversation between two peers, driven entirely through
   the sans-io ocapn surface (pancake_ocapn.h). This is the reference shape of a
   C event loop: pump bytes with recv_stream, take events with next_event, and
   drain with take_outbound. No
   sockets, the two peers exchange their frames through plain memory, which is
   exactly what the sans-I/O contract promises a host can do. It links the ocapn
   base plus the TCP transport archive (ADR-0059) to show a real composed link
   line stays symbol-disjoint even when the program drives only the base.

   This is the host's view: a host that owns its event loop drives the peer by
   hand. The owning, Connection-shaped client surface — dial, handshake, fetch,
   call — is pancake_tcp_session_* in pancake_net_transport_tcp.h (ADR-0062); its
   worked round-trip against a hosting peer lives in
   test/c_abi/tcp_session_test.zig. */

#include "pancake_ocapn.h"

#include <stdio.h>
#include <string.h>

/* Move every queued outbound frame from one peer into the other, counting the
   frames moved into *moved. The sender owns each frame until release; the
   receiver consumes the bytes through recv_stream, the stream-input primitive a
   socket loop would also use. */
static int pump(PancakePeer *from, PancakePeer *to, int *moved) {
    for (;;) {
        PancakeManagedFrame frame;
        int32_t rc = pancake_peer_take_outbound(from, &frame);
        if (rc == PANCAKE_ERR_WOULD_BLOCK) {
            return PANCAKE_OK;
        }
        if (rc != PANCAKE_OK) {
            return rc;
        }

        *moved += 1;
        size_t offset = 0;
        while (offset < frame.len) {
            size_t consumed = 0;
            rc = pancake_peer_recv_stream(to, frame.bytes + offset, frame.len - offset, &consumed);
            if (rc == PANCAKE_ERR_WOULD_BLOCK) {
                break;
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

/* Encode pending work on both peers and shuttle frames both ways until a full
   round moves nothing, which is when both queues are quiet. The round cap is a
   defensive bound against a protocol loop, far above what this conversation
   needs. */
static int settle(PancakePeer *a, PancakePeer *b) {
    for (int round = 0; round < 32; round++) {
        int moved = 0;
        int rc = pancake_peer_step(a);
        if (rc != PANCAKE_OK) {
            return rc;
        }
        rc = pancake_peer_step(b);
        if (rc != PANCAKE_OK) {
            return rc;
        }
        rc = pump(a, b, &moved);
        if (rc != PANCAKE_OK) {
            return rc;
        }
        rc = pump(b, a, &moved);
        if (rc != PANCAKE_OK) {
            return rc;
        }
        if (moved == 0) {
            return PANCAKE_OK;
        }
    }
    return PANCAKE_ERR_INTERNAL;
}

int main(void) {
    PancakePeer *host = NULL;
    PancakePeer *client = NULL;
    if (pancake_peer_new_raw_open(&host) != PANCAKE_OK ||
        pancake_peer_new_raw_open(&client) != PANCAKE_OK) {
        return 1;
    }

    if (pancake_peer_register_export(host, PANCAKE_BOOTSTRAP_POSITION) != PANCAKE_OK) {
        return 1;
    }

    uint64_t echo_export = 0;
    if (pancake_peer_register_bootstrap_cap(host, (const uint8_t *)"echo", 4, &echo_export) != PANCAKE_OK) {
        return 1;
    }

    uint64_t fetch_answer = 0;
    if (pancake_peer_send_bootstrap_fetch(client, (const uint8_t *)"echo", 4, &fetch_answer) != PANCAKE_OK) {
        return 1;
    }
    if (settle(client, host) != PANCAKE_OK) {
        return 1;
    }

    PancakeAnyEvent fetched;
    if (pancake_peer_next_event(client, &fetched) != PANCAKE_OK) {
        return 1;
    }
    if (fetched.projection != PANCAKE_PROJECTION_RESOLVE ||
        fetched.resolve.answer != fetch_answer ||
        fetched.resolve.resolution_kind != PANCAKE_RESOLUTION_FULFILL ||
        fetched.resolve.fulfill.kind != PANCAKE_ARG_REFERENCE) {
        pancake_any_event_release(&fetched);
        return 1;
    }
    PancakeReference echo_cap = fetched.resolve.fulfill.reference;
    pancake_any_event_release(&fetched);
    printf("fetched \"echo\" as import %llu\n", (unsigned long long)echo_cap.id);

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

    PancakeAnyEvent polled;
    for (;;) {
        if (pancake_peer_next_event(host, &polled) != PANCAKE_OK) {
            return 1;
        }
        if (polled.projection == PANCAKE_PROJECTION_DELIVER &&
            polled.deliver.target.kind == PANCAKE_REF_NEAR &&
            polled.deliver.target.id == echo_export) {
            break;
        }
        pancake_any_event_release(&polled);
    }
    PancakeDeliver call = polled.deliver;
    if (call.args_len < 1 || call.has_answer == 0) {
        pancake_any_event_release(&polled);
        return 1;
    }
    printf("host echoing \"%.*s\"\n", (int)call.args[0].bytes_len, (const char *)call.args[0].bytes);
    int32_t rc = pancake_peer_send_resolve(host, call.answer, PANCAKE_RESOLUTION_FULFILL, &call.args[0], NULL, 0);
    pancake_any_event_release(&polled);
    if (rc != PANCAKE_OK) {
        return 1;
    }
    if (settle(host, client) != PANCAKE_OK) {
        return 1;
    }

    PancakeAnyEvent replied;
    if (pancake_peer_next_event(client, &replied) != PANCAKE_OK) {
        return 1;
    }
    PancakeResolve reply = replied.resolve;
    int ok = replied.projection == PANCAKE_PROJECTION_RESOLVE &&
        reply.answer == call_answer &&
        reply.resolution_kind == PANCAKE_RESOLUTION_FULFILL &&
        reply.fulfill.kind == PANCAKE_ARG_STRING &&
        reply.fulfill.bytes_len == 5 &&
        memcmp(reply.fulfill.bytes, "hello", 5) == 0;
    if (ok) {
        printf("round trip: \"%.*s\"\n", (int)reply.fulfill.bytes_len, (const char *)reply.fulfill.bytes);
    }
    pancake_any_event_release(&replied);

    pancake_peer_release(client);
    pancake_peer_release(host);
    return ok ? 0 : 1;
}
