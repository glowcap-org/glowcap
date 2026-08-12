/* Generated from src/c_abi/driver/mod.zig by tools/gen/header/driver.zig.
   Do not edit by hand: run `zig build gen-header-driver`.
   libpancake_driver exports only pancake_driver_*; compose it with
   libpancake_host and the transport archives selected by the application. */
#ifndef PANCAKE_DRIVER_H
#define PANCAKE_DRIVER_H

#include <stddef.h>
#include <stdint.h>
#include "pancake_host.h"
#include "pancake_transport_provider.h"

#ifdef __cplusplus
extern "C" {
#endif

/* A stepping CapTP loop over one Host moved into pancake_driver_take_host.
   The driver owns that Host after a successful move. */
typedef struct PancakeDriverLoop PancakeDriverLoop;
/* PancakeDriverOptions.abi_version. */
#define PANCAKE_DRIVER_OPTIONS_ABI_VERSION 1
/* Largest handshake_ms or settle_ms value. */
#define PANCAKE_DRIVER_MAX_WAIT_MS 2147483647
/* Default PancakeDriverOptions.wire_buffer_bytes. */
#define PANCAKE_DRIVER_DEFAULT_WIRE_BUFFER_BYTES 16384
/* Default PancakeDriverOptions.max_pending_opens. */
#define PANCAKE_DRIVER_DEFAULT_MAX_PENDING_OPENS 256
/* Default PancakeDriverOptions.handshake_ms. */
#define PANCAKE_DRIVER_DEFAULT_HANDSHAKE_MS 10000
/* Default PancakeDriverOptions.settle_ms. */
#define PANCAKE_DRIVER_DEFAULT_SETTLE_MS 10000
/* PancakeDriverEvent.kind: ticketed dial or external adoption reached an open session. */
#define PANCAKE_DRIVER_EVENT_OPENED 0
/* PancakeDriverEvent.kind: ticketed dial or external adoption failed; message carries the reason. */
#define PANCAKE_DRIVER_EVENT_OPEN_FAILED 1
/* PancakeDriverEvent.kind: listener accepted session. */
#define PANCAKE_DRIVER_EVENT_ACCEPTED 2
/* PancakeDriverEvent.kind: session wire closed; release the handle through the driver. */
#define PANCAKE_DRIVER_EVENT_SESSION_CLOSED 3
/* PancakeDriverEvent.kind: action carries a settled or failed vow. */
#define PANCAKE_DRIVER_EVENT_COMPLETION 4
/* pancake_driver_adopt_external role: use the dialed Host/session half. */
#define PANCAKE_DRIVER_ADOPT_DIALED 0
/* pancake_driver_adopt_external role: use the accepted Host/session half. */
#define PANCAKE_DRIVER_ADOPT_ACCEPTED 1

typedef struct PancakeDriverOptions {
    /* PANCAKE_DRIVER_OPTIONS_ABI_VERSION. */
    uint32_t abi_version;
    /* sizeof(PancakeDriverOptions). */
    size_t struct_size;
    /* Retained bytes per stream direction, or per multiplexed read staging buffer. */
    size_t wire_buffer_bytes;
    /* Maximum transport connects and CapTP handshakes admitted at once. */
    size_t max_pending_opens;
    /* Handshake progress budget in milliseconds. */
    uint32_t handshake_ms;
    /* Application-answer progress budget in milliseconds. */
    uint32_t settle_ms;
} PancakeDriverOptions;

typedef struct PancakeDriverEvent {
    /* PANCAKE_DRIVER_EVENT_*. */
    uint32_t kind;
    /* Open ticket or listener id. */
    uint64_t ticket;
    /* OPENED, ACCEPTED, or SESSION_CLOSED session. */
    PancakeHostSession *session;
    /* COMPLETION action. */
    PancakeHostAction action;
    /* Borrowed OPEN_FAILED message. */
    const uint8_t *message;
    size_t message_len;
} PancakeDriverEvent;

/* Move a quiescent Host into a transport loop. Failure leaves Host ownership
   unchanged. Success transfers transport execution, action draining, session
   release, and terminal Host release to the loop. The loop starts with no
   transports; add provider packages before dial or listen. The options layout
   must be recognized and every policy value positive. Release only through
   pancake_driver_release. */
int32_t pancake_driver_take_host(PancakeHost *host, const PancakeDriverOptions *options, PancakeDriverLoop **out_loop);
/* Release listeners, wires, events, provider adapters, and the moved Host.
   NULL is a no-op; refused inside a callback. */
int32_t pancake_driver_release(PancakeDriverLoop *loop);
/* Install one validated provider package. The driver acquires its native lease
   through provider.retain, copies profiles and implementation tables, and calls
   provider.release only after every listener, connection, and callback has retired.
   The provider lease, not a binding-side owner, keeps the transport context alive. */
int32_t pancake_driver_add_provider(PancakeDriverLoop *loop, const PancakeTransportProvider *provider);
/* Report whether one installed provider owns the transport symbol. */
int32_t pancake_driver_has_transport(PancakeDriverLoop *loop, const uint8_t *transport, size_t transport_len, uint8_t *out_present);
/* Begin a non-blocking dial from one borrowed locator view. Pre-admission failures
   return directly and mint no ticket. After admission, transport completion and
   the CapTP handshake advance through step; OPENED or OPEN_FAILED carries the
   returned ticket. */
int32_t pancake_driver_dial(PancakeDriverLoop *loop, const PancakeLocatorView *locator, uint64_t *out_ticket);
/* Begin adoption of one externally established provider connection. Pre-admission failures return directly and mint no ticket. The subject is interpreted only by the provider registered under transport. role selects the Host/session half; after admission, OPENED or OPEN_FAILED carries the returned ticket. */
int32_t pancake_driver_adopt_external(PancakeDriverLoop *loop, const uint8_t *transport, size_t transport_len, uint64_t subject, uint32_t role, uint64_t *out_ticket);
/* Bind through a registered listener-capable provider. ACCEPTED events carry
   the returned listener id. */
int32_t pancake_driver_listen(PancakeDriverLoop *loop, const uint8_t *transport, size_t transport_len, const uint8_t *designator, size_t designator_len, uint64_t *out_listener);
/* Borrow the active listener's complete locator view until it is advertised
   again, closed, or its loop is released. Clone through libpancake_ocapn to retain it. */
int32_t pancake_driver_listener_locator(PancakeDriverLoop *loop, uint64_t listener, PancakeLocatorView *out_locator);
/* Replace an active listener's complete advertised locator from a borrowed
   view while preserving its transport and identity posture. The loop clones the
   value before returning. */
int32_t pancake_driver_listener_advertise(PancakeDriverLoop *loop, uint64_t listener, const PancakeLocatorView *locator);
/* Select this listener locator as the Host's acceptable location. */
int32_t pancake_driver_listener_select(PancakeDriverLoop *loop, uint64_t listener);
/* Stop one listener and remove its advertised locator without releasing the
   loop or accepted session handles. */
int32_t pancake_driver_listener_close(PancakeDriverLoop *loop, uint64_t listener);
/* Return the loop-owned descriptor on which the embedder parks. */
int32_t pancake_driver_readiness_fd(PancakeDriverLoop *loop, int32_t *out_fd);
/* Advance listeners, in-flight opens, wires, Host actions, and handshakes.
   PANCAKE_OK means immediate work was observed or an event remains queued;
   PANCAKE_ERR_WOULD_BLOCK means the loop is drained after the requested wait.
   Edge-triggered embedders call until WOULD_BLOCK before clearing readiness.
   Drain events after every call that returns PANCAKE_OK. */
int32_t pancake_driver_step(PancakeDriverLoop *loop, int32_t timeout_ms);
/* End the current thread's exclusive claim at a quiescent handoff boundary. */
int32_t pancake_driver_detach_thread(PancakeDriverLoop *loop);
/* Wake a parked loop from any thread. */
int32_t pancake_driver_wake(PancakeDriverLoop *loop);
/* Pop one event, or PANCAKE_ERR_WOULD_BLOCK. Borrowed views last until the
   next pop. */
int32_t pancake_driver_next_event(PancakeDriverLoop *loop, PancakeDriverEvent *out);
/* Release one loop-owned session and its wire. */
int32_t pancake_driver_session_release(PancakeDriverLoop *loop, PancakeHostSession *session);
/* Query or copy this archive's thread-local error message. */
size_t pancake_driver_last_error(uint8_t *out_buf, size_t cap);
/* Clear this archive's thread-local error message. */
void pancake_driver_clear_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* PANCAKE_DRIVER_H */
