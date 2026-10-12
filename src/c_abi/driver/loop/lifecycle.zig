//! Own C loop adoption and the aggregate close, retire, and release barrier.

const std = @import("std");
const driver = @import("driver");
const root = @import("../loop.zig");
const events = @import("events.zig");
const provider_registry = @import("../provider_registry.zig");
const driver_error = @import("../error.zig");
const failure_output = @import("../failure_output.zig");
const shared = @import("c_abi_shared");
const ch = @import("c_abi_host");
const c = @import("../mod.zig");

const Internal = root.Internal;
const Instance = Internal.Instance;
const GLOWCAP_OK = shared.GLOWCAP_OK;
const GLOWCAP_ERR_NULL_POINTER = shared.GLOWCAP_ERR_NULL_POINTER;
const GLOWCAP_ERR_INVALID_ARGUMENT = shared.GLOWCAP_ERR_INVALID_ARGUMENT;
const instanceFrom = Internal.instanceFrom;
const errToCode = Internal.errToCode;
const claimHost = Internal.claimHost;
const adoptionErrorCode = Internal.adoptionErrorCode;
const adoptionOptions = Internal.adoptionOptions;
const reentrancyCode = events.reentrancyCode;
const reserveSinkEvent = events.reserveSinkEvent;
const releaseSinkEvent = events.releaseSinkEvent;
const sinkTake = events.sinkTake;
const observeClose = events.observeClose;
const popEvent = events.popEvent;
const freeEventPayload = events.freeEventPayload;
const compactEventsIfDrained = events.compactEventsIfDrained;

// ── Lifecycle ────────────────────────────────────────────────────────────────

/// Move a byte-fed Host with no live sessions or borrowed action into a native
/// loop. Unpopped actions move with the Host and are first consumed by the driver.
/// Failure leaves the caller as the Host's runtime owner. Success transfers
/// transport execution, action draining, session release, and terminal Host
/// release to the returned loop. Buffer and admission limits must be positive.
/// A zero wait budget explicitly selects an unbounded wait, and each nonzero
/// wait is bounded by GLOWCAP_DRIVER_MAX_WAIT_MS. The generic loop starts with
/// no transports, so install provider packages before dialing or listening.
/// Released with `glowcap_driver_release`.
pub export fn glowcap_driver_take_host(
    host: ?*ch.GlowcapHost,
    options: ?*const c.GlowcapDriverOptions,
    out_loop: ?*?*c.GlowcapDriverLoop,
) i32 {
    shared.lastErrorClear();
    const host_handle = host orelse return GLOWCAP_ERR_NULL_POINTER;
    const options_ptr = options orelse return GLOWCAP_ERR_NULL_POINTER;
    const slot = out_loop orelse return GLOWCAP_ERR_NULL_POINTER;
    if (options_ptr.abi_version != c.GLOWCAP_DRIVER_OPTIONS_ABI_VERSION or
        options_ptr.struct_size < @sizeOf(c.GlowcapDriverOptions))
    {
        shared.setLastError("driver: unsupported GlowcapDriverOptions layout", .{});
        return GLOWCAP_ERR_INVALID_ARGUMENT;
    }
    const opts = options_ptr.*;
    if (opts.wire_buffer_bytes == 0 or opts.max_pending_opens == 0 or
        opts.handshake_ms > c.GLOWCAP_DRIVER_MAX_WAIT_MS or
        opts.listener_setup_ms > c.GLOWCAP_DRIVER_MAX_WAIT_MS or
        opts.settle_ms > c.GLOWCAP_DRIVER_MAX_WAIT_MS)
    {
        shared.setLastError("driver: buffer/open limits must be positive and wait budgets must be 0 or at most GLOWCAP_DRIVER_MAX_WAIT_MS", .{});
        return GLOWCAP_ERR_INVALID_ARGUMENT;
    }
    const claim = claimHost(host_handle) catch |err| return errToCode(err);
    const inst = buildInstance(
        claim,
        host_handle,
        adoptionOptions(opts),
    ) catch |err| {
        claim.rollback();
        return adoptionErrorCode(err);
    };
    slot.* = @ptrCast(inst);
    return GLOWCAP_OK;
}

