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

const shared = @import("c_abi_shared");
const ch = @import("c_abi_host");
const c = @import("mod.zig");

const crypto = foundation.crypto;
const LocatorProjection = shared.locator_adapter.Projection;

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
    core: *driver_core.Host,
    runtime: driver.HostRuntime,
    providers: provider_registry.Registry,
    /// One listener per transport, keyed by stable loop-minted ids. The Host
    /// advertises one locator per transport too, so refusing a duplicate
    /// transport keeps listener state and Host authority in the same shape.
    listeners: std.AutoHashMapUnmanaged(ListenerId, BoundListener) = .{},
    next_listener: u64 = 1,
    next_ticket: u64 = 1,
    /// FIFO event queue: `events[events_head..]` is pending; the storage
    /// compacts when drained.
    events: std.ArrayListUnmanaged(OwnedEvent) = .empty,
    events_head: usize = 0,
    /// Queue slots promised to admitted dial/accept operations. Their terminal
    /// callbacks publish without allocation; admission owns capacity failure.
    open_event_reservations: usize = 0,
    /// The completion view handed out by the last
    /// `pancake_driver_next_event`, freed by the next one — the byte-fed
    /// queue's borrow contract, one tier up. Error names are static.
    handed_completion: ?driver_core.HostAction = null,
    stepping: bool = false,
    /// A post-commit boundary failed and the loop can no longer promise that
    /// every transition is observable. Sticky and fail-stop: release remains
    /// valid, while every operational verb refuses.
    event_channel_failed: bool = false,

    fn io(self: *Instance) std.Io {
        return self.threaded.io();
    }
};

/// Listener ids belong to one loop instance and are never reused during its
/// lifetime. The C projection is `u64`; this type keeps that namespace from
/// being confused with dial tickets inside Zig.
const ListenerId = enum(u64) { _ };

const BoundListener = struct {
    listener: driver.HostRuntime.TransportListener,
    locator: model.PeerLocator,
    projection: LocatorProjection,

    fn transportName(self: *const BoundListener) []const u8 {
        return self.listener.transportName();
    }

    fn designatorScheme(self: *const BoundListener) net.netlayer.DesignatorScheme {
        return self.listener.designatorScheme();
    }

    fn close(self: *BoundListener, inst: *Instance) void {
        inst.runtime.closeListener(&self.listener);
        self.projection.deinit(inst.allocator);
        model.freePeerLocator(inst.allocator, self.locator);
    }
};

/// One queued loop event, in owned form; projection to C happens at pop.
const OwnedEvent = union(enum) {
    opened: struct { ticket: u64, session: SessionEventRef },
    open_failed: struct { ticket: u64, message: []const u8 },
    accepted: struct { listener: u64, session: SessionEventRef },
    session_closed: SessionEventRef,
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
        const wire = inst.runtime.wires.get(self.peer_id) orelse return false;
        return wire.session == self.hs;
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
    return switch (err) {
        error.OutOfMemory => shared.PANCAKE_ERR_INTERNAL,
        error.InvalidArgument,
        error.UnknownTransport,
        error.InvalidAddress,
        error.DesignatorUnavailable,
        error.ListenerAlreadyActive,
        error.ReadinessDescriptorConflict,
        error.ReadinessUnavailable,
        error.MissingAdvertisedLocator,
        => PANCAKE_ERR_INVALID_ARGUMENT,
        error.HandshakeTimedOut, error.WaitTimedOut => shared.PANCAKE_ERR_TIMEOUT,
        error.PendingOpenLimitReached => shared.PANCAKE_ERR_WOULD_BLOCK,
        error.ConnectionClosed, error.ConnectionLost, error.SessionCondemned => shared.PANCAKE_ERR_CLOSED,
        else => shared.PANCAKE_ERR_IO,
    };
}

fn claimHost(host: *ch.PancakeHost) !ch.embedding.DriverClaim {
    return (ch.embedding.claimForDriver(host) catch |err| {
        switch (err) {
            error.HostAlreadyOwned => shared.setLastError("driver: host already has a runtime owner", .{}),
            error.HostNotQuiescent => shared.setLastError("driver: host has live sessions or a borrowed adapter action", .{}),
            error.ReenteredHost => shared.setLastError("driver: host transfer refused inside a callback", .{}),
        }
        return error.InvalidArgument;
    }) orelse unreachable;
}

