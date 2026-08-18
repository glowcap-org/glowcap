//! Generates `include/pancake_driver.h` from the driver C ABI.

const std = @import("std");
const cd = @import("c_abi_driver");
const header_emit = @import("header_emit.zig");

const Output = @import("output").Output;
pub const outputs = [_]Output{
    .{ .path = "include/pancake_driver.h", .generate = generate },
};
pub const step_name = "gen-header-driver";

const emitted_fn_names = [_][]const u8{
    "pancake_driver_take_host",
    "pancake_driver_close",
    "pancake_driver_retire",
    "pancake_driver_lifecycle_state",
    "pancake_driver_step_wait_ms",
    "pancake_driver_release",
    "pancake_driver_add_provider",
    "pancake_driver_has_transport",
    "pancake_driver_dial",
    "pancake_driver_adopt_external",
    "pancake_driver_listen",
    "pancake_driver_listener_locator",
    "pancake_driver_listener_restoration_state",
    "pancake_driver_listener_advertise",
    "pancake_driver_listener_select",
    "pancake_driver_listener_close",
    "pancake_driver_readiness_fd",
    "pancake_driver_step",
    "pancake_driver_detach_thread",
    "pancake_driver_wake",
    "pancake_driver_next_event",
    "pancake_driver_claim_reference_exporter",
    "pancake_driver_session_close",
    "pancake_driver_session_lifecycle_state",
    "pancake_driver_session_serve",
    "pancake_driver_session_release",
    "pancake_driver_last_error",
    "pancake_driver_clear_last_error",
};

const Spec = struct {
    pub const c = cd;
    pub const emitted_fns: []const []const u8 = &emitted_fn_names;
    pub const const_docs = [_]struct { name: []const u8, doc: []const u8 }{
        .{ .name = "PANCAKE_DRIVER_OPTIONS_ABI_VERSION", .doc = "PancakeDriverOptions.abi_version." },
        .{ .name = "PANCAKE_DRIVER_FAILURE_ABI_VERSION", .doc = "PancakeDriverFailure.abi_version." },
        .{ .name = "PANCAKE_DRIVER_MAX_WAIT_MS", .doc = "Largest handshake_ms or settle_ms value." },
        .{ .name = "PANCAKE_DRIVER_DEFAULT_WIRE_BUFFER_BYTES", .doc = "Default PancakeDriverOptions.wire_buffer_bytes." },
        .{ .name = "PANCAKE_DRIVER_DEFAULT_MAX_PENDING_OPENS", .doc = "Default PancakeDriverOptions.max_pending_opens." },
        .{ .name = "PANCAKE_DRIVER_DEFAULT_HANDSHAKE_MS", .doc = "Default PancakeDriverOptions.handshake_ms." },
        .{ .name = "PANCAKE_DRIVER_DEFAULT_LISTENER_SETUP_MS", .doc = "Default PancakeDriverOptions.listener_setup_ms." },
        .{ .name = "PANCAKE_DRIVER_DEFAULT_SETTLE_MS", .doc = "Default PancakeDriverOptions.settle_ms." },
        .{ .name = "PANCAKE_DRIVER_EVENT_OPENED", .doc = "PancakeDriverEvent.kind: dial or external adoption reached an open session." },
        .{ .name = "PANCAKE_DRIVER_EVENT_OPEN_FAILED", .doc = "PancakeDriverEvent.kind: dial or external adoption failed; failure fields carry the typed chain." },
        .{ .name = "PANCAKE_DRIVER_EVENT_ACCEPTED", .doc = "PancakeDriverEvent.kind: listener accepted session." },
        .{ .name = "PANCAKE_DRIVER_EVENT_SESSION_CLOSED", .doc = "PancakeDriverEvent.kind: session wire closed; failure fields carry a fault, or PANCAKE_OK for clean EOF." },
        .{ .name = "PANCAKE_DRIVER_EVENT_COMPLETION", .doc = "PancakeDriverEvent.kind: action carries a settled or failed vow." },
        .{ .name = "PANCAKE_DRIVER_EVENT_LISTENER_READY", .doc = "PancakeDriverEvent.kind: listener construction completed." },
        .{ .name = "PANCAKE_DRIVER_EVENT_LISTENER_FAILED", .doc = "PancakeDriverEvent.kind: listener construction or active accept infrastructure failed; the listener id is retired." },
        .{ .name = "PANCAKE_DRIVER_ADOPT_DIALED", .doc = "pancake_driver_adopt_external role: use the dialed Host/session half." },
        .{ .name = "PANCAKE_DRIVER_ADOPT_ACCEPTED", .doc = "pancake_driver_adopt_external role: use the accepted Host/session half." },
    };
    pub fn special(comptime T: type) ?[]const u8 {
        _ = T;
        return null;
    }
};