fn buildInstance(
    claim: ch.embedding.DriverClaim,
    host_handle: *ch.GlowcapHost,
    opts: driver.HostRuntime.AdoptionOptions,
) !*Instance {
    const alloc = claim.allocator();
    const inst = try alloc.create(Instance);
    errdefer alloc.destroy(inst);
    inst.* = .{
        .allocator = alloc,
        .threaded = std.Io.Threaded.init(alloc, .{}),
        .host_handle = host_handle,
        .runtime = undefined,
        .providers = undefined,
    };
    errdefer inst.threaded.deinit();
    // The loop is stepped from birth: the runtime is built with its readiness
    // set and both event recipients, so no wire ever exists without a
    // reserved close seat and no completion without a taker.
    var adoption = opts;
    adoption.drive = .{ .stepped = .{
        .completion_sink = .{
            .ctx = inst,
            .reserve = reserveSinkEvent,
            .release = releaseSinkEvent,
            .take = sinkTake,
        },
        .close_observer = .{
            .ctx = inst,
            .reserve = reserveSinkEvent,
            .release = releaseSinkEvent,
            .closed = observeClose,
        },
    } };
    inst.runtime = try driver.HostRuntime.initWithCore(alloc, inst.io(), claim.core(), .{}, adoption);
    errdefer inst.runtime.deinitAfterFailedAdoption();
    inst.providers = provider_registry.Registry.init(alloc, inst.io(), &inst.runtime);
    // Mint the settle mailbox now, so its wake descriptor joins the readiness
    // set before the embedder's first park.
    _ = try inst.runtime.settleMailbox();
    return inst;
}

pub fn releaseRetiredListenerMetadata(inst: *Instance) bool {
    var complete = true;
    var it = inst.listeners.valueIterator();
    while (it.next()) |state| complete = state.deinit(inst) and complete;
    inst.listeners.clearRetainingCapacity();
    return complete;
}

/// Project the native runtime phase through the C delivery barrier. Core and
/// transport teardown remain authoritative below. Queued C events keep only
/// this ABI owner terminating until the caller has received them.
fn projectDriverLifecycle(inst: *const Instance) u32 {
    return switch (inst.runtime.lifecyclePhase()) {
        .active => ch.GLOWCAP_LIFECYCLE_ACTIVE,
        .finishing => ch.GLOWCAP_LIFECYCLE_FINISHING,
        .terminating => ch.GLOWCAP_LIFECYCLE_TERMINATING,
        .closed => if (inst.runtime.closeOutcome() == .pending or
            inst.events_head < inst.events.items.len)
            ch.GLOWCAP_LIFECYCLE_TERMINATING
        else
            ch.GLOWCAP_LIFECYCLE_CLOSED,
    };
}

/// Seal loop admission, close listeners, and begin or escalate the shared
/// runtime close barrier. Progress remains step-driven and nonblocking.
pub export fn glowcap_driver_close(
    raw: ?*c.GlowcapDriverLoop,
    options: ?*const ch.GlowcapCloseOptions,
) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(raw) orelse return GLOWCAP_ERR_NULL_POINTER;
    const callback_close = inst.stepping and inst.runtime.withinCallback();
    if (!callback_close) {
        if (reentrancyCode(inst, "close")) |code| return code;
    }
    const pending = ch.parseCloseOptions(options) catch |err| return ch.closeOptionsErrorCode("driver", err);

    inst.runtime.beginClose(pending);
    if (!callback_close and inst.runtime.listenerOwnershipRetired() and
        !releaseRetiredListenerMetadata(inst))
        inst.runtime.noteTerminalFailure(error.ProviderContract);
    return GLOWCAP_OK;
}

/// Stop listener admission and retire the loop after every application-owned
/// session handle releases. Existing sessions remain active. The final
/// release begins the ordinary cancel close barrier.
pub export fn glowcap_driver_retire(raw: ?*c.GlowcapDriverLoop) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(raw) orelse return GLOWCAP_ERR_NULL_POINTER;
    const callback_retire = inst.stepping and inst.runtime.withinCallback();
    if (!callback_retire) {
        if (reentrancyCode(inst, "retire")) |code| return code;
    }
    inst.runtime.beginRetirement();
    if (!callback_retire and inst.runtime.listenerOwnershipRetired() and
        !releaseRetiredListenerMetadata(inst))
        inst.runtime.noteTerminalFailure(error.ProviderContract);
    return GLOWCAP_OK;
}

/// Observe the close barrier. A timed-out FINISH returns GLOWCAP_ERR_TIMEOUT
/// only after teardown and queued event delivery have reached CLOSED.
pub export fn glowcap_driver_lifecycle_state(raw: ?*c.GlowcapDriverLoop, out_state: ?*u32) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(raw) orelse return GLOWCAP_ERR_NULL_POINTER;
    if (reentrancyCode(inst, "lifecycle_state")) |code| return code;
    const slot = out_state orelse return GLOWCAP_ERR_NULL_POINTER;
    slot.* = projectDriverLifecycle(inst);
    if (slot.* == ch.GLOWCAP_LIFECYCLE_CLOSED and inst.runtime.closeOutcome() == .timed_out)
        return shared.GLOWCAP_ERR_TIMEOUT;
    return GLOWCAP_OK;
}