fn hostOptions(core: *const driver_core.Host, options: c.PancakeDriverOptions) driver.HostRuntime.Options {
    return .{
        .frame_cap = core.opts.limits.max_frame_bytes,
        .wire_buffer_bytes = options.wire_buffer_bytes,
        .max_pending_opens = options.max_pending_opens,
        .codec = core.opts.codec,
        .captp_version = core.opts.captp_version,
        .handshake = .{ .ms = @intCast(options.handshake_ms) },
        .settle = .{ .ms = @intCast(options.settle_ms) },
    };
}

// ── Event queue ──────────────────────────────────────────────────────────────

fn failEventChannel(inst: *Instance) void {
    inst.event_channel_failed = true;
}

fn compactEventsIfDrained(inst: *Instance) void {
    if (inst.events_head < inst.events.items.len) return;
    inst.events.clearRetainingCapacity();
    inst.events_head = 0;
}

/// Queue one event. True on success. False means ownership remains with the
/// caller and the loop is terminal: a committed transition cannot continue
/// after its observable event is lost.
fn enqueueEvent(inst: *Instance, event: OwnedEvent) bool {
    if (inst.event_channel_failed or inst.providers.failed()) return false;
    compactEventsIfDrained(inst);
    const promised = std.math.add(usize, inst.events.items.len, inst.open_event_reservations) catch {
        failEventChannel(inst);
        return false;
    };
    const required = std.math.add(usize, promised, 1) catch {
        failEventChannel(inst);
        return false;
    };
    inst.events.ensureTotalCapacity(inst.allocator, required) catch {
        failEventChannel(inst);
        return false;
    };
    inst.events.appendAssumeCapacity(event);
    return true;
}

fn reserveOpenEvent(inst: *Instance) !void {
    compactEventsIfDrained(inst);
    const promised = std.math.add(usize, inst.events.items.len, inst.open_event_reservations) catch
        return error.OutOfMemory;
    const required = std.math.add(usize, promised, 1) catch return error.OutOfMemory;
    try inst.events.ensureTotalCapacity(inst.allocator, required);
    inst.open_event_reservations += 1;
}

fn releaseOpenEventReservation(inst: *Instance) void {
    std.debug.assert(inst.open_event_reservations != 0);
    inst.open_event_reservations -= 1;
}

fn reserveOpenEventForObserver(ctx: *anyopaque, _: u64) anyerror!void {
    const inst: *Instance = @ptrCast(@alignCast(ctx));
    try reserveOpenEvent(inst);
}

fn releaseOpenEventForObserver(ctx: *anyopaque, _: u64) void {
    const inst: *Instance = @ptrCast(@alignCast(ctx));
    releaseOpenEventReservation(inst);
}

fn enqueueReservedOpenEvent(inst: *Instance, event: OwnedEvent) bool {
    releaseOpenEventReservation(inst);
    if (inst.event_channel_failed or inst.providers.failed()) return false;
    inst.events.appendAssumeCapacity(event);
    return true;
}

fn terminalCode(inst: *const Instance) ?i32 {
    if (inst.providers.terminalCode()) |code| return code;
    if (!inst.event_channel_failed) return null;
    shared.setLastError("driver: the loop could not preserve a committed event; release the loop", .{});
    return shared.PANCAKE_ERR_INTERNAL;
}

fn operationErrorCode(inst: *const Instance, err: anyerror) i32 {
    return terminalCode(inst) orelse errToCode(err);
}

fn freeEventPayload(inst: *Instance, event: OwnedEvent) void {
    switch (event) {
        .completion => |action| inst.core.freeAction(action),
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
        .session_closed => |session| session.isLive(inst),
        .open_failed, .completion => true,
    };
}

// ── Host observer seams ──────────────────────────────────────────────────

