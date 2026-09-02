/* Two hosts open a keyed session over plain memory: feed received bytes,
   drain work (FLUSH copies take_outbound into the partner's inbox), refuse
   an over-cap frame, and break far vows when the connection is gone. This
   is the compiled checklist the language bindings mirror. glowcap_host_pump_drain
   is the opt-in wrapper; it still pops glowcap_host_next_action internally.

   Links libglowcap_host (and libglowcap_ocapn for managed frames). */

#include "glowcap_host.h"
#include "glowcap_ocapn.h"

#include <stdio.h>
#include <string.h>

typedef struct {
    uint8_t buf[8192];
    size_t len;
} BytePipe;

typedef struct {
    BytePipe *pipe;
    GlowcapHostSession *session;
} FlushCtx;

static int fail(const char *what) {
    uint8_t buf[256];
    size_t n = glowcap_host_last_error(buf, sizeof buf);
    fprintf(stderr, "host_embedder_pump: %s: %.*s\n", what, (int)n, buf);
    return 1;
}

/* Honor FLUSH by draining take_outbound into `pipe`. CLOSE, COMPLETE, DIAL,
   and NEED_GIFT_ID fail the scene: a NULL arm would skip-consume them. */
static int32_t refuse_unexpected(void *ctx, GlowcapHost *host,
    const GlowcapHostAction *action, uint32_t *out_progressed) {
    (void)ctx;
    (void)host;
    if (out_progressed) {
        *out_progressed = 0;
    }
    fprintf(stderr, "host_embedder_pump: unexpected action kind %u\n",
        (unsigned)action->kind);
    return GLOWCAP_ERR_INVALID_ARGUMENT;
}

static int32_t on_flush(void *ctx, GlowcapHost *host,
    const GlowcapHostAction *action, uint32_t *out_progressed) {
    FlushCtx *f = (FlushCtx *)ctx;
    (void)host;
    if (out_progressed) {
        *out_progressed = 0;
    }
    if (action->kind != GLOWCAP_HOST_ACTION_FLUSH || action->session != f->session) {
        fprintf(stderr, "host_embedder_pump: unexpected flush target\n");
        return GLOWCAP_ERR_INVALID_ARGUMENT;
    }
    for (;;) {
        GlowcapManagedFrame frame;
        uint8_t prefix[GLOWCAP_HOST_OUTBOUND_PREFIX_CAP];
        size_t prefix_len = 0;
        int32_t rc = glowcap_host_session_take_outbound(
            f->session, &frame, prefix, sizeof prefix, &prefix_len);
        if (rc == GLOWCAP_ERR_WOULD_BLOCK) {
            break;
        }
        if (rc != GLOWCAP_OK) {
            return rc;
        }
        if (f->pipe->len + prefix_len + frame.len > sizeof f->pipe->buf) {
            glowcap_managed_frame_release(&frame);
            fprintf(stderr, "host_embedder_pump: pipe overflow\n");
            return GLOWCAP_ERR_INVALID_ARGUMENT;
        }
        memcpy(f->pipe->buf + f->pipe->len, prefix, prefix_len);
        f->pipe->len += prefix_len;
        memcpy(f->pipe->buf + f->pipe->len, frame.bytes, frame.len);
        f->pipe->len += frame.len;
        glowcap_managed_frame_release(&frame);
        if (out_progressed) {
            *out_progressed = 1;
        }
    }
    return GLOWCAP_OK;
}

static int drain_actions(GlowcapHost *host, BytePipe *pipe, GlowcapHostSession *session) {
    FlushCtx ctx = { .pipe = pipe, .session = session };
    GlowcapHostPumpHooks hooks = {
        .ctx = &ctx,
        .flush = on_flush,
        .close = refuse_unexpected,
        .need_gift_id = refuse_unexpected,
        .complete = refuse_unexpected,
        .dial = refuse_unexpected,
    };
    return glowcap_host_pump_drain(host, &hooks, NULL, NULL);
}

static int feed_pipe(GlowcapHostSession *to, BytePipe *pipe) {
    /* The library owns framing and the unconsumed tail, so one call moves
       the whole pipe; the resume verb dispatches frames the session held
       behind its handshake open. */
    int32_t rc = pipe->len == 0
        ? glowcap_host_session_resume_feed(to)
        : glowcap_host_session_feed_bytes(to, pipe->buf, pipe->len);
    if (rc != GLOWCAP_OK) {
        return rc;
    }
    pipe->len = 0;
    return GLOWCAP_OK;
}

static int shuttle(GlowcapHost *ha, GlowcapHostSession *a, BytePipe *ab,
    GlowcapHost *hb, GlowcapHostSession *b, BytePipe *ba) {
    int32_t rc = drain_actions(ha, ab, a);
    if (rc != GLOWCAP_OK) {
        return rc;
    }
    rc = drain_actions(hb, ba, b);
    if (rc != GLOWCAP_OK) {
        return rc;
    }
    rc = feed_pipe(b, ab);
    if (rc != GLOWCAP_OK) {
        return rc;
    }
    rc = feed_pipe(a, ba);
    if (rc != GLOWCAP_OK) {
        return rc;
    }
    return GLOWCAP_OK;
}

