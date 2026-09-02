//! Own readiness projection, one loop step, thread handoff, and wake.

const root = @import("../loop.zig");
const lifecycle = @import("lifecycle.zig");
const shared = @import("c_abi_shared");
const c = @import("../mod.zig");

const Internal = root.Internal;
const Instance = Internal.Instance;
const GLOWCAP_OK = shared.GLOWCAP_OK;
const GLOWCAP_ERR_NULL_POINTER = shared.GLOWCAP_ERR_NULL_POINTER;
const GLOWCAP_ERR_WOULD_BLOCK = shared.GLOWCAP_ERR_WOULD_BLOCK;
const instanceFrom = Internal.instanceFrom;
const errToCode = Internal.errToCode;
const reentrancyCode = @import("events.zig").reentrancyCode;
const operationErrorCode = @import("events.zig").operationErrorCode;
const releaseRetiredListenerMetadata = lifecycle.releaseRetiredListenerMetadata;

/// The one descriptor to park on: readable while any wire, resident,
/// listener, mailbox, or wake has pending work. Arm it once, before sharing
/// the loop pointer with any waking thread, and call `glowcap_driver_step`
/// whenever it reads ready. Owned by the loop; never close it.
pub export fn glowcap_driver_readiness_fd(raw: ?*c.GlowcapDriverLoop, out_fd: ?*i32) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(raw) orelse return GLOWCAP_ERR_NULL_POINTER;
    if (reentrancyCode(inst, "readiness_fd")) |code| return code;
    const slot = out_fd orelse return GLOWCAP_ERR_NULL_POINTER;
    const fd = inst.runtime.readinessDescriptor() catch |err| return errToCode(err);
    slot.* = fd;
    return GLOWCAP_OK;
}

// ── Step, wake, events ───────────────────────────────────────────────────────

/// One loop step: accept what the listener has ready, then pump — apply
/// cross-thread settles, service ready wires and
/// residents, drain host actions (flushes execute here; completions queue as
/// events), and advance in-flight dial handshakes, direct and redeem alike.
/// Parks up to `timeout_ms` only when nothing is already pending; `-1` parks
/// until readiness, `0` never parks. Returns `GLOWCAP_OK` when immediate work
/// was observed or an event remains queued, and `GLOWCAP_ERR_WOULD_BLOCK` when
/// the loop is drained after that wait. Edge-triggered embedders therefore call
/// until WOULD_BLOCK before clearing readiness. Drain
/// `glowcap_driver_next_event` after every call that returns OK.
pub export fn glowcap_driver_step(raw: ?*c.GlowcapDriverLoop, timeout_ms: i32) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(raw) orelse return GLOWCAP_ERR_NULL_POINTER;
    if (reentrancyCode(inst, "step")) |code| return code;
    // Events are the consumer's backpressure signal. Do not commit more
    // observable transitions until it drains what the prior step produced.
    if (inst.events_head < inst.events.items.len) return GLOWCAP_OK;
    inst.stepping = true;
    defer inst.stepping = false;

    const progress = inst.runtime.stepAny(timeout_ms) catch |err| {
        return operationErrorCode(inst, err);
    };
    // An individually closed listener retains its `.retired` C identity until
    // the caller retries listener_close after WOULD_BLOCK. Whole-loop close
    // has no such caller-owned retry and may release all projection metadata.
    if (inst.runtime.lifecyclePhase() != .active and inst.runtime.listenerOwnershipRetired() and
        !releaseRetiredListenerMetadata(inst))
        inst.runtime.noteTerminalFailure(error.ProviderContract);
    if (progress == null and inst.events_head >= inst.events.items.len)
        return GLOWCAP_ERR_WOULD_BLOCK;
    return GLOWCAP_OK;
}

/// Release the calling thread's exclusive claim on the loop's host at a
/// quiescent boundary: call it after setup (`glowcap_host_publish` and the
/// like claim the host for the thread that ran them), before another thread
/// begins stepping. The next verb from any thread re-claims; this is a
/// sequential handover, never permission for concurrent access. In an
/// unsafe build the claim tracking compiles out and this is a no-op.
pub export fn glowcap_driver_detach_thread(raw: ?*c.GlowcapDriverLoop) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(raw) orelse return GLOWCAP_ERR_NULL_POINTER;
    if (reentrancyCode(inst, "detach_thread")) |code| return code;
    inst.runtime.detachThread() catch |err| return errToCode(err);
    return GLOWCAP_OK;
}

/// Make a parked loop return from its wait, from any thread — the one
/// cross-thread verb on this family. Arm the readiness descriptor before
/// sharing the loop pointer with a waking thread.
pub export fn glowcap_driver_wake(raw: ?*c.GlowcapDriverLoop) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(raw) orelse return GLOWCAP_ERR_NULL_POINTER;
    inst.runtime.wakeReadiness() catch |err| return errToCode(err);
    return GLOWCAP_OK;
}