/// The completion sink installed on the poll face: settled/failed actions
/// with no in-process claimer queue as COMPLETION events. Best-effort under
/// allocation failure the loop becomes terminal: the committed completion
/// cannot be rolled back or silently discarded. This callback consumes the
/// action in both cases.
fn sinkTake(ctx: *anyopaque, action: driver_core.HostAction) bool {
    const inst: *Instance = @ptrCast(@alignCast(ctx));
    if (!enqueueEvent(inst, .{ .completion = action })) inst.core.freeAction(action);
    return true;
}

/// The close observer: a wire the pump closes queues a SESSION_CLOSED event.
/// Failure to preserve the close event makes the loop terminal.
fn observeClose(ctx: *anyopaque, hs: *driver_core.HostSession) void {
    const inst: *Instance = @ptrCast(@alignCast(ctx));
    _ = enqueueEvent(inst, .{ .session_closed = .init(hs) });
}

/// A ticketed open finished its handshake inside a step; queue OPENED under
/// its ticket. Admission reserved the queue slot, so this callback cannot
/// allocate after the session commits.
fn openSucceeded(ctx: *anyopaque, tag: u64, session: *driver_core.HostSession) void {
    const inst: *Instance = @ptrCast(@alignCast(ctx));
    if (!enqueueReservedOpenEvent(inst, .{ .opened = .{ .ticket = tag, .session = .init(session) } })) {
        inst.runtime.releaseWire(session);
    }
}

/// A ticketed open failed after the host unwound its in-flight session. Queue
/// OPEN_FAILED with the error's static name. Admission reserved the queue slot,
/// so failure publication cannot allocate after the operation commits.
fn openFailedEvent(ctx: *anyopaque, tag: u64, err: anyerror) void {
    const inst: *Instance = @ptrCast(@alignCast(ctx));
    _ = enqueueReservedOpenEvent(inst, .{
        .open_failed = .{ .ticket = tag, .message = @errorName(err) },
    });
}

/// The accept observer's opened arm: an admitted accept finished its handshake;
/// queue the ACCEPTED event under its listener id. The accept step reserved
/// the queue slot before admitting the connection.
fn acceptOpened(ctx: *anyopaque, tag: u64, session: *driver_core.HostSession) void {
    const inst: *Instance = @ptrCast(@alignCast(ctx));
    if (!enqueueReservedOpenEvent(inst, .{ .accepted = .{ .listener = tag, .session = .init(session) } })) {
        inst.runtime.releaseWire(session);
    }
}

/// The accept observer's failed arm: a connector never completed its
/// handshake and the host already unwound it. Deliberately quiet — a stalled
/// or hostile connector is listener hygiene, not an embedder event, exactly
/// as the blocking accept swallowed it.
fn acceptFailedEvent(ctx: *anyopaque, _: u64, _: anyerror) void {
    const inst: *Instance = @ptrCast(@alignCast(ctx));
    releaseOpenEventReservation(inst);
}

// ── Lifecycle ────────────────────────────────────────────────────────────────

/// Move a byte-fed Host with no live sessions or borrowed action into a native
/// loop. Unpopped actions move with the Host and are first consumed by the driver.
/// Failure leaves the caller as the Host's runtime owner; success transfers
/// transport execution, action draining, session release, and terminal Host
/// release to the returned loop. Every construction option must be positive;
/// the generic loop starts with no transports, so install provider packages
/// before dialing or listening. Released with `pancake_driver_release`.
pub export fn pancake_driver_take_host(
    host: ?*ch.PancakeHost,
    options: ?*const c.PancakeDriverOptions,
    out_loop: ?*?*c.PancakeDriverLoop,
) i32 {
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
        opts.handshake_ms == 0 or opts.handshake_ms > c.PANCAKE_DRIVER_MAX_WAIT_MS or
        opts.settle_ms == 0 or opts.settle_ms > c.PANCAKE_DRIVER_MAX_WAIT_MS)
    {
        shared.setLastError("driver: buffer/open limits must be positive and wait budgets must be in 1..PANCAKE_DRIVER_MAX_WAIT_MS", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    }
    const claim = claimHost(host_handle) catch |err| return errToCode(err);
    const inst = buildInstance(
        claim,
        host_handle,
        hostOptions(claim.core(), opts),
    ) catch |err| {
        claim.rollback();
        return errToCode(err);
    };
    slot.* = @ptrCast(inst);
    return PANCAKE_OK;
}

