/* The normative byte-fed host embedder pump (bindings/README.md "embedder
   contract", ADR-0072). Two PancakeHosts open a keyed session over plain memory
   — feed_bytes, the one-loop action drain (FLUSH, then take_outbound, then write into
   the partner's inbox), feed-refusal with last_abort, and EOF via
   break_far_vows. This is the compiled checklist the four language bindings
   mirror. The drain rides pancake_host_pump_drain (ADR-0072 fifth amendment)
   — an opt-in wrapper that still pops pancake_host_next_action internally.

   Links libpancake_host (+ ocapn for the shared managed-frame vocabulary). */

#include "pancake_host.h"
#include "pancake_ocapn.h"

#include <stdio.h>
#include <string.h>

typedef struct {
    uint8_t buf[8192];
    size_t len;
} BytePipe;

typedef struct {
    BytePipe *pipe;
    PancakeHostSession *session;
} FlushCtx;

static int fail(const char *what) {
    uint8_t buf[256];
    size_t n = pancake_host_last_error(buf, sizeof buf);
    fprintf(stderr, "host_embedder_pump: %s: %.*s\n", what, (int)n, buf);
    return 1;
}

/* Honor FLUSH by draining take_outbound into `pipe`. Other arms are NULL on
   the hooks (no dials, no vows) — enough for the handshake shuttle. */
static int32_t on_flush(void *ctx, PancakeHost *host,
    const PancakeHostAction *action, uint32_t *out_progressed) {
    FlushCtx *f = (FlushCtx *)ctx;
    (void)host;
    if (out_progressed) {
        *out_progressed = 0;
    }
    if (action->kind != PANCAKE_HOST_ACTION_FLUSH || action->session != f->session) {
        return PANCAKE_OK;
    }
    for (;;) {
        PancakeManagedFrame frame;
        int32_t rc = pancake_host_session_take_outbound(f->session, &frame);
        if (rc == PANCAKE_ERR_WOULD_BLOCK) {
            break;
        }
        if (rc != PANCAKE_OK) {
            return rc;
        }
        char prefix[32];
        int prefix_len = snprintf(prefix, sizeof prefix, "%zu:", frame.len);
        if (prefix_len < 0 || (size_t)prefix_len >= sizeof prefix ||
            f->pipe->len + (size_t)prefix_len + frame.len > sizeof f->pipe->buf) {
            pancake_managed_frame_release(&frame);
            fprintf(stderr, "host_embedder_pump: pipe overflow\n");
            return PANCAKE_ERR_INVALID_ARGUMENT;
        }
        memcpy(f->pipe->buf + f->pipe->len, prefix, (size_t)prefix_len);
        f->pipe->len += (size_t)prefix_len;
        memcpy(f->pipe->buf + f->pipe->len, frame.bytes, frame.len);
        f->pipe->len += frame.len;
        pancake_managed_frame_release(&frame);
    }
    return PANCAKE_OK;
}

static int drain_actions(PancakeHost *host, BytePipe *pipe, PancakeHostSession *session) {
    FlushCtx ctx = { .pipe = pipe, .session = session };
    PancakeHostPumpHooks hooks = {
        .ctx = &ctx,
        .flush = on_flush,
        .close = NULL,
        .need_gift_id = NULL,
        .complete = NULL,
        .dial = NULL,
    };
    return pancake_host_pump_drain(host, &hooks, NULL);
}

static int feed_pipe(PancakeHostSession *to, BytePipe *pipe) {
    /* The library owns framing and the unconsumed tail, so one call moves
       the whole pipe; an empty feed resumes frames the session held behind
       its handshake open. */
    int32_t rc = pancake_host_session_feed_bytes(to, pipe->buf, pipe->len);
    if (rc != PANCAKE_OK) {
        return rc;
    }
    pipe->len = 0;
    return PANCAKE_OK;
}

static int shuttle(PancakeHost *ha, PancakeHostSession *a, BytePipe *ab,
    PancakeHost *hb, PancakeHostSession *b, BytePipe *ba) {
    int32_t rc = drain_actions(ha, ab, a);
    if (rc != PANCAKE_OK) {
        return rc;
    }
    rc = drain_actions(hb, ba, b);
    if (rc != PANCAKE_OK) {
        return rc;
    }
    rc = feed_pipe(b, ab);
    if (rc != PANCAKE_OK) {
        return rc;
    }
    rc = feed_pipe(a, ba);
    if (rc != PANCAKE_OK) {
        return rc;
    }
    return PANCAKE_OK;
}

static PancakeHost *new_host(uint8_t fill, size_t frame_cap) {
    uint8_t seed[32];
    memset(seed, fill, sizeof seed);
    PancakeHost *host = NULL;
    if (pancake_host_new(seed, sizeof seed, frame_cap, 1, PANCAKE_CODEC_SYRUP,
                         PANCAKE_CAPTP_V1_0, PANCAKE_FEATURE_FULL, 0, &host) != PANCAKE_OK) {
        return NULL;
    }
    return host;
}

static int32_t set_tcp_locator(PancakeHost *host, const char *designator) {
    uint8_t *encoded = NULL;
    size_t encoded_len = 0;
    int32_t rc = pancake_locator_record_encode(
        (const uint8_t *)"tcp", 3,
        (const uint8_t *)designator, strlen(designator),
        NULL, 0, &encoded, &encoded_len);
    if (rc == PANCAKE_OK) {
        rc = pancake_host_set_advertised_locator(host, encoded, encoded_len);
    }
    pancake_locator_record_bytes_release(encoded, encoded_len);
    return rc;
}

