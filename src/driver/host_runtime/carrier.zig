//! Physical carrier close, retirement, and wire allocation release.

const std = @import("std");

const foundation = @import("foundation");
const engine = @import("engine");
const net = @import("net");

const runtime = @import("../host_runtime.zig");

const HostRuntime = runtime.HostRuntime;
const Internal = runtime.Internal;
const OperationFailure = @import("../operation_failure.zig").OperationFailure;
const Wire = HostRuntime.Wire;
const transport_close_ms: i32 = 5_000;

pub fn progressCarrierCloseDeadlines(self: *HostRuntime) void {
    const now_ms = net.clock.nowMs(self.io);
    var wires = self.wires.valueIterator();
    while (wires.next()) |wire| {
        const deadline = wire.*.carrier_close_deadline_ms orelse continue;
        if (deadline <= now_ms) progressWireCarrierClose(self, wire.*);
    }
    var retiring = self.retiring_wires;
    while (retiring) |wire| {
        const next = wire.retiring_next;
        if (wire.carrier_close_deadline_ms) |deadline|
            if (deadline <= now_ms) progressWireCarrierClose(self, wire);
        retiring = next;
    }
}

/// Free one wire's transport and buffers. The caller owns the `wires` row;
/// the resident routing row leaves here with the link it routes.
pub fn freeWire(self: *HostRuntime, wire: *Wire) void {
    std.debug.assert(wire.carrierClosed());
    if (wire.close_event_reserved) {
        if (self.close_observer) |observer| {
            observer.release(observer.ctx);
        } else {
            Internal.retainAndReportUnhandledFailure(self, .fromError(error.ProviderContract));
        }
        wire.close_event_reserved = false;
    }
    switch (wire.link) {
        .stream => |*stream| {
            if (stream.conn.socketHandle()) |fd| Internal.removeReadyFd(self, fd);
            if (!stream.transport_released) stream.conn.deinit();
            self.allocator.free(stream.read_buf);
            self.allocator.free(stream.write_buf);
        },
        .resident => |*rl| {
            std.debug.assert(self.resident_wires.remove(.{ .resident = rl.index, .conn = rl.conn }));
            if (rl.pending) |*pending| pending.frame.deinit();
            rl.parked.deinit(self.allocator);
            for (rl.parked_packets.items) |packet| self.allocator.free(packet);
            rl.parked_packets.deinit(self.allocator);
            self.allocator.free(rl.read_buf);
        },
    }
    self.allocator.destroy(wire);
}

pub fn dropWire(self: *HostRuntime, peer_handle: engine.PeerHandle) void {
    if (self.wires.fetchRemove(peer_handle)) |kv| retireConsumedWire(self, kv.value);
}

fn suppressWireCloseEvent(self: *HostRuntime, wire: *Wire) void {
    if (!wire.close_event_reserved) return;
    if (self.close_observer) |observer|
        observer.release(observer.ctx)
    else
        Internal.retainAndReportUnhandledFailure(self, .fromError(error.ProviderContract));
    wire.close_event_reserved = false;
}

fn retireConsumedWire(self: *HostRuntime, wire: *Wire) void {
    suppressWireCloseEvent(self, wire);
    if (wire.carrierClosed()) {
        freeWire(self, wire);
        return;
    }
    std.debug.assert(!wire.detached);
    wire.detached = true;
    wire.retiring_prev = null;
    wire.retiring_next = self.retiring_wires;
    if (self.retiring_wires) |head| head.retiring_prev = wire;
    self.retiring_wires = wire;
    if (!wire.closed) closeWire(self, wire, null);
}

fn unlinkRetiringWire(self: *HostRuntime, wire: *Wire) void {
    std.debug.assert(wire.detached);
    if (wire.retiring_prev) |previous|
        previous.retiring_next = wire.retiring_next
    else
        self.retiring_wires = wire.retiring_next;
    if (wire.retiring_next) |next| next.retiring_prev = wire.retiring_prev;
    wire.detached = false;
    wire.retiring_prev = null;
    wire.retiring_next = null;
}

/// Final Runtime destruction joins stream close directly. A resident package
/// stays the asynchronous owner and is joined later in the deinit barrier.
pub fn forceWireCarrierClose(self: *HostRuntime, wire: *Wire) void {
    if (!wire.closed) closeWire(self, wire, null);
    if (wire.carrierClosed()) return;
    switch (wire.link) {
        .stream => |*stream| if (!stream.transport_released) {
            if (stream.conn.closeGracefully(transport_close_ms)) |failure|
                noteWireCloseChain(wire, failure);
        },
        .resident => {},
    }
    finishWireCarrierClose(self, wire);
}

/// Mark a wire closed and break its session vows without freeing its shell.
pub fn closeWire(self: *HostRuntime, wire: *Wire, cause: ?anyerror) void {
    if (wire.closed) return;
    const failure = takeWireFailure(self, wire) orelse
        if (cause) |err| OperationFailure.fromError(err) else null;
    closeWireFailure(self, wire, failure);
}