fn buildInstance(
    claim: ch.embedding.DriverClaim,
    host_handle: *ch.PancakeHost,
    opts: driver.HostRuntime.Options,
) !*Instance {
    const alloc = claim.allocator();
    const inst = try alloc.create(Instance);
    errdefer alloc.destroy(inst);
    inst.* = .{
        .allocator = alloc,
        .threaded = std.Io.Threaded.init(alloc, .{}),
        .host_handle = host_handle,
        .core = claim.core(),
        .runtime = undefined,
        .providers = undefined,
    };
    errdefer inst.threaded.deinit();
    inst.providers = provider_registry.Registry.init(alloc, inst.io());
    inst.runtime = try driver.HostRuntime.initWithCore(alloc, inst.io(), inst.core, &.{}, opts);
    errdefer inst.runtime.deinit();
    // Mint the settle mailbox now, so its wake descriptor is in the
    // readiness set from the moment the set is armed.
    _ = try inst.runtime.settleMailbox();
    inst.runtime.setCompletionSink(.{ .ctx = inst, .take = sinkTake });
    inst.runtime.setCloseObserver(.{ .ctx = inst, .closed = observeClose });
    return inst;
}

/// Release the loop and everything it owns: listeners, in-flight opens,
/// queued events, every live wire, and then the wrapped host itself (with
/// `pancake_host_release`'s exact semantics). Do not release the host handle
/// separately. Null is a no-op; refused from inside a callback.
pub export fn pancake_driver_release(raw: ?*c.PancakeDriverLoop) i32 {
    const inst = instanceFrom(raw) orelse return PANCAKE_OK;
    if (inst.core.in_callback) {
        shared.setLastError("driver: release refused inside a callback", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    }
    var listener_it = inst.listeners.iterator();
    while (listener_it.next()) |entry| {
        entry.value_ptr.close(inst);
    }
    inst.listeners.deinit(inst.allocator);
    while (popEvent(inst)) |event| freeEventPayload(inst, event);
    inst.events.deinit(inst.allocator);
    if (inst.handed_completion) |action| inst.core.freeAction(action);
    inst.runtime.deinit();
    std.debug.assert(inst.open_event_reservations == 0);
    inst.providers.deinit();
    ch.embedding.releaseFromDriver(inst.host_handle);
    inst.threaded.deinit();
    const alloc = inst.allocator;
    alloc.destroy(inst);
    return PANCAKE_OK;
}

// ── Transport providers ─────────────────────────────────────────────────────

/// Install a provider package atomically through the generic provider registry.
pub export fn pancake_driver_add_provider(
    raw: ?*c.PancakeDriverLoop,
    provider: ?*const shared.PancakeTransportProvider,
) i32 {
    const inst = instanceFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    if (terminalCode(inst)) |code| return code;
    return inst.providers.addProvider(&inst.runtime, provider);
}

/// Report whether the loop's provider registry owns `transport`.
pub export fn pancake_driver_has_transport(
    raw: ?*c.PancakeDriverLoop,
    transport: ?[*]const u8,
    transport_len: usize,
    out_present: ?*u8,
) i32 {
    const inst = instanceFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    if (terminalCode(inst)) |code| return code;
    const slot = out_present orelse return PANCAKE_ERR_NULL_POINTER;
    const name = shared.sliceFromC(transport, transport_len) catch |err| return shared.marshalErrorToCode(err);
    if (name.len == 0) return PANCAKE_ERR_INVALID_ARGUMENT;
    slot.* = @intFromBool(inst.runtime.hasTransport(name));
    return PANCAKE_OK;
}

// ── Dial, listen, readiness ──────────────────────────────────────────────────

/// Begin a nonblocking dial toward one complete canonical OCapN peer locator
/// and answer at once with a ticket. Transport completion and the handshake
/// advance across steps under the handshake budget; OPENED or OPEN_FAILED
/// carries the ticket.
pub export fn pancake_driver_dial(
    raw: ?*c.PancakeDriverLoop,
    locator_view: ?*const shared.PancakeLocatorView,
    out_ticket: ?*u64,
) i32 {
    const inst = instanceFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    if (terminalCode(inst)) |code| return code;
    const slot = out_ticket orelse return PANCAKE_ERR_NULL_POINTER;
    const ticket = beginDial(inst, locator_view) catch |err| return operationErrorCode(inst, err);
    slot.* = ticket;
    return PANCAKE_OK;
}

/// Begin adoption of one externally established provider connection. The
/// subject is meaningful only to the provider registered under `transport`;
/// the driver never interprets it. `role` selects the Host/session half; the
/// terminal OPENED or OPEN_FAILED event carries the returned ticket.
pub export fn pancake_driver_adopt_external(
    raw: ?*c.PancakeDriverLoop,
    transport: ?[*]const u8,
    transport_len: usize,
    subject: u64,
    role: u32,
    out_ticket: ?*u64,
) i32 {
    const inst = instanceFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    if (terminalCode(inst)) |code| return code;
    const slot = out_ticket orelse return PANCAKE_ERR_NULL_POINTER;
    const adoption_role: driver.HostRuntime.ExternalAdoptionRole = switch (role) {
        c.PANCAKE_DRIVER_ADOPT_DIALED => .dialed,
        c.PANCAKE_DRIVER_ADOPT_ACCEPTED => .accepted,
        else => return PANCAKE_ERR_INVALID_ARGUMENT,
    };
    const ticket = beginExternalAdoption(inst, transport, transport_len, subject, adoption_role) catch |err|
        return operationErrorCode(inst, err);
    slot.* = ticket;
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
    const ticket = inst.next_ticket;
    if (ticket == std.math.maxInt(u64)) return error.IdentifierExhausted;
    const observer: driver.HostRuntime.SessionOpenObserver = .{
        .ctx = inst,
        .reserve = reserveOpenEventForObserver,
        .release = releaseOpenEventForObserver,
        .opened = openSucceeded,
        .failed = openFailedEvent,
    };
    const provider_subject = std.math.cast(usize, subject) orelse return error.InvalidArgument;
    try inst.runtime.startAdoptExternal(bytes, provider_subject, role, ticket, observer);
    inst.next_ticket += 1;
    return ticket;
}

fn beginDial(
    inst: *Instance,
    locator_view: ?*const shared.PancakeLocatorView,
) !u64 {
    const view = locator_view orelse return error.InvalidArgument;
    var hints: [shared.locator_adapter.inline_hint_capacity]model.HintEntry = undefined;
    var locator = shared.locator_adapter.BorrowedLocator.init(inst.allocator, view, &hints) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidLocatorView => return error.InvalidArgument,
    };
    defer locator.deinit(inst.allocator);
    const ticket = inst.next_ticket;
    if (ticket == std.math.maxInt(u64)) return error.IdentifierExhausted;
    try inst.runtime.startConnectLocator(locator.value, ticket, .{
        .ctx = inst,
        .reserve = reserveOpenEventForObserver,
        .release = releaseOpenEventForObserver,
        .opened = openSucceeded,
        .failed = openFailedEvent,
    });
    inst.next_ticket += 1;
    return ticket;
}

