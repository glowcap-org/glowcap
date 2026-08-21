//! Own C listener construction, locator publication, selection, and retirement.

const std = @import("std");
const model = @import("model");
const driver = @import("driver");
const root = @import("../loop.zig");
const events = @import("events.zig");
const listener_state = @import("../listener_state.zig");
const driver_error = @import("../error.zig");
const failure_output = @import("../failure_output.zig");
const shared = @import("c_abi_shared");
const c = @import("../mod.zig");

const Internal = root.Internal;
const Instance = Internal.Instance;
const LocatorProjection = shared.locator_adapter.Projection;
const PANCAKE_OK = shared.PANCAKE_OK;
const PANCAKE_ERR_NULL_POINTER = shared.PANCAKE_ERR_NULL_POINTER;
const PANCAKE_ERR_INVALID_ARGUMENT = shared.PANCAKE_ERR_INVALID_ARGUMENT;
const PANCAKE_ERR_BUFFER_TOO_SMALL = shared.PANCAKE_ERR_BUFFER_TOO_SMALL;
const PANCAKE_ERR_WOULD_BLOCK = shared.PANCAKE_ERR_WOULD_BLOCK;
const instanceFrom = Internal.instanceFrom;
const errToCode = Internal.errToCode;
const operationOptionsCode = Internal.operationOptionsCode;
const reentrancyCode = events.reentrancyCode;
const operationErrorCode = events.operationErrorCode;
const reserveEvent = events.reserveEvent;
const reserveOpenEventForObserver = events.reserveOpenEventForObserver;
const releaseOpenEventForObserver = events.releaseOpenEventForObserver;
const releaseEventReservation = events.releaseEventReservation;
const enqueueReservedEvent = events.enqueueReservedEvent;
const abandonListenerEvent = events.abandonListenerEvent;
const retireListener = events.retireListener;
const acceptOpened = events.acceptOpened;
const acceptFailed = events.acceptFailed;

/// Listener ids belong to one loop instance and are never reused.
pub const ListenerId = enum(u64) { _ };

const ActiveListenerLookupError = listener_state.ActiveLookupError;

fn activeListener(inst: *Instance, listener: u64) ActiveListenerLookupError!*listener_state.Bound {
    return listener_state.lookupActive(inst, listener);
}

fn activeListenerErrorCode(err: ActiveListenerLookupError) i32 {
    return switch (err) {
        error.UnknownListener => shared.PANCAKE_ERR_NOT_FOUND,
        error.ListenerPending => shared.PANCAKE_ERR_WOULD_BLOCK,
        error.ListenerClosing => shared.PANCAKE_ERR_NOT_FOUND,
    };
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
    inst.listeners.putAssumeCapacity(@fromBackingInt(@intCast(id)), .pending);
    inst.runtime.startListener(transport_bytes, designator_bytes, operation_options, id, .{
        .ctx = inst,
        .reserve = reserveOpenEventForObserver,
        .release = releaseOpenEventForObserver,
        .abandoned = abandonListenerEvent,
        .ready = listenerReady,
        .failed = listenerFailed,
    }) catch |err| {
        if (!inst.listeners.remove(@fromBackingInt(@intCast(id))))
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
        if (!inst.listeners.remove(@fromBackingInt(@intCast(tag))))
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
    if (!inst.listeners.remove(@fromBackingInt(@intCast(tag))))
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
    const state = inst.listeners.getPtr(@fromBackingInt(@intCast(id))) orelse
        return driver.OperationFailure.fromError(error.InvalidArgument);
    switch (state.*) {
        .pending => {},
        .active, .closing, .retired => return driver.OperationFailure.fromError(error.InvalidArgument),
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
        .retired = retireListener,
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
    const id: ListenerId = @fromBackingInt(@intCast(listener));
    const state = inst.listeners.get(id) orelse {
        shared.setLastError("driver: unknown listener id", .{});
        return failure_output.refuse(failure_slot, shared.PANCAKE_ERR_NOT_FOUND, error.UnknownListener);
    };
    const pending = switch (state) {
        .retired => {
            std.debug.assert(inst.listeners.remove(id));
            return PANCAKE_OK;
        },
        .pending => true,
        .active, .closing => false,
    };
    const outcome = inst.runtime.stopOwnedListener(@backingInt(id));
    if (!outcome.found)
        return failure_output.refuse(failure_slot, PANCAKE_ERR_INVALID_ARGUMENT, error.ProviderContract);
    if (outcome.pending) {
        listener_state.markClosing(inst, listener);
        return PANCAKE_ERR_WOULD_BLOCK;
    }
    if (outcome.failure) |failure| {
        if (!pending) std.debug.assert(listener_state.remove(inst, listener));
        failure_output.setLastError("driver: listener close failed", failure);
        const code = driver_error.code(failure.kind);
        failure_output.project(failure_slot, code, failure);
        return code;
    }
    if (!pending) std.debug.assert(listener_state.remove(inst, listener));
    return PANCAKE_OK;
}
