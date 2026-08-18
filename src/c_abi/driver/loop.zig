//! The `pancake_driver_*` loop family (ADR-0112): a stepping projection of
//! `driver.HostRuntime` over the byte-fed Host implementation. The embedder's
//! whole transport role is: create the loop, register provider packages, dial
//! and listen, park on one readiness
//! descriptor, step, and drain one event queue; every application verb stays
//! `pancake_host_*` on the Host handle moved into `pancake_driver_take_host`. Those
//! symbols belong to `libpancake_host`; this archive emits only
//! `pancake_driver_*`.
//!
//! Threading: one thread drives one loop, and every verb here except
//! `pancake_driver_wake` must run on it. Callbacks fire on the stepping
//! thread.
//!
//! Dial starts are nonblocking by provider contract and run in the dial call;
//! transport completion and every CapTP handshake advance across later steps
//! under the handshake budget. Accepted handshakes use the same pending-open
//! path, so a silent connector does not park the loop or starve siblings.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const net = @import("net");
const driver = @import("driver");
const driver_core = @import("driver_core");
const provider_registry = @import("provider_registry.zig");
const driver_error = @import("error.zig");
const failure_output = @import("failure_output.zig");

const shared = @import("c_abi_shared");
const ch = @import("c_abi_host");
const c = @import("mod.zig");

const crypto = foundation.crypto;
const LocatorProjection = shared.locator_adapter.Projection;
const FailureProjection = c.FailureProjection;

const PANCAKE_OK = shared.PANCAKE_OK;
const PANCAKE_ERR_NULL_POINTER = shared.PANCAKE_ERR_NULL_POINTER;
const PANCAKE_ERR_INVALID_ARGUMENT = shared.PANCAKE_ERR_INVALID_ARGUMENT;
const PANCAKE_ERR_WOULD_BLOCK = shared.PANCAKE_ERR_WOULD_BLOCK;
const PANCAKE_ERR_BUFFER_TOO_SMALL = shared.PANCAKE_ERR_BUFFER_TOO_SMALL;

/// One loop: the wrapped host handle (a real `PancakeHost`, so every
/// `pancake_host_*` verb works on it), the HostRuntime that pumps for it, the
/// transports and listeners it owns, and the in-flight opens and event queue
/// between the C caller and the pump.
const Instance = struct {
    allocator: std.mem.Allocator,
    threaded: std.Io.Threaded,
    host_handle: *ch.PancakeHost,
    runtime: driver.HostRuntime,
    providers: provider_registry.Registry,
    /// One listener per transport, keyed by stable loop-minted ids. The Host
    /// advertises one locator per transport too, so refusing a duplicate
    /// transport keeps listener state and Host authority in the same shape.
    listeners: std.AutoHashMapUnmanaged(ListenerId, ListenerState) = .{},
    next_listener: u64 = 1,
    next_operation_id: u64 = 1,
    /// FIFO event queue: `events[events_head..]` is pending; the storage
    /// compacts when drained.
    events: std.ArrayListUnmanaged(OwnedEvent) = .empty,
    events_head: usize = 0,
    /// Queue slots promised before dial/listen/accept, session-close, and
    /// completion outcomes commit. Every terminal callback publishes without
    /// allocation; the admitting or preflight boundary owns capacity failure.
    event_reservations: usize = 0,
    /// The completion view handed out by the last
    /// `pancake_driver_next_event`, freed by the next one — the byte-fed
    /// queue's borrow contract, one tier up. Error names are static.
    handed_completion: ?driver_core.HostAction = null,
    stepping: bool = false,

    fn io(self: *Instance) std.Io {
        return self.threaded.io();
    }
};

/// Listener ids belong to one loop instance and are never reused during its
/// lifetime. The C projection is `u64`; this type keeps that namespace from
/// being confused with operation ids inside Zig.
const ListenerId = enum(u64) { _ };

const BoundListener = struct {
    projection: LocatorProjection,

    fn deinit(self: *BoundListener, inst: *Instance) void {
        self.projection.deinit(inst.allocator);
    }
};

const ListenerState = union(enum) {
    pending,
    active: BoundListener,
};

const ActiveListenerLookupError = error{ UnknownListener, ListenerPending };

fn activeListener(inst: *Instance, listener: u64) ActiveListenerLookupError!*BoundListener {
    const state = inst.listeners.getPtr(@enumFromInt(listener)) orelse {
        shared.setLastError("driver: unknown listener id", .{});
        return error.UnknownListener;
    };
    return switch (state.*) {
        .pending => {
            shared.setLastError("driver: listener setup is pending", .{});
            return error.ListenerPending;
        },
        .active => |*active| active,
    };
}

fn activeListenerErrorCode(err: ActiveListenerLookupError) i32 {
    return switch (err) {
        error.UnknownListener => shared.PANCAKE_ERR_NOT_FOUND,
        error.ListenerPending => shared.PANCAKE_ERR_WOULD_BLOCK,
    };
}

/// One queued loop event, in owned form; projection to C happens at pop.
const OwnedEvent = union(enum) {
    opened: struct { operation_id: u64, session: SessionEventRef },
    open_failed: struct { operation_id: u64, failure: FailureProjection },
    listener_ready: u64,
    listener_failed: struct { listener: u64, failure: FailureProjection },
    accepted: struct { listener: u64, session: SessionEventRef },
    session_closed: struct {
        session: SessionEventRef,
        failure: ?FailureProjection,
    },
    completion: driver_core.HostAction,
};

/// Stable identity beside a borrowed session pointer. Release removes the
/// wire map row before freeing the session, so stale queued events can compare
/// pointer values without dereferencing freed memory.
const SessionEventRef = struct {
    peer_id: engine.PeerId,
    hs: *driver_core.HostSession,

    fn init(hs: *driver_core.HostSession) SessionEventRef {
        return .{ .peer_id = hs.peer_id, .hs = hs };
    }

    fn isLive(self: SessionEventRef, inst: *const Instance) bool {
        return inst.runtime.sessionEventIsLive(self.peer_id, self.hs);
    }
};

fn instanceFrom(raw: ?*c.PancakeDriverLoop) ?*Instance {
    return @ptrCast(@alignCast(raw orelse return null));
}

fn errToCode(err: anyerror) i32 {
    // An `InvalidArgument` refusal wrote its own message before raising (the
    // host family's convention); stamping the bare error name over it would
    // throw the diagnostic away. Every other error names itself.
    if (err != error.InvalidArgument) shared.setLastError("driver: {s}", .{@errorName(err)});
    return driver_error.fromError(err);
}

