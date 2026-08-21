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
/* PancakeDriverFailure.abi_version. */
#define PANCAKE_DRIVER_FAILURE_ABI_VERSION 2
/* Largest handshake_ms or settle_ms value. */
#define PANCAKE_DRIVER_MAX_WAIT_MS 2147483647
/* Default PancakeDriverOptions.wire_buffer_bytes. */
#define PANCAKE_DRIVER_DEFAULT_WIRE_BUFFER_BYTES 16384
/* Default PancakeDriverOptions.max_pending_opens. */
#define PANCAKE_DRIVER_DEFAULT_MAX_PENDING_OPENS 256
/* Default PancakeDriverOptions.handshake_ms. */
#define PANCAKE_DRIVER_DEFAULT_HANDSHAKE_MS 10000
/* Default PancakeDriverOptions.listener_setup_ms. */
#define PANCAKE_DRIVER_DEFAULT_LISTENER_SETUP_MS 10000
/* Default PancakeDriverOptions.settle_ms. */
#define PANCAKE_DRIVER_DEFAULT_SETTLE_MS 10000
/* PancakeDriverEvent.kind: dial or external adoption reached an open session. */
#define PANCAKE_DRIVER_EVENT_OPENED 0
/* PancakeDriverEvent.kind: dial or external adoption failed; failure fields carry the typed chain. */
#define PANCAKE_DRIVER_EVENT_OPEN_FAILED 1
/* PancakeDriverEvent.kind: listener accepted session. */
#define PANCAKE_DRIVER_EVENT_ACCEPTED 2
/* PancakeDriverEvent.kind: the session's physical carrier close barrier completed; failure fields carry a fault, or PANCAKE_OK for a clean close. */
#define PANCAKE_DRIVER_EVENT_SESSION_CLOSED 3
/* PancakeDriverEvent.kind: action carries a settled or failed vow. */
#define PANCAKE_DRIVER_EVENT_COMPLETION 4
/* PancakeDriverEvent.kind: listener construction completed. */
#define PANCAKE_DRIVER_EVENT_LISTENER_READY 5
/* PancakeDriverEvent.kind: listener construction or active accept infrastructure failed; the listener id is retired. */
#define PANCAKE_DRIVER_EVENT_LISTENER_FAILED 6
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
    /* Handshake progress budget in milliseconds; zero waits without a bound. */
    uint32_t handshake_ms;
    /* Listener-construction progress budget in milliseconds; zero waits without a bound. */
    uint32_t listener_setup_ms;
    /* Application-answer progress budget in milliseconds; zero waits without a bound. */
    uint32_t settle_ms;
} PancakeDriverOptions;

typedef struct PancakeDriverFailure {
    /* PANCAKE_DRIVER_FAILURE_ABI_VERSION. */
    uint32_t abi_version;
    /* sizeof(PancakeDriverFailure). */
    size_t struct_size;
    /* Stable PANCAKE_ERR_* primary result; PANCAKE_OK on success. */
    int32_t primary_result;
    /* Stable PANCAKE_ERR_* first consequence; PANCAKE_OK when absent. */
    int32_t secondary_result;
    /* Total observed consequences. */
    uint32_t secondary_count;
    /* PANCAKE_CARRIER_PHASE_* or NONE. */
    uint32_t carrier_phase;
    /* PANCAKE_CARRIER_DETAIL_* presence bits. */
    uint32_t carrier_detail_flags;
    /* Neutral certificate-verification flags; zero when unavailable. */
    uint32_t carrier_verification_flags;
    /* Peer TLS alert byte when its presence bit is set. */
    uint32_t carrier_peer_alert;
    /* Private engine failure code when its presence bit is set. */
    int32_t carrier_engine_code;
    /* Borrowed process-lifetime primary failure name. */
    const uint8_t *primary_name;
    size_t primary_name_len;
    /* Borrowed process-lifetime first consequence name. */
    const uint8_t *secondary_name;
    size_t secondary_name_len;
} PancakeDriverFailure;