static GlowcapHost *new_host(uint8_t fill, size_t frame_cap) {
    uint8_t seed[64];
    /* Durable identity followed by a distinct per-process session-key root.
       A real embedder draws the second half afresh on each process start. */
    memset(seed, fill, 32);
    memset(seed + 32, fill ^ 0xa5, 32);
    GlowcapHost *host = NULL;
    if (glowcap_host_new(seed, sizeof seed, frame_cap, 1, GLOWCAP_CODEC_SYRUP,
                         GLOWCAP_CAPTP_V1_0, GLOWCAP_FEATURE_FULL, 0, &host) != GLOWCAP_OK) {
        return NULL;
    }
    return host;
}

static int32_t set_tcp_locator(GlowcapHost *host, const char *designator) {
    const GlowcapLocatorView locator = {
        .abi_version = GLOWCAP_LOCATOR_VIEW_ABI_VERSION,
        .struct_size = sizeof(GlowcapLocatorView),
        .transport = (const uint8_t *)"tcp",
        .transport_len = 3,
        .designator = (const uint8_t *)designator,
        .designator_len = strlen(designator),
        .hints = NULL,
        .hint_count = 0,
        .hint_wire_form = GLOWCAP_HINTS_BOOLEAN_FALSE,
    };
    return glowcap_host_set_advertised_locator(host, &locator);
}

static int32_t open_accepted(
        GlowcapHost *host, const char *transport, GlowcapHostSession **out_session) {
    /* An address-scheme accept with no reported address: the host falls back
     * to the unreachable-client placeholder unless a locator was published,
     * and a published one always wins. */
    return glowcap_host_session_open_accepted(
        host, (const uint8_t *)transport, strlen(transport),
        GLOWCAP_DESIGNATOR_SCHEME_ADDRESS, NULL, 0, NULL, 0, out_session);
}

static int32_t open_dialed(
        GlowcapHost *host, const char *transport, const char *designator,
        GlowcapHostSession **out_session) {
    /* The locator travels whole as one hintless view; the host retains its
     * own dial default for the transport. */
    GlowcapLocatorView locator = {0};
    locator.abi_version = GLOWCAP_LOCATOR_VIEW_ABI_VERSION;
    locator.struct_size = sizeof locator;
    locator.transport = (const uint8_t *)transport;
    locator.transport_len = strlen(transport);
    locator.designator = (const uint8_t *)designator;
    locator.designator_len = strlen(designator);
    locator.hint_wire_form = GLOWCAP_HINTS_BOOLEAN_FALSE;
    return glowcap_host_session_open_dialed_locator(host, &locator, out_session);
}

static int32_t release_session(GlowcapHostSession **session) {
    if (!*session) {
        return GLOWCAP_OK;
    }
    const int32_t rc = glowcap_host_session_release(*session);
    if (rc == GLOWCAP_OK) {
        *session = NULL;
    }
    return rc;
}

static int32_t release_host(GlowcapHost **host) {
    if (!*host) {
        return GLOWCAP_OK;
    }
    const int32_t rc = glowcap_host_release(*host);
    if (rc == GLOWCAP_OK) {
        *host = NULL;
    }
    return rc;
}

static int scene_handshake(void) {
    GlowcapHost *client = new_host(0xa1, GLOWCAP_DEFAULT_FRAME_CAP);
    GlowcapHost *server = new_host(0xa2, GLOWCAP_DEFAULT_FRAME_CAP);
    GlowcapHostSession *accepted = NULL;
    GlowcapHostSession *dialed = NULL;
    int status = 1;

    if (!client || !server) {
        (void)fail("host_new");
        goto done;
    }

    const char *designator = "127.0.0.1:9";
    /* The server publishes where it accepts; the dialing client publishes
       nothing, because the dial retains the host's own default. */
    if (set_tcp_locator(server, designator) != GLOWCAP_OK) {
        (void)fail("publish locator");
        goto done;
    }
    if (open_accepted(server, "tcp", &accepted) != GLOWCAP_OK) {
        (void)fail("open_accepted");
        goto done;
    }
    if (open_dialed(client, "tcp", designator, &dialed) != GLOWCAP_OK) {
        (void)fail("open_dialed");
        goto done;
    }

    BytePipe ab = {0};
    BytePipe ba = {0};
    for (int round = 0; round < 64; round++) {
        if (shuttle(client, dialed, &ab, server, accepted, &ba) != GLOWCAP_OK) {
            (void)fail("handshake shuttle");
            goto done;
        }
        if (glowcap_host_session_is_open(dialed) && glowcap_host_session_is_open(accepted)) {
            break;
        }
    }
    if (!glowcap_host_session_is_open(dialed) || !glowcap_host_session_is_open(accepted)) {
        fprintf(stderr, "host_embedder_pump: session did not open\n");
        goto done;
    }
    printf("host_embedder_pump: feed_bytes + FLUSH drain opened a keyed session\n");
    status = 0;

done:
    if (release_session(&dialed) != GLOWCAP_OK) {
        (void)fail("session_release");
        status = 1;
    }
    if (release_session(&accepted) != GLOWCAP_OK) {
        (void)fail("session_release");
        status = 1;
    }
    if (release_host(&client) != GLOWCAP_OK) {
        (void)fail("host_release");
        status = 1;
    }
    if (release_host(&server) != GLOWCAP_OK) {
        (void)fail("host_release");
        status = 1;
    }
    return status;
}