fn claimHost(host: *ch.PancakeHost) !ch.embedding.DriverClaim {
    return (ch.embedding.claimForDriver(host) catch |err| {
        switch (err) {
            error.HostAlreadyOwned => shared.setLastError("driver: host already has a drive owner", .{}),
        }
        return error.InvalidArgument;
    }) orelse {
        shared.setLastError("driver: host handle is null", .{});
        return error.InvalidArgument;
    };
}

fn adoptionErrorCode(err: anyerror) i32 {
    switch (err) {
        error.HostNotQuiescent => shared.setLastError("driver: host has live sessions or a borrowed adapter action", .{}),
        error.ReenteredHost => shared.setLastError("driver: host transfer refused inside a callback", .{}),
        error.HostClosing => shared.setLastError("driver: a closing host cannot transfer to a new driver", .{}),
        else => shared.setLastError("driver: {s}", .{@errorName(err)}),
    }
    return driver_error.fromError(err);
}

fn adoptionOptions(options: c.PancakeDriverOptions) driver.HostRuntime.AdoptionOptions {
    return .{
        .wire_buffer_bytes = options.wire_buffer_bytes,
        .max_pending_opens = options.max_pending_opens,
        .handshake = waitBudget(options.handshake_ms),
        .listener_setup = waitBudget(options.listener_setup_ms),
        .settle = waitBudget(options.settle_ms),
    };
}

fn waitBudget(milliseconds: u32) driver.Budget {
    return if (milliseconds == 0) .unbounded else .{ .ms = @intCast(milliseconds) };
}

fn operationOptions(raw: ?*const shared.PancakeTransportOperationOptions) !net.OperationOptions {
    const options = raw orelse return .inherit;
    const data = options.data orelse {
        if (options.size != 0) return error.InvalidArgument;
        return .inherit;
    };
    if (options.size == 0) return error.InvalidArgument;
    return .{ .data = data, .size = options.size };
}

fn operationOptionsCode(raw: ?*const shared.PancakeTransportOperationOptions) !net.OperationOptions {
    return operationOptions(raw) catch |err| {
        shared.setLastError("driver: invalid transport operation options: {s}", .{@errorName(err)});
        return err;
    };
}

// ── Event queue ──────────────────────────────────────────────────────────────

fn compactEventsIfDrained(inst: *Instance) void {
    if (inst.events_head < inst.events.items.len) return;
    inst.events.clearRetainingCapacity();
    inst.events_head = 0;
}

fn reserveEvent(inst: *Instance) !void {
    compactEventsIfDrained(inst);
    const promised = std.math.add(usize, inst.events.items.len, inst.event_reservations) catch
        return error.OutOfMemory;
    const required = std.math.add(usize, promised, 1) catch return error.OutOfMemory;
    try inst.events.ensureTotalCapacity(inst.allocator, required);
    inst.event_reservations += 1;
}

fn releaseEventReservation(inst: *Instance) void {
    std.debug.assert(inst.event_reservations != 0);
    inst.event_reservations -= 1;
}

fn reserveOpenEventForObserver(ctx: *anyopaque, _: u64) anyerror!void {
    const inst: *Instance = @ptrCast(@alignCast(ctx));
    try reserveEvent(inst);
}

fn releaseOpenEventForObserver(ctx: *anyopaque, _: u64) void {
    const inst: *Instance = @ptrCast(@alignCast(ctx));
    releaseEventReservation(inst);
}

fn abandonListenerEvent(ctx: *anyopaque, tag: u64) void {
    const inst: *Instance = @ptrCast(@alignCast(ctx));
    if (!inst.listeners.remove(@enumFromInt(tag)))
        inst.runtime.noteTerminalFailure(error.ProviderContract);
    releaseEventReservation(inst);
}

fn enqueueReservedEvent(inst: *Instance, event: OwnedEvent) void {
    releaseEventReservation(inst);
    inst.events.appendAssumeCapacity(event);
}

fn reentrancyCode(inst: *Instance, operation: []const u8) ?i32 {
    if (inst.stepping) {
        shared.setLastError("driver: {s} refused during driver execution", .{operation});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    }
    inst.runtime.refuseReentry() catch |err| {
        shared.setLastError("driver: {s} refused during driver execution: {s}", .{ operation, @errorName(err) });
        return driver_error.fromError(err);
    };
    return null;
}

fn operationErrorCode(inst: *const Instance, err: anyerror) i32 {
    return failure_output.operationCode(&inst.runtime, err);
}

fn freeEventPayload(inst: *Instance, event: OwnedEvent) void {
    switch (event) {
        .completion => |action| inst.runtime.freeAction(action),
        else => {},
    }
}

fn popEvent(inst: *Instance) ?OwnedEvent {
    if (inst.events_head >= inst.events.items.len) return null;
    const event = inst.events.items[inst.events_head];
    inst.events_head += 1;
    return event;
}

fn eventNamesLiveSession(inst: *const Instance, event: OwnedEvent) bool {
    return switch (event) {
        .opened => |opened| opened.session.isLive(inst),
        .accepted => |accepted| accepted.session.isLive(inst),
        .session_closed => |closed| closed.session.isLive(inst),
        .open_failed, .listener_ready, .listener_failed, .completion => true,
    };
}

// ── Host observer seams ──────────────────────────────────────────────────

/// The completion sink installed on the poll face: settled/failed actions
/// with no in-process claimer queue as COMPLETION events. The shared drain
/// reserves the queue slot while the completion remains parked, so taking it
/// here is allocation-free and infallible.
fn sinkTake(ctx: *anyopaque, action: driver_core.HostAction) bool {
    const inst: *Instance = @ptrCast(@alignCast(ctx));
    enqueueReservedEvent(inst, .{ .completion = action });
    return true;
}

fn reserveSinkEvent(ctx: *anyopaque) anyerror!void {
    const inst: *Instance = @ptrCast(@alignCast(ctx));
    try reserveEvent(inst);
}

fn releaseSinkEvent(ctx: *anyopaque) void {
    const inst: *Instance = @ptrCast(@alignCast(ctx));
    releaseEventReservation(inst);
}

/// The close observer: a wire the pump closes queues a SESSION_CLOSED event.
/// Clean EOF carries PANCAKE_OK and no message; a fault carries the stable
/// driver classification plus its concrete Zig error name. Wire adoption
/// reserved this event before the session could become visible.
fn observeClose(
    ctx: *anyopaque,
    hs: *driver_core.HostSession,
    failure: ?driver.OperationFailure,
) void {
    const inst: *Instance = @ptrCast(@alignCast(ctx));
    enqueueReservedEvent(inst, .{ .session_closed = .{
        .session = .init(hs),
        .failure = if (failure) |f| .init(f) else null,
    } });
}