const E = header_emit.Emit(Spec);

comptime {
    E.guardFns("c_abi_driver", "pancake_driver_");
    std.debug.assert(cd.PANCAKE_DRIVER_EVENT_OPENED == 0);
    std.debug.assert(cd.PANCAKE_DRIVER_EVENT_OPEN_FAILED == 1);
    std.debug.assert(cd.PANCAKE_DRIVER_EVENT_ACCEPTED == 2);
    std.debug.assert(cd.PANCAKE_DRIVER_EVENT_SESSION_CLOSED == 3);
    std.debug.assert(cd.PANCAKE_DRIVER_EVENT_COMPLETION == 4);
    std.debug.assert(cd.PANCAKE_DRIVER_EVENT_LISTENER_READY == 5);
    std.debug.assert(cd.PANCAKE_DRIVER_EVENT_LISTENER_FAILED == 6);
    std.debug.assert(cd.PANCAKE_DRIVER_ADOPT_DIALED == 0);
    std.debug.assert(cd.PANCAKE_DRIVER_ADOPT_ACCEPTED == 1);
    std.debug.assert(cd.PANCAKE_CLOSE_GRACE_UNSPECIFIED == 0);
    std.debug.assert(cd.PANCAKE_CLOSE_GRACE_FINITE == 1);
    std.debug.assert(cd.PANCAKE_CLOSE_GRACE_UNBOUNDED == 2);
}