typedef struct PancakeDriverEvent {
    /* PANCAKE_DRIVER_EVENT_*. */
    uint32_t kind;
    /* Stable PANCAKE_ERR_* primary result for failure events; PANCAKE_OK otherwise. */
    int32_t primary_result;
    /* Stable PANCAKE_ERR_* first consequence, or PANCAKE_OK. */
    int32_t secondary_result;
    /* Total observed consequences. */
    uint32_t secondary_count;
    /* PANCAKE_CARRIER_PHASE_* or NONE. */
    uint32_t carrier_phase;
    /* PANCAKE_CARRIER_DETAIL_* presence bits. */
    uint32_t carrier_detail_flags;
    /* Neutral certificate-verification flags; zero when unavailable. */
    uint32_t carrier_verification_flags;
    /* Peer TLS alert byte when its presence bit is set. */
    uint32_t carrier_peer_alert;
    /* Private engine failure code when its presence bit is set. */
    int32_t carrier_engine_code;
    /* OPENED or OPEN_FAILED operation id. */
    uint64_t operation_id;
    /* Listener identity for listener events and ACCEPTED. */
    uint64_t listener_id;
    /* OPENED, ACCEPTED, or SESSION_CLOSED session. */
    PancakeHostSession *session;
    /* COMPLETION action. */
    PancakeHostAction action;
    /* Borrowed primary failure name. */
    const uint8_t *primary_name;
    size_t primary_name_len;
    /* Borrowed first consequence name. */
    const uint8_t *secondary_name;
    size_t secondary_name_len;
} PancakeDriverEvent;

/* Move a quiescent Host into a transport loop. Failure leaves Host ownership
   unchanged. Success transfers transport execution, action draining, session
   release, and terminal Host release to the loop. The loop starts with no
   transports; add provider packages before dial or listen. The options layout
   must be recognized; buffer and admission limits must be positive, while zero
   wait budgets select an unbounded wait. Release only through
   pancake_driver_release. */
int32_t pancake_driver_take_host(PancakeHost *host, const PancakeDriverOptions *options, PancakeDriverLoop **out_loop);
/* Seal admission, stop listeners, and begin or escalate one terminal close
   barrier without blocking. CANCEL interrupts admitted opens and closes sessions.
   FINISH drives admitted opens, vows, and deferred answers under the explicit
   finite or unbounded grace choice. Continue pancake_driver_step and drain events
   until pancake_driver_lifecycle_state reports PANCAKE_LIFECYCLE_CLOSED. This
   closes without releasing the loop handle. */
int32_t pancake_driver_close(PancakeDriverLoop *loop, const PancakeCloseOptions *options);
/* Stop listener admission and retire the loop after every application-owned
   session handle releases. Existing sessions remain active; the final release
   begins cancel close. Continue stepping until lifecycle state reports CLOSED. */
int32_t pancake_driver_retire(PancakeDriverLoop *loop);
/* Write the current PANCAKE_LIFECYCLE_* state. CLOSED is withheld until the runtime
   has retired its execution state and queued events have been drained. After finite
   grace expiry, teardown escalates to CANCEL and this returns PANCAKE_ERR_TIMEOUT
   together with CLOSED. */
int32_t pancake_driver_lifecycle_state(PancakeDriverLoop *loop, uint32_t *out_state);
/* The longest a nonblocking embedder may park on the readiness descriptor before
   calling pancake_driver_step again with a zero timeout: milliseconds until the
   nearest pending-work deadline (the close grace, a session's close grace, a dial
   or listener setup budget), clamped at zero, or -1 when no finite deadline is
   pending and readiness alone advances the loop. The value drops straight into a
   wait primitive's timeout argument. */
int32_t pancake_driver_step_wait_ms(PancakeDriverLoop *loop, int32_t *out_wait_ms);
/* Release listeners, wires, events, provider adapters, and the moved Host.
   out_failure must identify the current version/layout before the call. NULL loop is
   a no-op. Invalid output or reentry refuses before consumption; every other
   result consumes the handle and returns the exact teardown chain in out_failure. */
int32_t pancake_driver_release(PancakeDriverLoop *loop, PancakeDriverFailure *out_failure);
/* Install one validated provider package. out_failure must identify the current
   version/layout and receives the exact primary and rollback chain. The driver
   acquires the native lease through provider.retain, copies profiles and tables,
   and calls provider.release after every listener, connection, and callback retires. */
int32_t pancake_driver_add_provider(PancakeDriverLoop *loop, const PancakeTransportProvider *provider, PancakeDriverFailure *out_failure);
/* Report whether one installed provider owns the transport symbol. */
int32_t pancake_driver_has_transport(PancakeDriverLoop *loop, const uint8_t *transport, size_t transport_len, uint8_t *out_present);
/* Begin a non-blocking dial from one borrowed locator view. Null options inherit
   provider defaults; a payload is interpreted only by the selected provider.
   Pre-admission failures return directly and mint no operation id. After admission,
   transport completion and the CapTP handshake advance through step; OPENED or
   OPEN_FAILED carries the returned operation id. */