/// An open finished its handshake inside a step; queue OPENED under its
/// operation id. Admission reserved the queue slot, so this callback cannot
/// allocate after the session commits.
fn openSucceeded(ctx: *anyopaque, tag: u64, session: *driver_core.HostSession) !void {
    const inst: *Instance = @ptrCast(@alignCast(ctx));
    try inst.runtime.claimSessionHandle(session);
    // The embedder has not seen this session; hold its inbound until
    // `pancake_driver_session_serve` says the post-open setup is done, so a
    // partner's pipelined first frames cannot outrun a publish.
    inst.runtime.markSessionUnattended(session);
    enqueueReservedEvent(inst, .{ .opened = .{ .operation_id = tag, .session = .init(session) } });
}

/// An open failed after the host unwound its in-flight session. Queue
/// OPEN_FAILED with the error's static name. Admission reserved the queue slot,
/// so failure publication cannot allocate after the operation commits.
fn openFailedEvent(ctx: *anyopaque, tag: u64, failure: driver.OperationFailure) void {
    const inst: *Instance = @ptrCast(@alignCast(ctx));
    enqueueReservedEvent(inst, .{
        .open_failed = .{
            .operation_id = tag,
            .failure = .init(failure),
        },
    });
}

/// The accept observer's opened arm: an admitted accept finished its handshake;
/// queue the ACCEPTED event under its listener id. The accept step reserved
/// the queue slot before admitting the connection.
fn acceptOpened(ctx: *anyopaque, tag: u64, session: *driver_core.HostSession) !void {
    const inst: *Instance = @ptrCast(@alignCast(ctx));
    try inst.runtime.claimSessionHandle(session);
    // Same hold as a dialed open: the accepted partner's coalesced fetch must
    // wait for the embedder's publishes, not race them.
    inst.runtime.markSessionUnattended(session);
    enqueueReservedEvent(inst, .{ .accepted = .{ .listener = tag, .session = .init(session) } });
}

fn acceptFailed(ctx: *anyopaque, tag: u64, failure: driver.OperationFailure) void {
    const inst: *Instance = @ptrCast(@alignCast(ctx));
    if (inst.listeners.fetchRemove(@enumFromInt(tag))) |removed| {
        var active = removed.value.active;
        active.deinit(inst);
    } else {
        inst.runtime.noteTerminalFailure(error.ProviderContract);
    }
    enqueueReservedEvent(inst, .{
        .listener_failed = .{
            .listener = tag,
            .failure = .init(failure),
        },
    });
}

// ── Lifecycle ────────────────────────────────────────────────────────────────

/// Move a byte-fed Host with no live sessions or borrowed action into a native
/// loop. Unpopped actions move with the Host and are first consumed by the driver.
/// Failure leaves the caller as the Host's runtime owner; success transfers
/// transport execution, action draining, session release, and terminal Host
/// release to the returned loop. Buffer and admission limits must be positive;
/// a zero wait budget explicitly selects an unbounded wait, and each nonzero
/// wait is bounded by PANCAKE_DRIVER_MAX_WAIT_MS. The generic loop starts with
/// no transports, so install provider packages before dialing or listening.
/// Released with `pancake_driver_release`.
pub export fn pancake_driver_take_host(
    host: ?*ch.PancakeHost,
    options: ?*const c.PancakeDriverOptions,
    out_loop: ?*?*c.PancakeDriverLoop,
) i32 {
    shared.lastErrorClear();
    const host_handle = host orelse return PANCAKE_ERR_NULL_POINTER;
    const options_ptr = options orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_loop orelse return PANCAKE_ERR_NULL_POINTER;
    if (options_ptr.abi_version != c.PANCAKE_DRIVER_OPTIONS_ABI_VERSION or
        options_ptr.struct_size < @sizeOf(c.PancakeDriverOptions))
    {
        shared.setLastError("driver: unsupported PancakeDriverOptions layout", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    }
    const opts = options_ptr.*;
    if (opts.wire_buffer_bytes == 0 or opts.max_pending_opens == 0 or
        opts.handshake_ms > c.PANCAKE_DRIVER_MAX_WAIT_MS or
        opts.listener_setup_ms > c.PANCAKE_DRIVER_MAX_WAIT_MS or
        opts.settle_ms > c.PANCAKE_DRIVER_MAX_WAIT_MS)
    {
        shared.setLastError("driver: buffer/open limits must be positive and wait budgets must be 0 or at most PANCAKE_DRIVER_MAX_WAIT_MS", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
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
    return PANCAKE_OK;
}

fn buildInstance(
    claim: ch.embedding.DriverClaim,
    host_handle: *ch.PancakeHost,
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
    inst.runtime = try driver.HostRuntime.initWithCore(alloc, inst.io(), claim.core(), &.{}, opts);
    errdefer inst.runtime.deinitAfterFailedAdoption();
    inst.providers = provider_registry.Registry.init(alloc, inst.io(), &inst.runtime);
    // Mint the settle mailbox now, so its wake descriptor is in the
    // readiness set from the moment the set is armed.
    _ = try inst.runtime.settleMailbox();
    inst.runtime.setCompletionSink(.{
        .ctx = inst,
        .reserve = reserveSinkEvent,
        .release = releaseSinkEvent,
        .take = sinkTake,
    });
    try inst.runtime.setCloseObserver(.{
        .ctx = inst,
        .reserve = reserveSinkEvent,
        .release = releaseSinkEvent,
        .closed = observeClose,
    });
    return inst;
}

fn closeListenerById(inst: *Instance, id: ListenerId) ?driver.OperationFailure {
    const outcome = inst.runtime.stopOwnedListener(@intFromEnum(id));
    if (!outcome.found) return .fromError(error.ProviderContract);
    // Pending cancellation synchronously removes its projection through the
    // observer. An active listener leaves only its C locator projection here.
    if (inst.listeners.fetchRemove(id)) |removed| {
        var bound_listener = removed.value.active;
        bound_listener.deinit(inst);
    }
    return outcome.failure;
}

fn releaseRetiredListenerMetadata(inst: *Instance) bool {
    var complete = true;
    var it = inst.listeners.iterator();
    while (it.next()) |entry| switch (entry.value_ptr.*) {
        // Runtime retirement removes pending listeners through their observer.
        // Keep release total if that internal contract is ever violated: the
        // pending row owns no projection, and the returned release failure is
        // a safer postmortem than terminating the embedding process.
        .pending => complete = false,
        .active => |*active| active.deinit(inst),
    };
    inst.listeners.clearRetainingCapacity();
    return complete;
}

/// Project the native runtime phase through the C delivery barrier. Core and
/// transport teardown remain authoritative below; queued C events keep only
/// this ABI owner terminating until the caller has received them.
fn projectDriverLifecycle(inst: *const Instance) u32 {
    return switch (inst.runtime.lifecyclePhase()) {
        .active => ch.PANCAKE_LIFECYCLE_ACTIVE,
        .finishing => ch.PANCAKE_LIFECYCLE_FINISHING,
        .terminating => ch.PANCAKE_LIFECYCLE_TERMINATING,
        .closed => if (inst.runtime.closeOutcome() == .pending or
            inst.events_head < inst.events.items.len)
            ch.PANCAKE_LIFECYCLE_TERMINATING
        else
            ch.PANCAKE_LIFECYCLE_CLOSED,
    };
}

/// Seal loop admission, close listeners, and begin or escalate the shared
/// runtime close barrier. Progress remains step-driven and nonblocking.
pub export fn pancake_driver_close(
    raw: ?*c.PancakeDriverLoop,
    options: ?*const ch.PancakeCloseOptions,
) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    const callback_close = inst.stepping and inst.runtime.withinCallback();
    if (!callback_close) {
        if (reentrancyCode(inst, "close")) |code| return code;
    }
    const pending = ch.parseCloseOptions(options) catch |err| return ch.closeOptionsErrorCode("driver", err);

    inst.runtime.beginClose(pending);
    if (!callback_close and inst.runtime.listenerOwnershipRetired() and
        !releaseRetiredListenerMetadata(inst))
        inst.runtime.noteTerminalFailure(error.ProviderContract);
    return PANCAKE_OK;
}

/// Stop listener admission and retire the loop after every application-owned
/// session handle releases. Existing sessions remain active; the final
/// release begins the ordinary cancel close barrier.
pub export fn pancake_driver_retire(raw: ?*c.PancakeDriverLoop) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    const callback_retire = inst.stepping and inst.runtime.withinCallback();
    if (!callback_retire) {
        if (reentrancyCode(inst, "retire")) |code| return code;
    }
    inst.runtime.beginRetirement();
    if (!callback_retire and inst.runtime.listenerOwnershipRetired() and
        !releaseRetiredListenerMetadata(inst))
        inst.runtime.noteTerminalFailure(error.ProviderContract);
    return PANCAKE_OK;
}

/// Observe the close barrier. A timed-out FINISH returns PANCAKE_ERR_TIMEOUT
/// only after teardown and queued event delivery have reached CLOSED.
pub export fn pancake_driver_lifecycle_state(raw: ?*c.PancakeDriverLoop, out_state: ?*u32) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    if (reentrancyCode(inst, "lifecycle_state")) |code| return code;
    const slot = out_state orelse return PANCAKE_ERR_NULL_POINTER;
    slot.* = projectDriverLifecycle(inst);
    if (slot.* == ch.PANCAKE_LIFECYCLE_CLOSED and inst.runtime.closeOutcome() == .timed_out)
        return shared.PANCAKE_ERR_TIMEOUT;
    return PANCAKE_OK;
}

