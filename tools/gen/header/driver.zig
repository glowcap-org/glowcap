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
    "pancake_driver_release",
    "pancake_driver_add_provider",
    "pancake_driver_has_transport",
    "pancake_driver_dial",
    "pancake_driver_adopt_external",
    "pancake_driver_listen",
    "pancake_driver_listener_locator",
    "pancake_driver_listener_advertise",
    "pancake_driver_listener_select",
    "pancake_driver_listener_close",
    "pancake_driver_readiness_fd",
    "pancake_driver_step",
    "pancake_driver_detach_thread",
    "pancake_driver_wake",
    "pancake_driver_next_event",
    "pancake_driver_session_release",
    "pancake_driver_last_error",
    "pancake_driver_clear_last_error",
};

const Spec = struct {
    pub const c = cd;
    pub const emitted_fns: []const []const u8 = &emitted_fn_names;
    pub const const_docs = [_]struct { name: []const u8, doc: []const u8 }{
        .{ .name = "PANCAKE_DRIVER_OPTIONS_ABI_VERSION", .doc = "PancakeDriverOptions.abi_version." },
        .{ .name = "PANCAKE_DRIVER_MAX_WAIT_MS", .doc = "Largest handshake_ms or settle_ms value." },
        .{ .name = "PANCAKE_DRIVER_DEFAULT_WIRE_BUFFER_BYTES", .doc = "Default PancakeDriverOptions.wire_buffer_bytes." },
        .{ .name = "PANCAKE_DRIVER_DEFAULT_MAX_PENDING_OPENS", .doc = "Default PancakeDriverOptions.max_pending_opens." },
        .{ .name = "PANCAKE_DRIVER_DEFAULT_HANDSHAKE_MS", .doc = "Default PancakeDriverOptions.handshake_ms." },
        .{ .name = "PANCAKE_DRIVER_DEFAULT_SETTLE_MS", .doc = "Default PancakeDriverOptions.settle_ms." },
        .{ .name = "PANCAKE_DRIVER_EVENT_OPENED", .doc = "PancakeDriverEvent.kind: ticketed dial or external adoption reached an open session." },
        .{ .name = "PANCAKE_DRIVER_EVENT_OPEN_FAILED", .doc = "PancakeDriverEvent.kind: ticketed dial or external adoption failed; message carries the reason." },
        .{ .name = "PANCAKE_DRIVER_EVENT_ACCEPTED", .doc = "PancakeDriverEvent.kind: listener accepted session." },
        .{ .name = "PANCAKE_DRIVER_EVENT_SESSION_CLOSED", .doc = "PancakeDriverEvent.kind: session wire closed; release the handle through the driver." },
        .{ .name = "PANCAKE_DRIVER_EVENT_COMPLETION", .doc = "PancakeDriverEvent.kind: action carries a settled or failed vow." },
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
    std.debug.assert(cd.PANCAKE_DRIVER_ADOPT_DIALED == 0);
    std.debug.assert(cd.PANCAKE_DRIVER_ADOPT_ACCEPTED == 1);
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
        "PANCAKE_DRIVER_MAX_WAIT_MS",
        "PANCAKE_DRIVER_DEFAULT_WIRE_BUFFER_BYTES",
        "PANCAKE_DRIVER_DEFAULT_MAX_PENDING_OPENS",
        "PANCAKE_DRIVER_DEFAULT_HANDSHAKE_MS",
        "PANCAKE_DRIVER_DEFAULT_SETTLE_MS",
        "PANCAKE_DRIVER_EVENT_OPENED",
        "PANCAKE_DRIVER_EVENT_OPEN_FAILED",
        "PANCAKE_DRIVER_EVENT_ACCEPTED",
        "PANCAKE_DRIVER_EVENT_SESSION_CLOSED",
        "PANCAKE_DRIVER_EVENT_COMPLETION",
        "PANCAKE_DRIVER_ADOPT_DIALED",
        "PANCAKE_DRIVER_ADOPT_ACCEPTED",
    }) |name| try E.emitConst(&b, gpa, name);
    try b.appendSlice(gpa, "\n");
    try E.emitStruct(&b, gpa, cd.PancakeDriverOptions, "PancakeDriverOptions", &.{
        "PANCAKE_DRIVER_OPTIONS_ABI_VERSION.",
        "sizeof(PancakeDriverOptions).",
        "Retained bytes per stream direction, or per multiplexed read staging buffer.",
        "Maximum transport connects and CapTP handshakes admitted at once.",
        "Handshake progress budget in milliseconds.",
        "Application-answer progress budget in milliseconds.",
    });
    try b.appendSlice(gpa, "\n");
    try E.emitStruct(&b, gpa, cd.PancakeDriverEvent, "PancakeDriverEvent", &.{
        "PANCAKE_DRIVER_EVENT_*.",                      "Open ticket or listener id.",
        "OPENED, ACCEPTED, or SESSION_CLOSED session.", "COMPLETION action.",
        "Borrowed OPEN_FAILED message.",                "",
    });
    try b.appendSlice(gpa, "\n");

    try E.emitFn(&b, gpa, "pancake_driver_take_host", &.{ "host", "options", "out_loop" }, "Move a quiescent Host into a transport loop. Failure leaves Host ownership\nunchanged. Success transfers transport execution, action draining, session\nrelease, and terminal Host release to the loop. The loop starts with no\ntransports; add provider packages before dial or listen. The options layout\nmust be recognized and every policy value positive. Release only through\npancake_driver_release.");
    try E.emitFn(&b, gpa, "pancake_driver_release", &.{"loop"}, "Release listeners, wires, events, provider adapters, and the moved Host.\nNULL is a no-op; refused inside a callback.");
    try E.emitFn(&b, gpa, "pancake_driver_add_provider", &.{ "loop", "provider" }, "Install one validated provider package. The driver acquires its native lease\nthrough provider.retain, copies profiles and implementation tables, and calls\nprovider.release only after every listener, connection, and callback has retired.\nThe provider lease, not a binding-side owner, keeps the transport context alive.");
    try E.emitFn(&b, gpa, "pancake_driver_has_transport", &.{ "loop", "transport", "transport_len", "out_present" }, "Report whether one installed provider owns the transport symbol.");
    try E.emitFn(&b, gpa, "pancake_driver_dial", &.{ "loop", "locator", "out_ticket" }, "Begin a non-blocking dial from one borrowed locator view. Pre-admission failures\nreturn directly and mint no ticket. After admission, transport completion and\nthe CapTP handshake advance through step; OPENED or OPEN_FAILED carries the\nreturned ticket.");
    try E.emitFn(&b, gpa, "pancake_driver_adopt_external", &.{ "loop", "transport", "transport_len", "subject", "role", "out_ticket" }, "Begin adoption of one externally established provider connection. Pre-admission failures return directly and mint no ticket. The subject is interpreted only by the provider registered under transport. role selects the Host/session half; after admission, OPENED or OPEN_FAILED carries the returned ticket.");
    try E.emitFn(&b, gpa, "pancake_driver_listen", &.{ "loop", "transport", "transport_len", "designator", "designator_len", "out_listener" }, "Bind through a registered listener-capable provider. ACCEPTED events carry\nthe returned listener id.");
    try E.emitFn(&b, gpa, "pancake_driver_listener_locator", &.{ "loop", "listener", "out_locator" }, "Borrow the active listener's complete locator view until it is advertised\nagain, closed, or its loop is released. Clone through libpancake_ocapn to retain it.");
    try E.emitFn(&b, gpa, "pancake_driver_listener_advertise", &.{ "loop", "listener", "locator" }, "Replace an active listener's complete advertised locator from a borrowed\nview while preserving its transport and identity posture. The loop clones the\nvalue before returning.");
    try E.emitFn(&b, gpa, "pancake_driver_listener_select", &.{ "loop", "listener" }, "Select this listener locator as the Host's acceptable location.");
    try E.emitFn(&b, gpa, "pancake_driver_listener_close", &.{ "loop", "listener" }, "Stop one listener and remove its advertised locator without releasing the\nloop or accepted session handles.");
    try E.emitFn(&b, gpa, "pancake_driver_readiness_fd", &.{ "loop", "out_fd" }, "Return the loop-owned descriptor on which the embedder parks.");
    try E.emitFn(&b, gpa, "pancake_driver_step", &.{ "loop", "timeout_ms" }, "Advance listeners, in-flight opens, wires, Host actions, and handshakes.\nPANCAKE_OK means immediate work was observed or an event remains queued;\nPANCAKE_ERR_WOULD_BLOCK means the loop is drained after the requested wait.\nEdge-triggered embedders call until WOULD_BLOCK before clearing readiness.\nDrain events after every call that returns PANCAKE_OK.");
    try E.emitFn(&b, gpa, "pancake_driver_detach_thread", &.{"loop"}, "End the current thread's exclusive claim at a quiescent handoff boundary.");
    try E.emitFn(&b, gpa, "pancake_driver_wake", &.{"loop"}, "Wake a parked loop from any thread.");
    try E.emitFn(&b, gpa, "pancake_driver_next_event", &.{ "loop", "out" }, "Pop one event, or PANCAKE_ERR_WOULD_BLOCK. Borrowed views last until the\nnext pop.");
    try E.emitFn(&b, gpa, "pancake_driver_session_release", &.{ "loop", "session" }, "Release one loop-owned session and its wire.");
    try E.emitFn(&b, gpa, "pancake_driver_last_error", &.{ "out_buf", "cap" }, "Query or copy this archive's thread-local error message.");
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