int32_t pancake_driver_dial(PancakeDriverLoop *loop, const PancakeLocatorView *locator, const PancakeTransportOperationOptions *options, uint64_t *out_operation_id);
/* Begin adoption of one externally established provider connection. Pre-admission failures return directly and mint no operation id. The subject is interpreted only by the provider registered under transport. role selects the Host/session half; after admission, OPENED or OPEN_FAILED carries the returned operation id. */
int32_t pancake_driver_adopt_external(PancakeDriverLoop *loop, const uint8_t *transport, size_t transport_len, uint64_t subject, uint32_t role, uint64_t *out_operation_id);
/* Begin listener construction through a registered provider. Null options inherit
   provider defaults; a payload is interpreted only by the selected provider.
   LISTENER_READY or LISTENER_FAILED carries the returned stable listener id;
   ACCEPTED uses the same id. */
int32_t pancake_driver_listen(PancakeDriverLoop *loop, const uint8_t *transport, size_t transport_len, const uint8_t *designator, size_t designator_len, const PancakeTransportOperationOptions *options, uint64_t *out_listener);
/* Borrow the active listener's complete locator view until it is advertised
   again, closed, or its loop is released. Clone through libpancake_ocapn to retain it. */
int32_t pancake_driver_listener_locator(PancakeDriverLoop *loop, uint64_t listener, PancakeLocatorView *out_locator);
/* Query or copy opaque transport-owned state sufficient to restore this listener's local address. A null/zero output queries the exact size; a short buffer is untouched. Treat returned bytes as sensitive provider vocabulary, never as locator data. */
int32_t pancake_driver_listener_restoration_state(PancakeDriverLoop *loop, uint64_t listener, uint8_t *out, size_t cap, size_t *out_len);
/* Replace an active listener's complete advertised locator from a borrowed
   view while preserving its transport and identity posture. The loop clones the
   value before returning. */
int32_t pancake_driver_listener_advertise(PancakeDriverLoop *loop, uint64_t listener, const PancakeLocatorView *locator);
/* Select this listener locator as the Host's acceptable location. */
int32_t pancake_driver_listener_select(PancakeDriverLoop *loop, uint64_t listener);
/* Stop one listener and remove its advertised locator without releasing the
   loop or accepted session handles. PANCAKE_ERR_WOULD_BLOCK means stop is committed
   but still pending: keep stepping, then retry after successful retirement or
   consume LISTENER_FAILED for the exact asynchronous chain. out_failure must
   identify the current version/layout and receives a synchronous stop/cancellation
   chain. */
int32_t pancake_driver_listener_close(PancakeDriverLoop *loop, uint64_t listener, PancakeDriverFailure *out_failure);
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
/* Resolve a live remote capability's exporter session and ensure the loop's one
   application-owned handle claims it before returning. A local, stale, foreign-Host,
   or closed-session capability writes NULL. Repeated calls return the same handle. */
int32_t pancake_driver_claim_reference_exporter(PancakeDriverLoop *loop, const PancakeReference *reference, PancakeHostSession **out_session);
/* Seal one loop-owned session's application admission and begin or escalate its
   nonblocking close barrier. Continue stepping until
   pancake_driver_session_lifecycle_state reports PANCAKE_LIFECYCLE_CLOSED. This
   closes without releasing the session handle. */
int32_t pancake_driver_session_close(PancakeDriverLoop *loop, PancakeHostSession *session, const PancakeCloseOptions *options);
/* Write one loop-owned session's PANCAKE_LIFECYCLE_* phase. CLOSED means the
   transport is closed while the handle remains valid for explicit release. A finite
   finish grace expiry returns PANCAKE_ERR_TIMEOUT together with CLOSED. */
int32_t pancake_driver_session_lifecycle_state(PancakeDriverLoop *loop, PancakeHostSession *session, uint32_t *out_state);
/* Begin delivering this session's inbound application frames: the embedder has
   finished its post-open setup (publishes, spawns), so a partner's pipelined
   first frames can no longer outrun the objects they name. A session surfaced
   by an OPENED or ACCEPTED event holds its inbound until this call; handshake
   frames were never held, and early bytes wait unread and replay in order now.
   Idempotent. Every binding runtime calls this from its serve path. */
int32_t pancake_driver_session_serve(PancakeDriverLoop *loop, PancakeHostSession *session);
/* Release one loop-owned session and its wire. */
int32_t pancake_driver_session_release(PancakeDriverLoop *loop, PancakeHostSession *session);
/* Query or copy this archive's thread-local error message. Every status-returning call clears the slot before validation; read it immediately after a failing call, and treat zero length as no additional detail. */
size_t pancake_driver_last_error(uint8_t *out_buf, size_t cap);
/* Clear this archive's thread-local error message. */
void pancake_driver_clear_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* PANCAKE_DRIVER_H */