/// Bind a listener through the HostRuntime provider registry and record it under a
/// stable listener id. Accepted sessions arrive as ACCEPTED events carrying
/// that id. A loop owns at most one listener per transport, matching the
/// Host's locator authority.
pub export fn pancake_driver_listen(
    raw: ?*c.PancakeDriverLoop,
    transport: ?[*]const u8,
    transport_len: usize,
    designator: ?[*]const u8,
    designator_len: usize,
    out_listener: ?*u64,
) i32 {
    const inst = instanceFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    if (terminalCode(inst)) |code| return code;
    const slot = out_listener orelse return PANCAKE_ERR_NULL_POINTER;
    const transport_bytes = shared.sliceFromC(transport, transport_len) catch |err| return shared.marshalErrorToCode(err);
    const designator_bytes = shared.sliceFromC(designator, designator_len) catch |err| return shared.marshalErrorToCode(err);
    slot.* = listenImpl(inst, transport_bytes, designator_bytes) catch |err| return operationErrorCode(inst, err);
    return PANCAKE_OK;
}

fn listenImpl(inst: *Instance, transport: []const u8, designator: []const u8) !u64 {
    var existing_it = inst.listeners.valueIterator();
    while (existing_it.next()) |existing| {
        if (std.mem.eql(u8, existing.transportName(), transport)) {
            shared.setLastError("driver: listen: this transport already has a listener", .{});
            return error.InvalidArgument;
        }
    }
    var listener = inst.runtime.bindListener(transport, designator) catch |err| {
        if (err == error.UnknownTransport) shared.setLastError("driver: listen: unsupported transport", .{});
        return err;
    };
    errdefer inst.runtime.closeListener(&listener);
    const local_locator = inst.runtime.listenerLocator(&listener) catch {
        shared.setLastError("driver: listener did not provide a valid locator", .{});
        return error.InvalidArgument;
    };
    defer model.freePeerLocator(inst.allocator, local_locator);
    if (listener.designatorScheme() == .key) {
        const expected = inst.core.node.publicKey().toDesignator();
        if (!std.mem.eql(u8, local_locator.designator, &expected)) {
            shared.setLastError("driver: listen: listener identity disagrees with host", .{});
            return error.InvalidArgument;
        }
    }
    const id = inst.next_listener;
    if (id == 0 or id == std.math.maxInt(u64)) return error.IdentifierExhausted;
    // Prepare and project the exact canonical value before the Host retains
    // it. Once retention succeeds, insertion is infallible, so the binding
    // view and the signed route cannot diverge during unwind.
    try inst.listeners.ensureUnusedCapacity(inst.allocator, 1);
    const locator = try inst.core.prepareAdvertisedLocator(inst.allocator, local_locator);
    errdefer model.freePeerLocator(inst.allocator, locator);
    var projection = try LocatorProjection.init(inst.allocator, locator, &.{});
    errdefer projection.deinit(inst.allocator);
    try inst.runtime.activateListener(&listener, id, .{
        .ctx = inst,
        .reserve = reserveOpenEventForObserver,
        .release = releaseOpenEventForObserver,
        .opened = acceptOpened,
        .failed = acceptFailedEvent,
    });
    try inst.core.retainPreparedAdvertisedLocator(locator);
    inst.listeners.putAssumeCapacity(@enumFromInt(id), .{
        .listener = listener,
        .locator = locator,
        .projection = projection,
    });
    inst.next_listener = id + 1;
    return id;
}