/// The longest a nonblocking embedder may park on the readiness descriptor
/// before calling `pancake_driver_step` again with a zero timeout:
/// milliseconds until the nearest pending-work deadline (the close grace, a
/// session's close grace, a dial or listener setup budget), clamped at zero,
/// or -1 when no finite deadline is pending and readiness alone advances the
/// loop. Poll-shaped on purpose: the value drops straight into a wait
/// primitive's timeout argument.
pub export fn pancake_driver_step_wait_ms(raw: ?*c.PancakeDriverLoop, out_wait_ms: ?*i32) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    if (reentrancyCode(inst, "step_wait_ms")) |code| return code;
    const slot = out_wait_ms orelse return PANCAKE_ERR_NULL_POINTER;
    slot.* = inst.runtime.stepWaitMs();
    return PANCAKE_OK;
}

/// Release the loop and everything it owns: listeners, in-flight opens,
/// queued events, every live wire, and then the wrapped host itself (with
/// `pancake_host_release`'s exact semantics). Do not release the host handle
/// separately. Null is a no-op; refused from inside a callback.
pub export fn pancake_driver_release(
    raw: ?*c.PancakeDriverLoop,
    out_failure: ?*failure_output.PancakeDriverFailure,
) i32 {
    shared.lastErrorClear();
    const failure_slot = switch (failure_output.claim(out_failure, "driver release")) {
        .slot => |slot| slot,
        .refused => |code| return code,
    };
    const inst = instanceFrom(raw) orelse return PANCAKE_OK;
    if (reentrancyCode(inst, "release")) |code|
        return failure_output.refuse(failure_slot, code, error.ReenteredHost);
    // No projection survives release. Retire core-owned completion payloads
    // while the core is still live, then detach the two optional event sinks;
    // operation observers still run during Runtime teardown to release their
    // reservations and C metadata.
    inst.runtime.setCompletionSink(null);
    inst.runtime.clearCloseObserver();
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
        // Detaching the completion sink makes this impossible through the
        // public state machine. If that invariant regresses, preserve the
        // consumed-handle release outcome instead of aborting the process.
        // The core is already gone, so the unexpected payload cannot safely
        // be traversed and is deliberately leaked on this contract-failure
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
        const consumed_code = if (code == PANCAKE_ERR_INVALID_ARGUMENT) shared.PANCAKE_ERR_INTERNAL else code;
        failure_output.project(failure_slot, consumed_code, failure);
        return consumed_code;
    }
    return PANCAKE_OK;
}

// ── Transport providers ─────────────────────────────────────────────────────

/// Install a provider package atomically through the generic provider registry.
pub export fn pancake_driver_add_provider(
    raw: ?*c.PancakeDriverLoop,
    provider: ?*const shared.PancakeTransportProvider,
    out_failure: ?*failure_output.PancakeDriverFailure,
) i32 {
    shared.lastErrorClear();
    const failure_slot = switch (failure_output.claim(out_failure, "driver add_provider")) {
        .slot => |slot| slot,
        .refused => |code| return code,
    };
    const inst = instanceFrom(raw) orelse
        return failure_output.refuse(failure_slot, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
    if (reentrancyCode(inst, "add_provider")) |code|
        return failure_output.refuse(failure_slot, code, error.ReenteredHost);
    const outcome = inst.providers.addProvider(provider);
    if (outcome.failure) |failure| failure_output.project(failure_slot, outcome.result, failure);
    return outcome.result;
}

/// Report whether the loop's provider registry owns `transport`.
pub export fn pancake_driver_has_transport(
    raw: ?*c.PancakeDriverLoop,
    transport: ?[*]const u8,
    transport_len: usize,
    out_present: ?*u8,
) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_present orelse return PANCAKE_ERR_NULL_POINTER;
    const name = shared.sliceFromC(transport, transport_len) catch |err| return shared.marshalErrorToCode(err);
    if (name.len == 0) {
        shared.setLastError("driver: has_transport requires a non-empty transport name", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    }
    slot.* = @intFromBool(inst.runtime.hasTransport(name));
    return PANCAKE_OK;
}

// ── Dial, listen, readiness ──────────────────────────────────────────────────

/// Begin a nonblocking dial toward one complete canonical OCapN peer locator
/// and answer at once with an operation id. Transport completion and the handshake
/// advance across steps under the handshake budget; OPENED or OPEN_FAILED
/// carries the operation id.
pub export fn pancake_driver_dial(
    raw: ?*c.PancakeDriverLoop,
    locator_view: ?*const shared.PancakeLocatorView,
    options: ?*const shared.PancakeTransportOperationOptions,
    out_operation_id: ?*u64,
) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    if (reentrancyCode(inst, "dial")) |code| return code;
    const slot = out_operation_id orelse return PANCAKE_ERR_NULL_POINTER;
    const operation_id = beginDial(inst, locator_view, options) catch |err| return operationErrorCode(inst, err);
    slot.* = operation_id;
    return PANCAKE_OK;
}