static int scene_refusal(void) {
    GlowcapHost *tiny = new_host(0xb1, 64);
    GlowcapHost *peer = new_host(0xb2, GLOWCAP_DEFAULT_FRAME_CAP);
    GlowcapHostSession *tiny_acc = NULL;
    GlowcapHostSession *peer_dial = NULL;
    int status = 1;

    if (!tiny || !peer) {
        (void)fail("host_new (refusal)");
        goto done;
    }
    const char *d2 = "127.0.0.1:10";
    if (set_tcp_locator(tiny, d2) != GLOWCAP_OK) {
        (void)fail("publish refusal locator");
        goto done;
    }
    if (open_accepted(tiny, "tcp", &tiny_acc) != GLOWCAP_OK) {
        (void)fail("open_accepted tiny");
        goto done;
    }
    if (open_dialed(peer, "tcp", d2, &peer_dial) != GLOWCAP_OK) {
        (void)fail("open_dialed peer");
        goto done;
    }

    BytePipe refuse_pipe = {0};
    if (drain_actions(peer, &refuse_pipe, peer_dial) != GLOWCAP_OK) {
        (void)fail("peer hello encode");
        goto done;
    }
    int32_t refused = glowcap_host_session_feed_bytes(tiny_acc, refuse_pipe.buf, refuse_pipe.len);
    if (refused == GLOWCAP_OK) {
        fprintf(stderr, "host_embedder_pump: expected over-cap refusal\n");
        goto done;
    }
    GlowcapLastAbort abort;
    if (glowcap_host_session_last_abort(tiny_acc, &abort) != GLOWCAP_OK) {
        (void)fail("last_abort");
        goto done;
    }
    /* The partner hears why: the refusal queues an abort the drain flushes. */
    BytePipe abort_out = {0};
    if (drain_actions(tiny, &abort_out, tiny_acc) != GLOWCAP_OK) {
        (void)fail("abort drain");
        goto done;
    }
    printf("host_embedder_pump: feed refusal surfaced last_abort (domain=%u), "
        "%zu abort bytes queued for the partner\n",
        (unsigned)abort.domain, abort_out.len);
    status = 0;

done:
    if (release_session(&tiny_acc) != GLOWCAP_OK) {
        (void)fail("session_release");
        status = 1;
    }
    if (release_session(&peer_dial) != GLOWCAP_OK) {
        (void)fail("session_release");
        status = 1;
    }
    if (release_host(&tiny) != GLOWCAP_OK) {
        (void)fail("host_release");
        status = 1;
    }
    if (release_host(&peer) != GLOWCAP_OK) {
        (void)fail("host_release");
        status = 1;
    }
    return status;
}

static int scene_transport_closed(void) {
    GlowcapHost *h = new_host(0xc1, GLOWCAP_DEFAULT_FRAME_CAP);
    GlowcapHostSession *c = NULL;
    int status = 1;

    if (!h) {
        (void)fail("host_new (break)");
        goto done;
    }
    const char *d3 = "127.0.0.1:11";
    if (set_tcp_locator(h, d3) != GLOWCAP_OK) {
        (void)fail("publish break locator");
        goto done;
    }
    if (open_accepted(h, "tcp", &c) != GLOWCAP_OK) {
        (void)fail("open_accepted break");
        goto done;
    }
    const char msg[] = "connection closed";
    if (glowcap_host_session_transport_closed(c, (const uint8_t *)msg, sizeof msg - 1) != GLOWCAP_OK) {
        (void)fail("transport_closed");
        goto done;
    }
    printf("host_embedder_pump: transport_closed retired the session\n");
    status = 0;

done:
    if (release_session(&c) != GLOWCAP_OK) {
        (void)fail("session_release");
        status = 1;
    }
    if (release_host(&h) != GLOWCAP_OK) {
        (void)fail("host_release");
        status = 1;
    }
    return status;
}

int main(void) {
    if (scene_handshake() != 0) return 1;
    if (scene_refusal() != 0) return 1;
    if (scene_transport_closed() != 0) return 1;
    printf("host_embedder_pump: embedder choreography OK\n");
    return 0;
}