/// Borrow one active listener's complete locator view. It remains valid until
/// that listener is advertised again, closed, or its loop is released.
pub export fn pancake_driver_listener_locator(
    raw: ?*c.PancakeDriverLoop,
    listener: u64,
    out_locator: ?*shared.PancakeLocatorView,
) i32 {
    const inst = instanceFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    if (terminalCode(inst)) |code| return code;
    const slot = out_locator orelse return PANCAKE_ERR_NULL_POINTER;
    const bound_listener = inst.listeners.get(@enumFromInt(listener)) orelse {
        shared.setLastError("driver: unknown listener id", .{});
        return shared.PANCAKE_ERR_NOT_FOUND;
    };
    // Return the POD view by value. Its nested slices still borrow the
    // listener's owned locator/projection, but no pointer into the hash map's
    // movable value storage escapes this call.
    slot.* = bound_listener.projection.view;
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
    const inst = instanceFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    if (terminalCode(inst)) |code| return code;
    const bound = inst.listeners.getPtr(@enumFromInt(listener)) orelse {
        shared.setLastError("driver: unknown listener id", .{});
        return shared.PANCAKE_ERR_NOT_FOUND;
    };
    const view = locator_view orelse return PANCAKE_ERR_NULL_POINTER;
    const proposed = shared.locator_adapter.cloneView(inst.allocator, view) catch |err| return errToCode(err);
    defer model.freePeerLocator(inst.allocator, proposed);
    const canonical = inst.runtime.canonicalizeListenerLocator(&bound.listener, proposed) catch |err|
        return operationErrorCode(inst, err);
    advertiseListener(inst, bound, canonical) catch |err| {
        model.freePeerLocator(inst.allocator, canonical);
        return operationErrorCode(inst, err);
    };
    return PANCAKE_OK;
}

