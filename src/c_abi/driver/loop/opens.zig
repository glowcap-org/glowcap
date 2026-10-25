//! Own provider installation and loop-owned outbound open admission.

const std = @import("std");
const model = @import("model");
const driver = @import("driver");
const root = @import("../loop.zig");
const events = @import("events.zig");
const failure_output = @import("../failure_output.zig");
const shared = @import("c_abi_shared");
const c = @import("../mod.zig");

const Internal = root.Internal;
const Instance = Internal.Instance;
const GLOWCAP_OK = shared.GLOWCAP_OK;
const GLOWCAP_ERR_NULL_POINTER = shared.GLOWCAP_ERR_NULL_POINTER;
const GLOWCAP_ERR_INVALID_ARGUMENT = shared.GLOWCAP_ERR_INVALID_ARGUMENT;
const instanceFrom = Internal.instanceFrom;
const operationOptionsCode = Internal.operationOptionsCode;
const reentrancyCode = events.reentrancyCode;
const operationErrorCode = events.operationErrorCode;
const reserveOpenEventForObserver = events.reserveOpenEventForObserver;
const releaseOpenEventForObserver = events.releaseOpenEventForObserver;
const openSucceeded = events.openSucceeded;
const openFailedEvent = events.openFailedEvent;

// ── Transport providers ─────────────────────────────────────────────────────

/// Install a provider package atomically through the generic provider registry.
/// `provider.retain` runs inside the driver bracket, so a driver verb it calls
/// is refused as re-entry.
pub export fn glowcap_driver_add_provider(
    raw: ?*c.GlowcapDriverLoop,
    provider: ?*const shared.GlowcapTransportProvider,
    out_failure: ?*failure_output.GlowcapDriverFailure,
) i32 {
    shared.lastErrorClear();
    const failure_slot = switch (failure_output.claim(out_failure, "driver add_provider")) {
        .slot => |slot| slot,
        .refused => |code| return code,
    };
    const inst = instanceFrom(raw) orelse
        return failure_output.refuse(failure_slot, GLOWCAP_ERR_NULL_POINTER, error.NullPointer);
    if (reentrancyCode(inst, "add_provider")) |code|
        return failure_output.refuse(failure_slot, code, error.ReenteredHost);
    // The provider's retain callback runs inside, so a verb it calls back
    // into is refused as re-entry.
    inst.runtime.enterDriver();
    defer inst.runtime.leaveDriver();
    const outcome = inst.providers.addProvider(provider);
    if (outcome.failure) |failure| failure_output.project(failure_slot, outcome.result, failure);
    return outcome.result;
}

/// Report whether the loop's provider registry owns `transport`.
pub export fn glowcap_driver_has_transport(
    raw: ?*c.GlowcapDriverLoop,
    transport: ?[*]const u8,
    transport_len: usize,
    out_present: ?*u8,
) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(raw) orelse return GLOWCAP_ERR_NULL_POINTER;
    const slot = out_present orelse return GLOWCAP_ERR_NULL_POINTER;
    const name = shared.sliceFromC(transport, transport_len) catch |err| return shared.marshalErrorToCode(err);
    if (name.len == 0) {
        shared.setLastError("driver: has_transport requires a non-empty transport name", .{});
        return GLOWCAP_ERR_INVALID_ARGUMENT;
    }
    slot.* = @intFromBool(inst.runtime.hasTransport(name));
    return GLOWCAP_OK;
}

// ── Dial, listen, readiness ──────────────────────────────────────────────────

/// Begin a nonblocking dial toward one complete canonical OCapN peer locator
/// and answer at once with an operation id. Transport completion and the handshake
/// advance across steps under the handshake budget. OPENED or OPEN_FAILED
/// carries the operation id.
pub export fn glowcap_driver_dial(
    raw: ?*c.GlowcapDriverLoop,
    locator_view: ?*const shared.GlowcapLocatorView,
    options: ?*const shared.GlowcapTransportOperationOptions,
    out_operation_id: ?*u64,
) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(raw) orelse return GLOWCAP_ERR_NULL_POINTER;
    if (reentrancyCode(inst, "dial")) |code| return code;
    const slot = out_operation_id orelse return GLOWCAP_ERR_NULL_POINTER;
    const operation_id = beginDial(inst, locator_view, options) catch |err| return operationErrorCode(inst, err);
    slot.* = operation_id;
    return GLOWCAP_OK;
}

/// Begin adoption of one externally established provider connection. The
/// subject is meaningful only to the provider registered under `transport`.
/// The driver never interprets it. `role` selects the Host/session half. The
/// terminal OPENED or OPEN_FAILED event carries the returned operation id.
pub export fn glowcap_driver_adopt_external(
    raw: ?*c.GlowcapDriverLoop,
    transport: ?[*]const u8,
    transport_len: usize,
    subject: u64,
    role: u32,
    out_operation_id: ?*u64,
) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(raw) orelse return GLOWCAP_ERR_NULL_POINTER;
    if (reentrancyCode(inst, "adopt_external")) |code| return code;
    const slot = out_operation_id orelse return GLOWCAP_ERR_NULL_POINTER;
    const adoption_role: driver.HostRuntime.ExternalAdoptionRole = switch (role) {
        c.GLOWCAP_DRIVER_ADOPT_DIALED => .dialed,
        c.GLOWCAP_DRIVER_ADOPT_ACCEPTED => .accepted,
        else => {
            shared.setLastError("driver: adopt_external role must be GLOWCAP_DRIVER_ADOPT_DIALED or GLOWCAP_DRIVER_ADOPT_ACCEPTED", .{});
            return GLOWCAP_ERR_INVALID_ARGUMENT;
        },
    };
    const operation_id = beginExternalAdoption(inst, transport, transport_len, subject, adoption_role) catch |err|
        return operationErrorCode(inst, err);
    slot.* = operation_id;
    return GLOWCAP_OK;
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
    locator_view: ?*const shared.GlowcapLocatorView,
    options_raw: ?*const shared.GlowcapTransportOperationOptions,
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
