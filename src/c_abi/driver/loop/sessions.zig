//! Own the loop C verbs for claiming, closing, serving, and releasing sessions.

const root = @import("../loop.zig");
const shared = @import("c_abi_shared");
const ch = @import("c_abi_host");
const c = @import("../mod.zig");

const Internal = root.Internal;
const Instance = Internal.Instance;
const GLOWCAP_OK = shared.GLOWCAP_OK;
const GLOWCAP_ERR_NULL_POINTER = shared.GLOWCAP_ERR_NULL_POINTER;
const instanceFrom = Internal.instanceFrom;
const errToCode = Internal.errToCode;
const reentrancyCode = @import("events.zig").reentrancyCode;

/// Resolve a live remote capability's exporter session and ensure that one
/// loop-owned application handle claims it before the pointer is returned.
/// Repeated calls for an already claimed session return the same handle.
/// Callback-safe: claiming does not drive I/O or dispatch another callback.
pub export fn glowcap_driver_claim_reference_exporter(
    raw: ?*c.GlowcapDriverLoop,
    reference: ?*const shared.GlowcapReference,
    out_session: ?*?*ch.GlowcapHostSession,
) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(raw) orelse return GLOWCAP_ERR_NULL_POINTER;
    if (!(inst.stepping and inst.runtime.withinCallback())) {
        if (reentrancyCode(inst, "claim_reference_exporter")) |code| return code;
    }
    const ref = reference orelse return GLOWCAP_ERR_NULL_POINTER;
    const slot = out_session orelse return GLOWCAP_ERR_NULL_POINTER;
    const session = inst.runtime.claimReferenceExporter(ref.id) catch |err| return errToCode(err);
    slot.* = if (session) |hs| ch.embedding.sessionHandle(hs) else null;
    return GLOWCAP_OK;
}

/// Claim the loop's single application handle for a borrowed exporter session.
/// The pointer must still be live and belong to this loop. This idempotent
/// ownership operation is callback-safe and performs no I/O or dispatch.
pub export fn glowcap_driver_claim_exporter_session(
    raw: ?*c.GlowcapDriverLoop,
    session: ?*ch.GlowcapHostSession,
) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(raw) orelse return GLOWCAP_ERR_NULL_POINTER;
    if (!(inst.stepping and inst.runtime.withinCallback())) {
        if (reentrancyCode(inst, "claim_exporter_session")) |code| return code;
    }
    const hs = ch.embedding.sessionFrom(session) orelse return GLOWCAP_ERR_NULL_POINTER;
    inst.runtime.claimExporterSession(hs) catch |err| return errToCode(err);
    return GLOWCAP_OK;
}

/// Seal one loop-owned session's admission and begin or escalate its native
/// close barrier without releasing the handle.
pub export fn glowcap_driver_session_close(
    raw: ?*c.GlowcapDriverLoop,
    session: ?*ch.GlowcapHostSession,
    options: ?*const ch.GlowcapCloseOptions,
) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(raw) orelse return GLOWCAP_ERR_NULL_POINTER;
    if (!(inst.stepping and inst.runtime.withinCallback())) {
        if (reentrancyCode(inst, "session_close")) |code| return code;
    }
    const hs = ch.embedding.sessionFrom(session) orelse return GLOWCAP_ERR_NULL_POINTER;
    const pending = ch.parseCloseOptions(options) catch |err| return ch.closeOptionsErrorCode("driver", err);
    inst.runtime.beginSessionClose(hs, pending) catch |err| return errToCode(err);
    return GLOWCAP_OK;
}

/// Observe one loop-owned session's native close barrier. CLOSED means its
/// transport is closed, while the handle remains valid for explicit release.
pub export fn glowcap_driver_session_lifecycle_state(
    raw: ?*c.GlowcapDriverLoop,
    session: ?*ch.GlowcapHostSession,
    out_state: ?*u32,
) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(raw) orelse return GLOWCAP_ERR_NULL_POINTER;
    if (reentrancyCode(inst, "session_lifecycle_state")) |code| return code;
    const hs = ch.embedding.sessionFrom(session) orelse return GLOWCAP_ERR_NULL_POINTER;
    const slot = out_state orelse return GLOWCAP_ERR_NULL_POINTER;
    const status = inst.runtime.sessionCloseStatus(hs) catch |err| return errToCode(err);
    slot.* = switch (status.outcome) {
        .closed, .timed_out => ch.GLOWCAP_LIFECYCLE_CLOSED,
        .pending => switch (status.phase) {
            .active => ch.GLOWCAP_LIFECYCLE_ACTIVE,
            .finishing => ch.GLOWCAP_LIFECYCLE_FINISHING,
            .cancel_pending => ch.GLOWCAP_LIFECYCLE_TERMINATING,
            .terminating => ch.GLOWCAP_LIFECYCLE_TERMINATING,
        },
    };
    return if (status.outcome == .timed_out) shared.GLOWCAP_ERR_TIMEOUT else GLOWCAP_OK;
}

/// Release one loop-owned session: flush what it queued, drop its wire, and
/// free the session. This is the loop spelling of `glowcap_host_session_release`,
/// which must not be called on sessions this loop minted. Queued events
/// naming the session are invalidated by the wire-map removal and skipped
/// lazily at drain, so release does not scan the event backlog.
pub export fn glowcap_driver_session_release(
    raw: ?*c.GlowcapDriverLoop,
    session: ?*ch.GlowcapHostSession,
) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(raw) orelse return GLOWCAP_ERR_NULL_POINTER;
    // As with listener close, terminal failure must not disable teardown. A
    // callback or active step must refuse before releaseWire drops the wire.
    if (reentrancyCode(inst, "session_release")) |code| return code;
    const hs = ch.embedding.sessionFrom(session) orelse return GLOWCAP_ERR_NULL_POINTER;
    inst.runtime.releaseWire(hs) catch |err| return errToCode(err);
    return GLOWCAP_OK;
}

/// Begin delivering `session`'s inbound application frames: the embedder has
/// finished its post-open setup (its publishes and spawns), so a partner's
/// pipelined first frames can no longer outrun the objects they name. A
/// session surfaced by an OPENED or ACCEPTED event holds its inbound until
/// this call (handshake frames are never held), and bytes that arrived early
/// wait unread (a stream socket's kernel buffer; a resident link's bounded
/// parking) and replay in order. Idempotent. A session already delivering
/// is a no-op. Replaying resident bytes may invoke a `GlowcapHostBehavior`
/// synchronously before this call returns. A binding must install its Host
/// delivery context first. Every binding runtime calls this from its serve path.
pub export fn glowcap_driver_session_serve(
    raw: ?*c.GlowcapDriverLoop,
    session: ?*ch.GlowcapHostSession,
) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(raw) orelse return GLOWCAP_ERR_NULL_POINTER;
    if (reentrancyCode(inst, "session_serve")) |code| return code;
    const hs = ch.embedding.sessionFrom(session) orelse return GLOWCAP_ERR_NULL_POINTER;
    inst.runtime.attendSession(hs) catch |err| return errToCode(err);
    return GLOWCAP_OK;
}