fn advertiseListener(inst: *Instance, bound: *BoundListener, locator: model.PeerLocator) !void {
    const transport = bound.transportName();
    const scheme = bound.designatorScheme();
    if (!std.mem.eql(u8, locator.transport, transport)) {
        shared.setLastError("driver: advertised locator changed the listener transport", .{});
        return error.InvalidArgument;
    }
    if (scheme == .key) {
        const expected = inst.core.node.publicKey().toDesignator();
        if (!std.mem.eql(u8, locator.designator, &expected)) {
            shared.setLastError("driver: listener advertised identity disagrees with host", .{});
            return error.InvalidArgument;
        }
    }

    const complete = try inst.core.prepareAdvertisedLocator(inst.allocator, locator);
    errdefer model.freePeerLocator(inst.allocator, complete);
    var projection = try LocatorProjection.init(inst.allocator, complete, &.{});
    errdefer projection.deinit(inst.allocator);
    try inst.core.retainPreparedAdvertisedLocator(complete);
    bound.projection.deinit(inst.allocator);
    model.freePeerLocator(inst.allocator, bound.locator);
    model.freePeerLocator(inst.allocator, locator);
    bound.locator = complete;
    bound.projection = projection;
}

/// Select an active listener's retained locator as the Host's
/// `acceptable-location`. This changes policy without reallocating or
/// rebuilding locator metadata.
pub export fn pancake_driver_listener_select(raw: ?*c.PancakeDriverLoop, listener: u64) i32 {
    const inst = instanceFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    if (terminalCode(inst)) |code| return code;
    const bound_listener = inst.listeners.get(@enumFromInt(listener)) orelse {
        shared.setLastError("driver: unknown listener id", .{});
        return shared.PANCAKE_ERR_NOT_FOUND;
    };
    if (!inst.core.selectAdvertisedLocator(bound_listener.transportName())) {
        shared.setLastError("driver: listener locator is not retained by the host", .{});
        return shared.PANCAKE_ERR_NOT_FOUND;
    }
    return PANCAKE_OK;
}

/// Stop one listener and remove its advertised locator. Accepted sessions and
/// already queued ACCEPTED events remain valid. If this listener supplied the
/// selected acceptable location, the Host intentionally has no selection
/// until the caller selects another active listener.
pub export fn pancake_driver_listener_close(raw: ?*c.PancakeDriverLoop, listener: u64) i32 {
    const inst = instanceFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    if (terminalCode(inst)) |code| return code;
    const id: ListenerId = @enumFromInt(listener);
    if (!inst.listeners.contains(id)) {
        shared.setLastError("driver: unknown listener id", .{});
        return shared.PANCAKE_ERR_NOT_FOUND;
    }
    const removed = inst.listeners.fetchRemove(id).?;
    var bound_listener = removed.value;
    inst.core.removeAdvertisedLocator(bound_listener.transportName());
    bound_listener.close(inst);
    return PANCAKE_OK;
}

