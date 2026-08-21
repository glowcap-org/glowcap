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
const listener_state = @import("listener_state.zig");

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

const loop_events = @import("loop/events.zig");
const loop_listeners = @import("loop/listeners.zig");

const ListenerId = loop_listeners.ListenerId;
const ListenerState = listener_state.State;
const OwnedEvent = loop_events.OwnedEvent;

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

    pub fn io(self: *Instance) std.Io {
        return self.threaded.io();
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

const LoopInstance = Instance;
const LoopListenerId = ListenerId;
const instanceFromFn = instanceFrom;
const errToCodeFn = errToCode;
const claimHostFn = claimHost;
const adoptionErrorCodeFn = adoptionErrorCode;
const adoptionOptionsFn = adoptionOptions;
const operationOptionsFn = operationOptions;
const operationOptionsCodeFn = operationOptionsCode;

pub const Internal = struct {
    pub const Instance = LoopInstance;
    pub const ListenerId = LoopListenerId;
    pub const instanceFrom = instanceFromFn;
    pub const errToCode = errToCodeFn;
    pub const claimHost = claimHostFn;
    pub const adoptionErrorCode = adoptionErrorCodeFn;
    pub const adoptionOptions = adoptionOptionsFn;
    pub const operationOptions = operationOptionsFn;
    pub const operationOptionsCode = operationOptionsCodeFn;
};

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