static int32_t ensure_tcp_locator(PancakeHost *host) {
    return pancake_host_ensure_advertised_locator(
        host, (const uint8_t *)"tcp", 3);
}

int main(void) {
    /* ── 1. feed_bytes + action drain until the session opens ──────────────── */
    PancakeHost *client = new_host(0xa1, PANCAKE_DEFAULT_FRAME_CAP);
    PancakeHost *server = new_host(0xa2, PANCAKE_DEFAULT_FRAME_CAP);
    if (!client || !server) {
        return fail("host_new");
    }

    const char *designator = "127.0.0.1:9";
    PancakeHostSession *accepted = NULL;
    PancakeHostSession *dialed = NULL;
    if (set_tcp_locator(server, designator) != PANCAKE_OK ||
        ensure_tcp_locator(client) != PANCAKE_OK) {
        return fail("publish locators");
    }
    if (pancake_host_session_open_accepted(
            server, (const uint8_t *)"tcp", 3, &accepted) != PANCAKE_OK) {
        return fail("open_accepted");
    }
    if (pancake_host_session_open_dialed_locator(client, (const uint8_t *)"tcp", 3,
            (const uint8_t *)designator, strlen(designator), &dialed) != PANCAKE_OK) {
        return fail("open_dialed");
    }

    BytePipe ab = {0};
    BytePipe ba = {0};
    for (int round = 0; round < 64; round++) {
        if (shuttle(client, dialed, &ab, server, accepted, &ba) != PANCAKE_OK) {
            return fail("handshake shuttle");
        }
        if (pancake_host_session_is_open(dialed) && pancake_host_session_is_open(accepted)) {
            break;
        }
    }
    if (!pancake_host_session_is_open(dialed) || !pancake_host_session_is_open(accepted)) {
        fprintf(stderr, "host_embedder_pump: session did not open\n");
        return 1;
    }
    printf("host_embedder_pump: feed_bytes + FLUSH drain opened a keyed session\n");

    pancake_host_session_release(dialed);
    pancake_host_session_release(accepted);
    pancake_host_release(client);
    pancake_host_release(server);

    /* ── 2. feed refusal: over-cap frame, last_abort, drain abort, release ─── */
    PancakeHost *tiny = new_host(0xb1, 64);
    PancakeHost *peer = new_host(0xb2, PANCAKE_DEFAULT_FRAME_CAP);
    if (!tiny || !peer) {
        return fail("host_new (refusal)");
    }
    PancakeHostSession *tiny_acc = NULL;
    PancakeHostSession *peer_dial = NULL;
    const char *d2 = "127.0.0.1:10";
    if (set_tcp_locator(tiny, d2) != PANCAKE_OK ||
        ensure_tcp_locator(peer) != PANCAKE_OK) {
        return fail("publish refusal locators");
    }
    if (pancake_host_session_open_accepted(
            tiny, (const uint8_t *)"tcp", 3, &tiny_acc) != PANCAKE_OK) {
        return fail("open_accepted tiny");
    }
    if (pancake_host_session_open_dialed_locator(peer, (const uint8_t *)"tcp", 3,
            (const uint8_t *)d2, strlen(d2), &peer_dial) != PANCAKE_OK) {
        return fail("open_dialed peer");
    }

    BytePipe refuse_pipe = {0};
    if (drain_actions(peer, &refuse_pipe, peer_dial) != PANCAKE_OK) {
        return fail("peer hello encode");
    }
    int32_t refused = pancake_host_session_feed_bytes(tiny_acc, refuse_pipe.buf, refuse_pipe.len);
    if (refused == PANCAKE_OK) {
        fprintf(stderr, "host_embedder_pump: expected over-cap refusal\n");
        return 1;
    }
    PancakeLastAbort abort;
    if (pancake_host_session_last_abort(tiny_acc, &abort) != PANCAKE_OK) {
        return fail("last_abort");
    }
    /* The partner hears why: the refusal queues an op:abort the drain flushes. */
    BytePipe abort_out = {0};
    if (drain_actions(tiny, &abort_out, tiny_acc) != PANCAKE_OK) {
        return fail("abort drain");
    }
    printf("host_embedder_pump: feed refusal surfaced last_abort (domain=%u), "
        "%zu abort bytes queued for the partner\n",
        (unsigned)abort.domain, abort_out.len);

    pancake_host_session_release(tiny_acc);
    pancake_host_session_release(peer_dial);
    pancake_host_release(tiny);
    pancake_host_release(peer);

    /* ── 3. EOF means break ────────────────────────────────────────────────── */
    PancakeHost *h = new_host(0xc1, PANCAKE_DEFAULT_FRAME_CAP);
    if (!h) {
        return fail("host_new (eof)");
    }
    PancakeHostSession *c = NULL;
    const char *d3 = "127.0.0.1:11";
    if (set_tcp_locator(h, d3) != PANCAKE_OK) {
        return fail("publish eof locator");
    }
    if (pancake_host_session_open_accepted(
            h, (const uint8_t *)"tcp", 3, &c) != PANCAKE_OK) {
        return fail("open_accepted eof");
    }
    const char msg[] = "connection closed";
    if (pancake_host_session_break_far_vows(c, (const uint8_t *)msg, sizeof msg - 1) != PANCAKE_OK) {
        return fail("break_far_vows");
    }
    printf("host_embedder_pump: EOF path broke far vows\n");
    pancake_host_session_release(c);
    pancake_host_release(h);

    printf("host_embedder_pump: embedder choreography OK\n");
    return 0;
}