/// The one descriptor to park on: readable while any wire, resident,
/// listener, mailbox, or wake has pending work. Arm it once, before sharing
/// the loop pointer with any waking thread, and call `pancake_driver_step`
/// whenever it reads ready. Owned by the loop; never close it.
pub export fn pancake_driver_readiness_fd(raw: ?*c.PancakeDriverLoop, out_fd: ?*i32) i32 {
    const inst = instanceFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    if (terminalCode(inst)) |code| return code;
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
    const inst = instanceFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    if (terminalCode(inst)) |code| return code;
    if (inst.core.in_callback) {
        shared.setLastError("driver: step refused inside a callback", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    }
    if (inst.stepping) {
        shared.setLastError("driver: step reentered", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    }
    // Events are the consumer's backpressure signal. Do not commit more
    // observable transitions until it drains what the prior step produced.
    if (inst.events_head < inst.events.items.len) return PANCAKE_OK;
    inst.stepping = true;
    defer inst.stepping = false;

    var did_work = false;

    var listener_it = inst.listeners.iterator();
    while (listener_it.next()) |entry| {
        const listener = entry.value_ptr;
        const accepted = inst.runtime.acceptReady(&listener.listener) catch |err| {
            if (terminalCode(inst)) |code| return code;
            if (err == error.MissingAdvertisedLocator or err == error.OutOfMemory)
                return errToCode(err);
            shared.setLastError("driver: accept failed: {s}", .{@errorName(err)});
            continue;
        };
        did_work = did_work or accepted != 0;
    }

    const pump_timeout: i32 = if (did_work or inst.events_head < inst.events.items.len) 0 else timeout_ms;
    const progress = inst.runtime.stepAny(pump_timeout) catch |err| {
        if (terminalCode(inst)) |code| return code;
        return errToCode(err);
    };
    if (terminalCode(inst)) |code| return code;
    if (!did_work and progress == null and inst.events_head >= inst.events.items.len)
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
    const inst = instanceFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    if (terminalCode(inst)) |code| return code;
    if (inst.core.in_callback) {
        shared.setLastError("driver: detach_thread refused inside a callback", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    }
    inst.core.releaseDriverOwnership();
    return PANCAKE_OK;
}

/// Make a parked loop return from its wait, from any thread — the one
/// cross-thread verb on this family. Arm the readiness descriptor before
/// sharing the loop pointer with a waking thread.
pub export fn pancake_driver_wake(raw: ?*c.PancakeDriverLoop) i32 {
    const inst = instanceFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    inst.runtime.wakeReadiness();
    return PANCAKE_OK;
}

/// Pop the oldest loop event into `out`, or `PANCAKE_ERR_WOULD_BLOCK` when
/// none is pending (drain in a loop until that code). Borrowed views in the
/// popped event — an OPEN_FAILED error name, a COMPLETION action's bytes and
/// children — stay valid until the next call. Completion payloads are freed
/// then; error names are static.
pub export fn pancake_driver_next_event(raw: ?*c.PancakeDriverLoop, out: ?*c.PancakeDriverEvent) i32 {
    const inst = instanceFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    if (terminalCode(inst)) |code| return code;
    const slot = out orelse return PANCAKE_ERR_NULL_POINTER;
    if (inst.handed_completion) |action| {
        inst.core.freeAction(action);
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
            slot.ticket = opened.ticket;
            slot.session = ch.embedding.sessionHandle(opened.session.hs);
        },
        .open_failed => |failed| {
            slot.kind = c.PANCAKE_DRIVER_EVENT_OPEN_FAILED;
            slot.ticket = failed.ticket;
            slot.message = failed.message.ptr;
            slot.message_len = failed.message.len;
        },
        .accepted => |a| {
            slot.kind = c.PANCAKE_DRIVER_EVENT_ACCEPTED;
            slot.ticket = a.listener;
            slot.session = ch.embedding.sessionHandle(a.session.hs);
        },
        .session_closed => |session| {
            slot.kind = c.PANCAKE_DRIVER_EVENT_SESSION_CLOSED;
            slot.session = ch.embedding.sessionHandle(session.hs);
        },
        .completion => |action| {
            slot.kind = c.PANCAKE_DRIVER_EVENT_COMPLETION;
            const code = ch.embedding.projectCompletion(inst.host_handle, action, &slot.action);
            if (code != PANCAKE_OK) {
                inst.core.freeAction(action);
                return code;
            }
            inst.handed_completion = action;
        },
    }
    return PANCAKE_OK;
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
    const inst = instanceFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    const hs = ch.embedding.sessionFrom(session) orelse return PANCAKE_ERR_NULL_POINTER;
    if (hs.host != inst.core) {
        shared.setLastError("driver: session belongs to another loop", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    }
    inst.runtime.releaseWire(hs);
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