/// Begin adoption of one externally established provider connection. The
/// subject is meaningful only to the provider registered under `transport`;
/// the driver never interprets it. `role` selects the Host/session half; the
/// terminal OPENED or OPEN_FAILED event carries the returned operation id.
pub export fn pancake_driver_adopt_external(
    raw: ?*c.PancakeDriverLoop,
    transport: ?[*]const u8,
    transport_len: usize,
    subject: u64,
    role: u32,
    out_operation_id: ?*u64,
) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    if (reentrancyCode(inst, "adopt_external")) |code| return code;
    const slot = out_operation_id orelse return PANCAKE_ERR_NULL_POINTER;
    const adoption_role: driver.HostRuntime.ExternalAdoptionRole = switch (role) {
        c.PANCAKE_DRIVER_ADOPT_DIALED => .dialed,
        c.PANCAKE_DRIVER_ADOPT_ACCEPTED => .accepted,
        else => {
            shared.setLastError("driver: adopt_external role must be PANCAKE_DRIVER_ADOPT_DIALED or PANCAKE_DRIVER_ADOPT_ACCEPTED", .{});
            return PANCAKE_ERR_INVALID_ARGUMENT;
        },
    };
    const operation_id = beginExternalAdoption(inst, transport, transport_len, subject, adoption_role) catch |err|
        return operationErrorCode(inst, err);
    slot.* = operation_id;
    return PANCAKE_OK;
}

fn beginExternalAdoption(
    inst: *Instance,
    transport: ?[*]const u8,
    transport_len: usize,
    subject: u64,
    role: driver.HostRuntime.ExternalAdoptionRole,
) !u64 {
    const bytes = shared.sliceFromC(transport, transport_len) catch return error.InvalidArgument;
    if (bytes.len == 0) return error.InvalidArgument;
    const operation_id = inst.next_operation_id;
    if (operation_id == std.math.maxInt(u64)) return error.IdentifierExhausted;
    const observer: driver.HostRuntime.SessionOpenObserver = .{
        .ctx = inst,
        .reserve = reserveOpenEventForObserver,
        .release = releaseOpenEventForObserver,
        .abandoned = releaseOpenEventForObserver,
        .opened = openSucceeded,
        .failed = openFailedEvent,
    };
    const provider_subject = std.math.cast(usize, subject) orelse return error.InvalidArgument;
    try inst.runtime.startAdoptExternal(bytes, provider_subject, role, operation_id, observer);
    inst.next_operation_id += 1;
    return operation_id;
}

fn beginDial(
    inst: *Instance,
    locator_view: ?*const shared.PancakeLocatorView,
    options_raw: ?*const shared.PancakeTransportOperationOptions,
) !u64 {
    const view = locator_view orelse return error.InvalidArgument;
    var hints: [shared.locator_adapter.inline_hint_capacity]model.HintEntry = undefined;
    var locator = shared.locator_adapter.BorrowedLocator.init(inst.allocator, view, &hints) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidLocatorView => return error.InvalidArgument,
    };
    defer locator.deinit(inst.allocator);
    const options = try operationOptionsCode(options_raw);
    const operation_id = inst.next_operation_id;
    if (operation_id == std.math.maxInt(u64)) return error.IdentifierExhausted;
    try inst.runtime.startDial(locator.value, options, operation_id, .{
        .ctx = inst,
        .reserve = reserveOpenEventForObserver,
        .release = releaseOpenEventForObserver,
        .abandoned = releaseOpenEventForObserver,
        .opened = openSucceeded,
        .failed = openFailedEvent,
    });
    inst.next_operation_id += 1;
    return operation_id;
}

/// Begin listener construction under one stable identity. Bounded and staged
/// providers both resolve through LISTENER_READY or LISTENER_FAILED; closing
/// the identity cancels pending setup or closes the active listener.
pub export fn pancake_driver_listen(
    raw: ?*c.PancakeDriverLoop,
    transport: ?[*]const u8,
    transport_len: usize,
    designator: ?[*]const u8,
    designator_len: usize,
    options: ?*const shared.PancakeTransportOperationOptions,
    out_listener: ?*u64,
) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    if (reentrancyCode(inst, "listen")) |code| return code;
    const slot = out_listener orelse return PANCAKE_ERR_NULL_POINTER;
    const transport_bytes = shared.sliceFromC(transport, transport_len) catch |err| return shared.marshalErrorToCode(err);
    const designator_bytes = shared.sliceFromC(designator, designator_len) catch |err| return shared.marshalErrorToCode(err);
    const operation_options = operationOptionsCode(options) catch return PANCAKE_ERR_INVALID_ARGUMENT;
    const id = inst.next_listener;
    if (id == 0 or id == std.math.maxInt(u64)) return errToCode(error.IdentifierExhausted);
    inst.listeners.ensureUnusedCapacity(inst.allocator, 1) catch return errToCode(error.OutOfMemory);
    inst.listeners.putAssumeCapacity(@enumFromInt(id), .pending);
    inst.runtime.startListener(transport_bytes, designator_bytes, operation_options, id, .{
        .ctx = inst,
        .reserve = reserveOpenEventForObserver,
        .release = releaseOpenEventForObserver,
        .abandoned = abandonListenerEvent,
        .ready = listenerReady,
        .failed = listenerFailed,
    }) catch |err| {
        if (!inst.listeners.remove(@enumFromInt(id)))
            inst.runtime.noteTerminalFailure(error.ProviderContract);
        return operationErrorCode(inst, err);
    };
    inst.next_listener = id + 1;
    slot.* = id;
    return PANCAKE_OK;
}