fn takeWireFailure(self: *HostRuntime, wire: *Wire) ?OperationFailure {
    const chain = switch (wire.link) {
        .stream => |*sl| sl.conn.takeFailure(),
        .resident => |rl| self.residents.items[rl.index].resident.takeFailure(rl.conn),
    } orelse return null;
    return OperationFailure.fromChain(chain);
}

fn closeWireFailure(self: *HostRuntime, wire: *Wire, failure: ?OperationFailure) void {
    if (failure) |reported| noteWireCloseFailure(wire, reported);
    if (!wire.closed) {
        wire.closed = true;
        wire.carrier_close_deadline_ms = net.clock.nowMs(self.io) +| transport_close_ms;
        const reason = if (wire.close_failure) |value| value.primaryName() else "connection closed";
        wire.session.host.transportClosed(wire.session, reason) catch |err|
            Internal.noteTerminalFailure(self, err);
    }
    progressWireCarrierClose(self, wire);
}

fn noteWireCloseFailure(wire: *Wire, later: OperationFailure) void {
    if (wire.close_failure) |*primary|
        primary.noteFailure(later)
    else
        wire.close_failure = later;
}

fn noteWireCloseChain(wire: *Wire, later: foundation.FailureChain) void {
    if (wire.close_failure) |*primary|
        primary.noteChain(later)
    else
        wire.close_failure = OperationFailure.fromChain(later);
}

fn setStreamCloseInterest(self: *HostRuntime, wire: *Wire, progress: net.ConnectionCloseProgress) void {
    const stream = switch (wire.link) {
        .stream => |*value| value,
        .resident => unreachable,
    };
    wire.carrier_close = switch (progress) {
        .wait_read => .wait_read,
        .wait_write => .wait_write,
        else => unreachable,
    };
    if (self.ready_set) |*ready_set| if (stream.conn.socketHandle()) |fd| {
        ready_set.setInterest(fd, if (progress == .wait_read) .read else .write) catch |err| {
            noteWireCloseFailure(wire, .fromError(err));
            finishWireCarrierClose(self, wire);
        };
    };
}

pub fn progressWireCarrierClose(self: *HostRuntime, wire: *Wire) void {
    if (!wire.closed or wire.carrierClosed()) return;
    const expired = if (wire.carrier_close_deadline_ms) |deadline|
        net.clock.nowMs(self.io) >= deadline
    else
        false;
    if (expired) {
        noteWireCloseFailure(wire, .fromError(error.CloseTimedOut));
        wire.carrier_close_deadline_ms = null;
        switch (wire.link) {
            .stream => |*stream| {
                stream.conn.deinit();
                stream.transport_released = true;
                finishWireCarrierClose(self, wire);
            },
            // The resident package still owns the operation and will join it
            // at release; timeout cannot fabricate physical completion.
            .resident => {},
        }
        return;
    }
    switch (wire.link) {
        .stream => |*stream| switch (stream.conn.advanceClose()) {
            .complete => finishWireCarrierClose(self, wire),
            .failed => {
                noteWireCloseChain(
                    wire,
                    stream.conn.takeFailure() orelse foundation.FailureChain.init(error.TransportCloseFailed),
                );
                finishWireCarrierClose(self, wire);
            },
            .wait_read, .wait_write => |progress| setStreamCloseInterest(self, wire, progress),
        },
        .resident => |resident| switch (self.residents.items[resident.index].resident.connCloseOutcome(resident.conn)) {
            .complete => finishWireCarrierClose(self, wire),
            .pending => wire.carrier_close = .wait_resident,
            .failed => |reported| {
                noteWireCloseChain(wire, reported);
                finishWireCarrierClose(self, wire);
            },
        },
    }
}

fn finishWireCarrierClose(self: *HostRuntime, wire: *Wire) void {
    if (wire.carrierClosed()) return;
    wire.carrier_close = .complete;
    wire.carrier_close_deadline_ms = null;
    if (self.open_wire_count == 0)
        Internal.retainAndReportUnhandledFailure(self, .fromError(error.ProviderContract))
    else
        self.open_wire_count -= 1;
    switch (wire.link) {
        .stream => |*stream| if (stream.conn.socketHandle()) |fd| Internal.removeReadyFd(self, fd),
        .resident => {},
    }
    if (wire.detached) {
        unlinkRetiringWire(self, wire);
        freeWire(self, wire);
        Internal.nudgeIfWorkRemains(self);
        return;
    }
    // A staged dial reports through its dial path; it was never visible to the
    // close observer.
    if (Internal.pendingOpenFor(self, wire.session)) |row| {
        row.close_cause = wire.close_failure;
        Internal.nudgeIfWorkRemains(self);
        return;
    }
    if (self.close_observer) |obs| {
        std.debug.assert(wire.close_event_reserved);
        wire.close_event_reserved = false;
        self.observer_callback_depth += 1;
        defer self.observer_callback_depth -= 1;
        obs.closed(obs.ctx, wire.session, wire.close_failure);
    }
    Internal.nudgeIfWorkRemains(self);
}