fn generate(gpa: std.mem.Allocator) ![]u8 {
    var b: header_emit.Buf = .empty;
    errdefer b.deinit(gpa);
    try b.appendSlice(gpa,
        \\/* Generated from src/c_abi/driver/mod.zig by tools/gen/header/driver.zig.
        \\   Do not edit by hand: run `zig build gen-header-driver`.
        \\   libpancake_driver exports only pancake_driver_*; compose it with
        \\   libpancake_host and the transport archives selected by the application. */
        \\#ifndef PANCAKE_DRIVER_H
        \\#define PANCAKE_DRIVER_H
        \\
        \\#include <stddef.h>
        \\#include <stdint.h>
        \\#include "pancake_host.h"
        \\#include "pancake_transport_provider.h"
        \\
        \\#ifdef __cplusplus
        \\extern "C" {
        \\#endif
        \\
        \\/* A stepping CapTP loop over one Host moved into pancake_driver_take_host.
        \\   The driver owns that Host after a successful move. */
        \\typedef struct PancakeDriverLoop PancakeDriverLoop;
        \\
    );
    inline for (.{
        "PANCAKE_DRIVER_OPTIONS_ABI_VERSION",
        "PANCAKE_DRIVER_FAILURE_ABI_VERSION",
        "PANCAKE_DRIVER_MAX_WAIT_MS",
        "PANCAKE_DRIVER_DEFAULT_WIRE_BUFFER_BYTES",
        "PANCAKE_DRIVER_DEFAULT_MAX_PENDING_OPENS",
        "PANCAKE_DRIVER_DEFAULT_HANDSHAKE_MS",
        "PANCAKE_DRIVER_DEFAULT_LISTENER_SETUP_MS",
        "PANCAKE_DRIVER_DEFAULT_SETTLE_MS",
        "PANCAKE_DRIVER_EVENT_OPENED",
        "PANCAKE_DRIVER_EVENT_OPEN_FAILED",
        "PANCAKE_DRIVER_EVENT_ACCEPTED",
        "PANCAKE_DRIVER_EVENT_SESSION_CLOSED",
        "PANCAKE_DRIVER_EVENT_COMPLETION",
        "PANCAKE_DRIVER_EVENT_LISTENER_READY",
        "PANCAKE_DRIVER_EVENT_LISTENER_FAILED",
        "PANCAKE_DRIVER_ADOPT_DIALED",
        "PANCAKE_DRIVER_ADOPT_ACCEPTED",
    }) |name| try E.emitConst(&b, gpa, name);
    try b.appendSlice(gpa, "\n");
    try E.emitStruct(&b, gpa, cd.PancakeDriverOptions, "PancakeDriverOptions", &.{
        "PANCAKE_DRIVER_OPTIONS_ABI_VERSION.",
        "sizeof(PancakeDriverOptions).",
        "Retained bytes per stream direction, or per multiplexed read staging buffer.",
        "Maximum transport connects and CapTP handshakes admitted at once.",
        "Handshake progress budget in milliseconds; zero waits without a bound.",
        "Listener-construction progress budget in milliseconds; zero waits without a bound.",
        "Application-answer progress budget in milliseconds; zero waits without a bound.",
    });
    try b.appendSlice(gpa, "\n");
    try E.emitStruct(&b, gpa, cd.PancakeDriverFailure, "PancakeDriverFailure", &.{
        "PANCAKE_DRIVER_FAILURE_ABI_VERSION.",
        "sizeof(PancakeDriverFailure).",
        "Stable PANCAKE_ERR_* primary result; PANCAKE_OK on success.",
        "Stable PANCAKE_ERR_* first consequence; PANCAKE_OK when absent.",
        "Total observed consequences.",
        "PANCAKE_CARRIER_PHASE_* or NONE.",
        "PANCAKE_CARRIER_DETAIL_* presence bits.",
        "Neutral certificate-verification flags; zero when unavailable.",
        "Peer TLS alert byte when its presence bit is set.",
        "Private engine failure code when its presence bit is set.",
        "Borrowed process-lifetime primary failure name.",
        "",
        "Borrowed process-lifetime first consequence name.",
        "",
    });
    try b.appendSlice(gpa, "\n");
    try E.emitStruct(&b, gpa, cd.PancakeDriverEvent, "PancakeDriverEvent", &.{
        "PANCAKE_DRIVER_EVENT_*.",
        "Stable PANCAKE_ERR_* primary result for failure events; PANCAKE_OK otherwise.",
        "Stable PANCAKE_ERR_* first consequence, or PANCAKE_OK.",
        "Total observed consequences.",
        "PANCAKE_CARRIER_PHASE_* or NONE.",
        "PANCAKE_CARRIER_DETAIL_* presence bits.",
        "Neutral certificate-verification flags; zero when unavailable.",
        "Peer TLS alert byte when its presence bit is set.",
        "Private engine failure code when its presence bit is set.",
        "OPENED or OPEN_FAILED operation id.",
        "Listener identity for listener events and ACCEPTED.",
        "OPENED, ACCEPTED, or SESSION_CLOSED session.",
        "COMPLETION action.",
        "Borrowed primary failure name.",
        "",
        "Borrowed first consequence name.",
        "",
    });
    try b.appendSlice(gpa, "\n");

    try E.emitFn(&b, gpa, "pancake_driver_take_host", &.{ "host", "options", "out_loop" }, "Move a quiescent Host into a transport loop. Failure leaves Host ownership\nunchanged. Success transfers transport execution, action draining, session\nrelease, and terminal Host release to the loop. The loop starts with no\ntransports; add provider packages before dial or listen. The options layout\nmust be recognized; buffer and admission limits must be positive, while zero\nwait budgets select an unbounded wait. Release only through\npancake_driver_release.");
    try E.emitFn(&b, gpa, "pancake_driver_close", &.{ "loop", "options" }, "Seal admission, stop listeners, and begin or escalate one terminal close\nbarrier without blocking. CANCEL interrupts admitted opens and closes sessions.\nFINISH drives admitted opens, vows, and deferred answers under the explicit\nfinite or unbounded grace choice. Continue pancake_driver_step and drain events\nuntil pancake_driver_lifecycle_state reports PANCAKE_LIFECYCLE_CLOSED. This\ncloses without releasing the loop handle.");
    try E.emitFn(&b, gpa, "pancake_driver_retire", &.{"loop"}, "Stop listener admission and retire the loop after every application-owned\nsession handle releases. Existing sessions remain active; the final release\nbegins cancel close. Continue stepping until lifecycle state reports CLOSED.");
    try E.emitFn(&b, gpa, "pancake_driver_lifecycle_state", &.{ "loop", "out_state" }, "Write the current PANCAKE_LIFECYCLE_* state. CLOSED is withheld until the runtime\nhas retired its execution state and queued events have been drained. After finite\ngrace expiry, teardown escalates to CANCEL and this returns PANCAKE_ERR_TIMEOUT\ntogether with CLOSED.");
    try E.emitFn(&b, gpa, "pancake_driver_step_wait_ms", &.{ "loop", "out_wait_ms" }, "The longest a nonblocking embedder may park on the readiness descriptor before\ncalling pancake_driver_step again with a zero timeout: milliseconds until the\nnearest pending-work deadline (the close grace, a session's close grace, a dial\nor listener setup budget), clamped at zero, or -1 when no finite deadline is\npending and readiness alone advances the loop. The value drops straight into a\nwait primitive's timeout argument.");
    try E.emitFn(&b, gpa, "pancake_driver_release", &.{ "loop", "out_failure" }, "Release listeners, wires, events, provider adapters, and the moved Host.\nout_failure must identify the current version/layout before the call. NULL loop is\na no-op. Invalid output or reentry refuses before consumption; every other\nresult consumes the handle and returns the exact teardown chain in out_failure.");
    try E.emitFn(&b, gpa, "pancake_driver_add_provider", &.{ "loop", "provider", "out_failure" }, "Install one validated provider package. out_failure must identify the current\nversion/layout and receives the exact primary and rollback chain. The driver\nacquires the native lease through provider.retain, copies profiles and tables,\nand calls provider.release after every listener, connection, and callback retires.");
    try E.emitFn(&b, gpa, "pancake_driver_has_transport", &.{ "loop", "transport", "transport_len", "out_present" }, "Report whether one installed provider owns the transport symbol.");
    try E.emitFn(&b, gpa, "pancake_driver_dial", &.{ "loop", "locator", "options", "out_operation_id" }, "Begin a non-blocking dial from one borrowed locator view. Null options inherit\nprovider defaults; a payload is interpreted only by the selected provider.\nPre-admission failures return directly and mint no operation id. After admission,\ntransport completion and the CapTP handshake advance through step; OPENED or\nOPEN_FAILED carries the returned operation id.");
    try E.emitFn(&b, gpa, "pancake_driver_adopt_external", &.{ "loop", "transport", "transport_len", "subject", "role", "out_operation_id" }, "Begin adoption of one externally established provider connection. Pre-admission failures return directly and mint no operation id. The subject is interpreted only by the provider registered under transport. role selects the Host/session half; after admission, OPENED or OPEN_FAILED carries the returned operation id.");
    try E.emitFn(&b, gpa, "pancake_driver_listen", &.{ "loop", "transport", "transport_len", "designator", "designator_len", "options", "out_listener" }, "Begin listener construction through a registered provider. Null options inherit\nprovider defaults; a payload is interpreted only by the selected provider.\nLISTENER_READY or LISTENER_FAILED carries the returned stable listener id;\nACCEPTED uses the same id.");
    try E.emitFn(&b, gpa, "pancake_driver_listener_locator", &.{ "loop", "listener", "out_locator" }, "Borrow the active listener's complete locator view until it is advertised\nagain, closed, or its loop is released. Clone through libpancake_ocapn to retain it.");
    try E.emitFn(&b, gpa, "pancake_driver_listener_restoration_state", &.{ "loop", "listener", "out", "cap", "out_len" }, "Query or copy opaque transport-owned state sufficient to restore this listener's local address. A null/zero output queries the exact size; a short buffer is untouched. Treat returned bytes as sensitive provider vocabulary, never as locator data.");
    try E.emitFn(&b, gpa, "pancake_driver_listener_advertise", &.{ "loop", "listener", "locator" }, "Replace an active listener's complete advertised locator from a borrowed\nview while preserving its transport and identity posture. The loop clones the\nvalue before returning.");
    try E.emitFn(&b, gpa, "pancake_driver_listener_select", &.{ "loop", "listener" }, "Select this listener locator as the Host's acceptable location.");
    try E.emitFn(&b, gpa, "pancake_driver_listener_close", &.{ "loop", "listener", "out_failure" }, "Stop one listener and remove its advertised locator without releasing the\nloop or accepted session handles. out_failure must identify the current\nversion/layout and receives the exact stop/cancellation and cleanup chain.");
    try E.emitFn(&b, gpa, "pancake_driver_readiness_fd", &.{ "loop", "out_fd" }, "Return the loop-owned descriptor on which the embedder parks.");
    try E.emitFn(&b, gpa, "pancake_driver_step", &.{ "loop", "timeout_ms" }, "Advance listeners, in-flight opens, wires, Host actions, and handshakes.\nPANCAKE_OK means immediate work was observed or an event remains queued;\nPANCAKE_ERR_WOULD_BLOCK means the loop is drained after the requested wait.\nEdge-triggered embedders call until WOULD_BLOCK before clearing readiness.\nDrain events after every call that returns PANCAKE_OK.");
    try E.emitFn(&b, gpa, "pancake_driver_detach_thread", &.{"loop"}, "End the current thread's exclusive claim at a quiescent handoff boundary.");
    try E.emitFn(&b, gpa, "pancake_driver_wake", &.{"loop"}, "Wake a parked loop from any thread.");
    try E.emitFn(&b, gpa, "pancake_driver_next_event", &.{ "loop", "out" }, "Pop one event, or PANCAKE_ERR_WOULD_BLOCK. Borrowed views last until the\nnext pop.");
    try E.emitFn(&b, gpa, "pancake_driver_claim_reference_exporter", &.{ "loop", "reference", "out_session" }, "Resolve a live remote capability's exporter session and ensure the loop's one\napplication-owned handle claims it before returning. A local, stale, foreign-Host,\nor closed-session capability writes NULL. Repeated calls return the same handle.");
    try E.emitFn(&b, gpa, "pancake_driver_session_close", &.{ "loop", "session", "options" }, "Seal one loop-owned session's application admission and begin or escalate its\nnonblocking close barrier. Continue stepping until\npancake_driver_session_lifecycle_state reports PANCAKE_LIFECYCLE_CLOSED. This\ncloses without releasing the session handle.");
    try E.emitFn(&b, gpa, "pancake_driver_session_lifecycle_state", &.{ "loop", "session", "out_state" }, "Write one loop-owned session's PANCAKE_LIFECYCLE_* phase. CLOSED means the\ntransport is closed while the handle remains valid for explicit release. A finite\nfinish grace expiry returns PANCAKE_ERR_TIMEOUT together with CLOSED.");
    try E.emitFn(&b, gpa, "pancake_driver_session_serve", &.{ "loop", "session" }, "Begin delivering this session's inbound application frames: the embedder has\nfinished its post-open setup (publishes, spawns), so a partner's pipelined\nfirst frames can no longer outrun the objects they name. A session surfaced\nby an OPENED or ACCEPTED event holds its inbound until this call; handshake\nframes were never held, and early bytes wait unread and replay in order now.\nIdempotent. Every binding runtime calls this from its serve path.");
    try E.emitFn(&b, gpa, "pancake_driver_session_release", &.{ "loop", "session" }, "Release one loop-owned session and its wire.");
    try E.emitFn(&b, gpa, "pancake_driver_last_error", &.{ "out_buf", "cap" }, "Query or copy this archive's thread-local error message." ++ header_emit.last_error_freshness_doc);
    try E.emitFn(&b, gpa, "pancake_driver_clear_last_error", &.{}, "Clear this archive's thread-local error message.");

    try b.appendSlice(gpa,
        \\
        \\#ifdef __cplusplus
        \\}
        \\#endif
        \\
        \\#endif /* PANCAKE_DRIVER_H */
        \\
    );
    try E.assertAllEmitted(&b, "gen-header-driver");
    return b.toOwnedSlice(gpa);
}