fn listenerReady(ctx: *anyopaque, tag: u64, ready_listener: driver.HostRuntime.TransportListener) void {
    const inst: *Instance = @ptrCast(@alignCast(ctx));
    var listener = ready_listener;
    if (finishListener(inst, tag, &listener)) |activation_failure| {
        var failure = activation_failure;
        if (inst.runtime.closeListener(&listener)) |close_failure|
            failure.noteFailure(close_failure);
        if (!inst.listeners.remove(@enumFromInt(tag)))
            inst.runtime.noteTerminalFailure(error.ProviderContract);
        enqueueReservedEvent(inst, .{
            .listener_failed = .{
                .listener = tag,
                .failure = .init(failure),
            },
        });
        return;
    }
    enqueueReservedEvent(inst, .{ .listener_ready = tag });
}

fn listenerFailed(ctx: *anyopaque, tag: u64, failure: driver.OperationFailure) void {
    const inst: *Instance = @ptrCast(@alignCast(ctx));
    if (!inst.listeners.remove(@enumFromInt(tag)))
        inst.runtime.noteTerminalFailure(error.ProviderContract);
    enqueueReservedEvent(inst, .{
        .listener_failed = .{
            .listener = tag,
            .failure = .init(failure),
        },
    });
}

fn finishListener(
    inst: *Instance,
    id: u64,
    listener: *driver.HostRuntime.TransportListener,
) ?driver.OperationFailure {
    const state = inst.listeners.getPtr(@enumFromInt(id)) orelse
        return driver.OperationFailure.fromError(error.InvalidArgument);
    switch (state.*) {
        .pending => {},
        .active => return driver.OperationFailure.fromError(error.InvalidArgument),
    }
    var prepared = switch (inst.runtime.prepareListenerLocatorOutcome(listener)) {
        .ready => |prepared| prepared,
        .failed => |failure| return driver.OperationFailure.fromChain(failure),
    };
    var projection = LocatorProjection.init(inst.allocator, prepared.value, &.{}) catch |err| {
        prepared.deinit(inst.allocator);
        return inst.runtime.operationFailure(err);
    };
    inst.runtime.activateOwnedListener(listener, &prepared, id, .{
        .ctx = inst,
        .reserve = reserveOpenEventForObserver,
        .release = releaseOpenEventForObserver,
        .abandoned = releaseOpenEventForObserver,
        .opened = acceptOpened,
        .failed = acceptFailed,
    }) catch |err| {
        projection.deinit(inst.allocator);
        prepared.deinit(inst.allocator);
        return inst.runtime.operationFailure(err);
    };
    state.* = .{ .active = .{ .projection = projection } };
    return null;
}

/// Borrow one active listener's complete locator view. It remains valid until
/// that listener is advertised again, closed, or its loop is released.
pub export fn pancake_driver_listener_locator(
    raw: ?*c.PancakeDriverLoop,
    listener: u64,
    out_locator: ?*shared.PancakeLocatorView,
) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_locator orelse return PANCAKE_ERR_NULL_POINTER;
    const bound_listener = activeListener(inst, listener) catch |err| return activeListenerErrorCode(err);
    // Return the POD view by value. Its nested slices still borrow the
    // listener's owned locator/projection, but no pointer into the hash map's
    // movable value storage escapes this call.
    slot.* = bound_listener.projection.view;
    return PANCAKE_OK;
}

/// Query or copy opaque transport-owned state sufficient to restore this
/// listener's local address. The state is sensitive provider vocabulary, not
/// part of the public locator. A null/zero output is the size query.
pub export fn pancake_driver_listener_restoration_state(
    raw: ?*c.PancakeDriverLoop,
    listener: u64,
    out: ?[*]u8,
    cap: usize,
    out_len: ?*usize,
) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    if (reentrancyCode(inst, "listener_restoration_state")) |code| return code;
    const len_slot = out_len orelse return PANCAKE_ERR_NULL_POINTER;
    len_slot.* = 0;
    const bound = activeListener(inst, listener) catch |err| return activeListenerErrorCode(err);
    const dest: []u8 = if (cap == 0) &.{} else (out orelse return PANCAKE_ERR_NULL_POINTER)[0..cap];
    _ = bound;
    const needed = switch (inst.runtime.ownedListenerRestorationStateOutcome(listener, dest)) {
        .unsupported => {
            shared.setLastError("driver: listener has no restoration state", .{});
            return shared.PANCAKE_ERR_NOT_FOUND;
        },
        .size => |needed| needed,
        .failed => |failure| {
            const operation_failure = driver.OperationFailure.fromChain(failure);
            failure_output.setLastError("driver: listener restoration-state provider failed", operation_failure);
            return driver_error.code(operation_failure.kind);
        },
    };
    len_slot.* = needed;
    if (cap < needed) return PANCAKE_ERR_BUFFER_TOO_SMALL;
    return PANCAKE_OK;
}

/// Replace an active listener's advertised locator while retaining its
/// transport and identity posture. This is the wildcard/NAT policy seam: the
/// binding may know a public address the socket cannot discover, but the loop
/// remains the sole owner that validates and publishes the resulting locator.
pub export fn pancake_driver_listener_advertise(
    raw: ?*c.PancakeDriverLoop,
    listener: u64,
    locator_view: ?*const shared.PancakeLocatorView,
) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    if (reentrancyCode(inst, "listener_advertise")) |code| return code;
    inst.runtime.enterDriver();
    defer inst.runtime.leaveDriver();
    const bound = activeListener(inst, listener) catch |err| return activeListenerErrorCode(err);
    const view = locator_view orelse return PANCAKE_ERR_NULL_POINTER;
    const proposed = shared.locator_adapter.cloneView(inst.allocator, view) catch |err| return errToCode(err);
    defer model.freePeerLocator(inst.allocator, proposed);
    var prepared = switch (inst.runtime.prepareOwnedListenerAdvertisementOutcome(listener, proposed)) {
        .ready => |prepared| prepared,
        .failed => |failure| {
            const operation_failure = driver.OperationFailure.fromChain(failure);
            failure_output.setLastError("driver: listener advertisement failed", operation_failure);
            return driver_error.code(operation_failure.kind);
        },
    };
    var prepared_live = true;
    defer if (prepared_live) prepared.deinit(inst.allocator);
    var projection = LocatorProjection.init(inst.allocator, prepared.value, &.{}) catch |err|
        return operationErrorCode(inst, err);
    var projection_live = true;
    defer if (projection_live) projection.deinit(inst.allocator);
    inst.runtime.commitOwnedListenerAdvertisement(listener, &prepared) catch |err|
        return operationErrorCode(inst, err);
    prepared_live = false;
    bound.projection.deinit(inst.allocator);
    bound.projection = projection;
    projection_live = false;
    return PANCAKE_OK;
}