/// The longest a nonblocking embedder may park on the readiness descriptor
/// before calling `glowcap_driver_step` again with a zero timeout:
/// milliseconds until the nearest pending-work deadline (the close grace, a
/// session's close grace, a dial or listener setup budget), clamped at zero,
/// or -1 when no finite deadline is pending and readiness alone advances the
/// loop. Poll-shaped: the value drops straight into a wait
/// primitive's timeout argument.
pub export fn glowcap_driver_step_wait_ms(raw: ?*c.GlowcapDriverLoop, out_wait_ms: ?*i32) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(raw) orelse return GLOWCAP_ERR_NULL_POINTER;
    if (reentrancyCode(inst, "step_wait_ms")) |code| return code;
    const slot = out_wait_ms orelse return GLOWCAP_ERR_NULL_POINTER;
    slot.* = inst.runtime.stepWaitMs();
    return GLOWCAP_OK;
}

/// Release the loop and everything it owns: listeners, in-flight opens,
/// queued events, every live wire, and then the wrapped host itself (with
/// `glowcap_host_release`'s exact semantics). Do not release the host handle
/// separately. Null is a no-op. Refused from inside a callback.
pub export fn glowcap_driver_release(
    raw: ?*c.GlowcapDriverLoop,
    out_failure: ?*failure_output.GlowcapDriverFailure,
) i32 {
    shared.lastErrorClear();
    const failure_slot = switch (failure_output.claim(out_failure, "driver release")) {
        .slot => |slot| slot,
        .refused => |code| return code,
    };
    const inst = instanceFrom(raw) orelse return GLOWCAP_OK;
    if (reentrancyCode(inst, "release")) |code|
        return failure_output.refuse(failure_slot, code, error.ReenteredHost);
    ch.embedding.checkAttachmentsReleased(inst.host_handle) catch |err|
        return failure_output.refuse(failure_slot, GLOWCAP_ERR_INVALID_ARGUMENT, err);
    // No projection survives release. The runtime's recipients stay installed
    // for its teardown, but from here `sinkTake` refuses (the drain then frees
    // each completion through the still-live core) and `observeClose` only
    // gives its reserved seat back; operation observers still run during
    // Runtime teardown to release their reservations and C metadata.
    inst.releasing = true;
    if (inst.handed_completion) |action| {
        inst.runtime.freeAction(action);
        inst.handed_completion = null;
    }
    while (popEvent(inst)) |event| freeEventPayload(inst, event);
    compactEventsIfDrained(inst);
    // Runtime teardown may still project terminal operation outcomes through
    // this adapter. Keep C-owned metadata and queues alive until it returns,
    // then discard projections no caller can observe after release.
    var teardown_failure = inst.runtime.deinitOutcome();
    if (!releaseRetiredListenerMetadata(inst))
        failure_output.noteError(&teardown_failure, error.ProviderContract);
    inst.listeners.deinit(inst.allocator);
    while (popEvent(inst)) |event| switch (event) {
        // A releasing sink refuses every take, which makes this impossible
        // through the public state machine. If that invariant regresses, preserve the
        // consumed-handle release outcome instead of aborting the process.
        // The core is already gone, so the unexpected payload cannot safely
        // be traversed and is leaked on this contract-failure
        // path rather than freed through dead ownership.
        .completion => failure_output.noteError(&teardown_failure, error.ProviderContract),
        else => {},
    };
    inst.events.deinit(inst.allocator);
    if (inst.event_reservations != 0)
        failure_output.noteError(&teardown_failure, error.ProviderContract);
    inst.providers.deinit();
    if (ch.embedding.releaseFromDriver(inst.host_handle)) |host_failure| {
        failure_output.noteError(&teardown_failure, host_failure);
    }
    inst.threaded.deinit();
    const alloc = inst.allocator;
    alloc.destroy(inst);
    if (teardown_failure) |failure| {
        failure_output.setLastError("driver release", failure);
        // INVALID_ARGUMENT is reserved for an admission refusal above and
        // therefore means the handle remains live. Teardown has already
        // consumed the loop; classify a provider's invalid-argument cleanup
        // report as internal at this boundary while preserving its exact cause
        // in last_error, so consumers can distinguish retry from consumption.
        const code = driver_error.code(failure.kind);
        const consumed_code = if (code == GLOWCAP_ERR_INVALID_ARGUMENT) shared.GLOWCAP_ERR_INTERNAL else code;
        failure_output.project(failure_slot, consumed_code, failure);
        return consumed_code;
    }
    return GLOWCAP_OK;
}