/// Select an active listener's retained locator as the Host's
/// `acceptable-location`. This changes policy without reallocating or
/// rebuilding locator metadata.
pub export fn pancake_driver_listener_select(raw: ?*c.PancakeDriverLoop, listener: u64) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    if (reentrancyCode(inst, "listener_select")) |code| return code;
    inst.runtime.enterDriver();
    defer inst.runtime.leaveDriver();
    const bound_listener = activeListener(inst, listener) catch |err| return activeListenerErrorCode(err);
    _ = bound_listener;
    const selected = inst.runtime.selectOwnedListener(listener) catch |err|
        return operationErrorCode(inst, err);
    if (!selected) {
        shared.setLastError("driver: listener locator is not retained by the host", .{});
        return shared.PANCAKE_ERR_NOT_FOUND;
    }
    return PANCAKE_OK;
}

/// Stop one listener and remove its advertised locator. Accepted sessions and
/// already queued ACCEPTED events remain valid. If this listener supplied the
/// selected acceptable location, the Host intentionally has no selection
/// until the caller selects another active listener.
pub export fn pancake_driver_listener_close(
    raw: ?*c.PancakeDriverLoop,
    listener: u64,
    out_failure: ?*failure_output.PancakeDriverFailure,
) i32 {
    shared.lastErrorClear();
    const failure_slot = switch (failure_output.claim(out_failure, "driver listener_close")) {
        .slot => |slot| slot,
        .refused => |code| return code,
    };
    const inst = instanceFrom(raw) orelse
        return failure_output.refuse(failure_slot, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
    // Terminal failure forbids new work, but never teardown. The provider
    // package remains leased until loop release, so closing a listener is both
    // valid and necessary after an unrelated provider violates its contract.
    if (reentrancyCode(inst, "listener_close")) |code|
        return failure_output.refuse(failure_slot, code, error.ReenteredHost);
    inst.runtime.enterDriver();
    defer inst.runtime.leaveDriver();
    const id: ListenerId = @enumFromInt(listener);
    if (!inst.listeners.contains(id)) {
        shared.setLastError("driver: unknown listener id", .{});
        return failure_output.refuse(failure_slot, shared.PANCAKE_ERR_NOT_FOUND, error.UnknownListener);
    }
    if (closeListenerById(inst, id)) |failure| {
        failure_output.setLastError("driver: listener close failed", failure);
        const code = driver_error.code(failure.kind);
        failure_output.project(failure_slot, code, failure);
        return code;
    }
    return PANCAKE_OK;
}

/// The one descriptor to park on: readable while any wire, resident,
/// listener, mailbox, or wake has pending work. Arm it once, before sharing
/// the loop pointer with any waking thread, and call `pancake_driver_step`
/// whenever it reads ready. Owned by the loop; never close it.
pub export fn pancake_driver_readiness_fd(raw: ?*c.PancakeDriverLoop, out_fd: ?*i32) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    if (reentrancyCode(inst, "readiness_fd")) |code| return code;
    const slot = out_fd orelse return PANCAKE_ERR_NULL_POINTER;
    const fd = inst.runtime.readinessDescriptor() catch |err| return errToCode(err);
    slot.* = fd;
    return PANCAKE_OK;
}

// ── Step, wake, events ───────────────────────────────────────────────────────

/// One loop step: accept what the listener has ready, then pump — apply
/// cross-thread settles, service ready wires and
/// residents, drain host actions (flushes execute here; completions queue as
/// events), and advance in-flight dial handshakes, direct and redeem alike.
/// Parks up to `timeout_ms` only when nothing is already pending; `-1` parks
/// until readiness, `0` never parks. Returns `PANCAKE_OK` when immediate work
/// was observed or an event remains queued, and `PANCAKE_ERR_WOULD_BLOCK` when
/// the loop is drained after that wait. Edge-triggered embedders therefore call
/// until WOULD_BLOCK before clearing readiness. Drain
/// `pancake_driver_next_event` after every call that returns OK.
pub export fn pancake_driver_step(raw: ?*c.PancakeDriverLoop, timeout_ms: i32) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    if (reentrancyCode(inst, "step")) |code| return code;
    // Events are the consumer's backpressure signal. Do not commit more
    // observable transitions until it drains what the prior step produced.
    if (inst.events_head < inst.events.items.len) return PANCAKE_OK;
    inst.stepping = true;
    defer inst.stepping = false;

    const progress = inst.runtime.stepAny(timeout_ms) catch |err| {
        return operationErrorCode(inst, err);
    };
    if (inst.runtime.listenerOwnershipRetired() and
        !releaseRetiredListenerMetadata(inst))
        inst.runtime.noteTerminalFailure(error.ProviderContract);
    if (progress == null and inst.events_head >= inst.events.items.len)
        return PANCAKE_ERR_WOULD_BLOCK;
    return PANCAKE_OK;
}

/// Release the calling thread's exclusive claim on the loop's host at a
/// quiescent boundary: call it after setup (`pancake_host_publish` and the
/// like claim the host for the thread that ran them), before another thread
/// begins stepping. The next verb from any thread re-claims; this is a
/// sequential handover, never permission for concurrent access. In an
/// unsafe build the claim tracking compiles out and this is a no-op.
pub export fn pancake_driver_detach_thread(raw: ?*c.PancakeDriverLoop) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    if (reentrancyCode(inst, "detach_thread")) |code| return code;
    inst.runtime.detachThread() catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// Make a parked loop return from its wait, from any thread — the one
/// cross-thread verb on this family. Arm the readiness descriptor before
/// sharing the loop pointer with a waking thread.
pub export fn pancake_driver_wake(raw: ?*c.PancakeDriverLoop) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    inst.runtime.wakeReadiness() catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// Pop the oldest loop event into `out`, or `PANCAKE_ERR_WOULD_BLOCK` when
/// none is pending (drain in a loop until that code). Borrowed views in the
/// popped event — an OPEN_FAILED error name, a COMPLETION action's bytes and
/// children — stay valid until the next call. Completion payloads are freed
/// then; error names are static.
pub export fn pancake_driver_next_event(raw: ?*c.PancakeDriverLoop, out: ?*c.PancakeDriverEvent) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    if (reentrancyCode(inst, "next_event")) |code| return code;
    const slot = out orelse return PANCAKE_ERR_NULL_POINTER;
    if (inst.handed_completion) |action| {
        inst.runtime.freeAction(action);
        inst.handed_completion = null;
    }
    const event = while (popEvent(inst)) |candidate| {
        if (eventNamesLiveSession(inst, candidate)) break candidate;
        freeEventPayload(inst, candidate);
    } else return PANCAKE_ERR_WOULD_BLOCK;
    slot.* = std.mem.zeroes(c.PancakeDriverEvent);
    switch (event) {
        .opened => |opened| {
            slot.kind = c.PANCAKE_DRIVER_EVENT_OPENED;
            slot.operation_id = opened.operation_id;
            slot.session = ch.embedding.sessionHandle(opened.session.hs);
        },
        .open_failed => |failed| {
            slot.kind = c.PANCAKE_DRIVER_EVENT_OPEN_FAILED;
            slot.operation_id = failed.operation_id;
            failed.failure.project(slot);
        },
        .listener_ready => |listener| {
            slot.kind = c.PANCAKE_DRIVER_EVENT_LISTENER_READY;
            slot.listener_id = listener;
        },
        .listener_failed => |failed| {
            slot.kind = c.PANCAKE_DRIVER_EVENT_LISTENER_FAILED;
            slot.listener_id = failed.listener;
            failed.failure.project(slot);
        },
        .accepted => |a| {
            slot.kind = c.PANCAKE_DRIVER_EVENT_ACCEPTED;
            slot.listener_id = a.listener;
            slot.session = ch.embedding.sessionHandle(a.session.hs);
        },
        .session_closed => |closed| {
            slot.kind = c.PANCAKE_DRIVER_EVENT_SESSION_CLOSED;
            slot.session = ch.embedding.sessionHandle(closed.session.hs);
            if (closed.failure) |failure| failure.project(slot);
        },
        .completion => |action| {
            slot.kind = c.PANCAKE_DRIVER_EVENT_COMPLETION;
            const code = ch.embedding.projectCompletion(inst.host_handle, action, &slot.action);
            if (code != PANCAKE_OK) {
                inst.runtime.freeAction(action);
                return code;
            }
            inst.handed_completion = action;
        },
    }
    return PANCAKE_OK;
}

/// Resolve a live remote capability's exporter session and ensure that one
/// loop-owned application handle claims it before the pointer is returned.
/// Repeated calls for an already claimed session return the same handle.
pub export fn pancake_driver_claim_reference_exporter(
    raw: ?*c.PancakeDriverLoop,
    reference: ?*const shared.PancakeReference,
    out_session: ?*?*ch.PancakeHostSession,
) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    if (reentrancyCode(inst, "claim_reference_exporter")) |code| return code;
    const ref = reference orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_session orelse return PANCAKE_ERR_NULL_POINTER;
    const session = inst.runtime.claimReferenceExporter(ref.id) catch |err| return errToCode(err);
    slot.* = if (session) |hs| ch.embedding.sessionHandle(hs) else null;
    return PANCAKE_OK;
}

/// Seal one loop-owned session's admission and begin or escalate its native
/// close barrier without releasing the handle.
pub export fn pancake_driver_session_close(
    raw: ?*c.PancakeDriverLoop,
    session: ?*ch.PancakeHostSession,
    options: ?*const ch.PancakeCloseOptions,
) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    if (!(inst.stepping and inst.runtime.withinCallback())) {
        if (reentrancyCode(inst, "session_close")) |code| return code;
    }
    const hs = ch.embedding.sessionFrom(session) orelse return PANCAKE_ERR_NULL_POINTER;
    const pending = ch.parseCloseOptions(options) catch |err| return ch.closeOptionsErrorCode("driver", err);
    inst.runtime.beginSessionClose(hs, pending) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// Observe one loop-owned session's native close barrier. CLOSED means its
/// transport is closed, while the handle remains valid for explicit release.
pub export fn pancake_driver_session_lifecycle_state(
    raw: ?*c.PancakeDriverLoop,
    session: ?*ch.PancakeHostSession,
    out_state: ?*u32,
) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    if (reentrancyCode(inst, "session_lifecycle_state")) |code| return code;
    const hs = ch.embedding.sessionFrom(session) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_state orelse return PANCAKE_ERR_NULL_POINTER;
    const status = inst.runtime.sessionCloseStatus(hs) catch |err| return errToCode(err);
    slot.* = switch (status.outcome) {
        .closed, .timed_out => ch.PANCAKE_LIFECYCLE_CLOSED,
        .pending => switch (status.phase) {
            .active => ch.PANCAKE_LIFECYCLE_ACTIVE,
            .finishing => ch.PANCAKE_LIFECYCLE_FINISHING,
            .cancel_pending => ch.PANCAKE_LIFECYCLE_TERMINATING,
            .terminating => ch.PANCAKE_LIFECYCLE_TERMINATING,
        },
    };
    return if (status.outcome == .timed_out) shared.PANCAKE_ERR_TIMEOUT else PANCAKE_OK;
}

/// Release one loop-owned session: flush what it queued, drop its wire, and
/// free the session — the loop spelling of `pancake_host_session_release`,
/// which must not be called on sessions this loop minted. Queued events
/// naming the session are invalidated by the wire-map removal and skipped
/// lazily at drain, so release does not scan the event backlog.
pub export fn pancake_driver_session_release(
    raw: ?*c.PancakeDriverLoop,
    session: ?*ch.PancakeHostSession,
) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    // As with listener close, terminal failure must not disable teardown. A
    // callback or active step must refuse before releaseWire drops the wire.
    if (reentrancyCode(inst, "session_release")) |code| return code;
    const hs = ch.embedding.sessionFrom(session) orelse return PANCAKE_ERR_NULL_POINTER;
    inst.runtime.releaseWire(hs) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// Begin delivering `session`'s inbound application frames: the embedder has
/// finished its post-open setup (its publishes and spawns), so a partner's
/// pipelined first frames can no longer outrun the objects they name. A
/// session surfaced by an OPENED or ACCEPTED event holds its inbound until
/// this call — handshake frames were never held, and bytes that arrived early
/// wait unread (a stream socket's kernel buffer; a resident link's bounded
/// parking) and replay in order now. Idempotent; a session already delivering
/// is a no-op. Every binding runtime calls this from its serve path.
pub export fn pancake_driver_session_serve(
    raw: ?*c.PancakeDriverLoop,
    session: ?*ch.PancakeHostSession,
) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    if (reentrancyCode(inst, "session_serve")) |code| return code;
    const hs = ch.embedding.sessionFrom(session) orelse return PANCAKE_ERR_NULL_POINTER;
    inst.runtime.attendSession(hs) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

// ── Last error ───────────────────────────────────────────────────────────────

/// Read this archive's per-thread last-error message into `out_buf`
/// (truncating), returning the full message length. Zero means no message.
pub export fn pancake_driver_last_error(out_buf: ?[*]u8, cap: usize) usize {
    return shared.lastErrorRead(out_buf, cap);
}

/// Clear this archive's per-thread last-error message.
pub export fn pancake_driver_clear_last_error() void {
    shared.lastErrorClear();
}
