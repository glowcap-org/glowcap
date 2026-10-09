//! Owned enliven outcomes and exact observation cancellation. Network dialing
//! remains Host work even when an individual observer no longer needs it.
const std = @import("std");
const model = @import("model");
const engine = @import("engine");
const actors = @import("actors");
const host_mod = @import("../host.zig");
const capability = @import("../capability.zig");
const action = @import("../host/action.zig");
const settlement = @import("../vows/settlement.zig");
const release = @import("../vows/release.zig");
const FailureText = @import("../host/failure_text.zig");
const Host = host_mod.Host;
const HostSession = host_mod.HostSession;

pub const Enliven = struct {
    host: *Host,
    allocator: std.mem.Allocator,
    state: union(enum) {
        starting,
        dialing: struct { id: u64, ticket: engine.Node.PendingId },
        lookup: u64,
        fetching: struct { id: u64, peer: engine.PeerHandle, provenance: host_mod.PeerProvenance, observer: actors.Listener },
        ready: struct { capability: capability.Ref, provenance: host_mod.PeerProvenance },
        failed: struct { kind: action.VowFailure, text: FailureText },
        taken,
    } = .starting,

    comptime {
        // The exact listener fits beneath the existing inline failure arm;
        // cancellation adds neither operation bytes nor allocation.
        const State = @FieldType(Enliven, "state");
        std.debug.assert(@sizeOf(@FieldType(State, "fetching")) <= @sizeOf(@FieldType(State, "failed")));
    }

    pub const Result = union(enum) {
        pending,
        ready: struct { capability: capability.Ref, provenance: host_mod.PeerProvenance },
        failed: struct { kind: action.VowFailure, message: []const u8 },
    };

    /// The result capability and failure text borrow this operation. The
    /// capability keeps its original Host identity and current session lifetime.
    pub fn result(self: *const Enliven) Result {
        return switch (self.state) {
            .dialing, .fetching, .lookup => .pending,
            .ready => |ready| .{ .ready = .{ .capability = ready.capability, .provenance = ready.provenance } },
            .failed => |*failed| .{ .failed = .{ .kind = failed.kind, .message = failed.text.message() } },
            .starting, .taken => unreachable,
        };
    }

    /// Transfer the completed capability retain. Destroy the operation after
    /// taking; pending and failed operations leave their state unchanged.
    pub fn take(self: *Enliven) !capability.Ref {
        const ready = switch (self.state) {
            .ready => |ready| ready,
            .dialing, .fetching, .lookup => return error.EnlivenPending,
            .failed => return error.EnlivenFailed,
            .starting, .taken => return error.AlreadyConsumed,
        };
        self.state = .taken;
        return ready.capability;
    }

    /// Synchronously detach pending observation or release its result. A shared
    /// dial stays owned by Host until its executor reports a terminal outcome.
    /// Call only at the top-level Host boundary, before destroying Host.
    pub fn deinit(self: *Enliven) void {
        self.host.refuseReentry() catch unreachable;
        switch (self.state) {
            .lookup => |id| {
                const lookup = self.host.publication_lookup orelse unreachable;
                lookup.cancel(lookup.context, .{ .origin = .{ .local = id } });
            },
            .dialing => |dialing| self.cancelDialing(dialing.id, dialing.ticket),
            .fetching => |fetching| release.cancelObserved(self.host, fetching.id, fetching.observer),
            .ready => |ready| self.host.releaseCapabilityTerminal(ready.capability, null),
            .failed, .taken => {},
            .starting => unreachable,
        }
        self.allocator.destroy(self);
    }

    fn cancelDialing(self: *Enliven, id: u64, ticket: engine.Node.PendingId) void {
        const host = self.host;
        const group = host.pending_enlivens.getPtr(ticket) orelse unreachable;
        const parked = if (group.first.vow_id == id) blk: {
            const found = group.first;
            if (group.rest.pop()) |next| {
                group.first = next;
            } else {
                group.rest.deinit(host.allocator);
                std.debug.assert(host.pending_enlivens.remove(ticket));
            }
            break :blk found;
        } else blk: {
            for (group.rest.items, 0..) |item, index| if (item.vow_id == id)
                break :blk group.rest.orderedRemove(index);
            unreachable;
        };
        std.debug.assert(parked.recipient == .observed and parked.recipient.observed == self);
        host.pending_enliven_count -= 1;
        model.uri.freeSturdyref(host.allocator, parked.sturdyref);
    }

    pub fn fail(self: *Enliven, kind: action.VowFailure, reason: []const u8) void {
        self.state = .{ .failed = .{ .kind = kind, .text = FailureText.init(reason) } };
    }

    fn receive(self: *Enliven, session: *HostSession, reference: model.Reference, provenance: host_mod.PeerProvenance, occurrence: enum { wire, cached }) void {
        const ref = self.host.liftCapability(session, reference) catch |err| {
            // A cache hit contributes no wire occurrence. Another unprojected
            // completion may still own the import that cache entry names.
            if (occurrence == .wire) self.host.discardCapabilityObservation(session, reference);
            self.fail(.broken, @errorName(err));
            return;
        };
        self.state = .{ .ready = .{ .capability = ref, .provenance = provenance } };
    }

    fn listener(self: *Enliven) actors.Listener {
        return .{ .ctx = self, .func = complete };
    }

    fn complete(context: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *Enliven = @ptrCast(@alignCast(context.?));
        const fetching = self.state.fetching;
        switch (resolution) {
            .fulfilled => |value| {
                const session = self.host.sessions.get(fetching.peer) orelse return self.fail(.closed, "session closed");
                if (value != .reference) {
                    self.host.discardValueObservation(session, value);
                    return self.fail(.broken, "NotCapability");
                }
                self.receive(session, value.reference, fetching.provenance, .wire);
            },
            .broken => |reason| self.fail(@import("../vows/completion.zig").classifyFailure(self.host, fetching.peer), reason),
            .give => self.fail(.broken, "NotCapability"),
        }
    }
};

/// A producer selects its completion destination before it can finish. All
/// existing action-based APIs and owned observations share the same producer.
pub const Recipient = union(enum) {
    action,
    observed: *Enliven,

    pub fn pendingLocal(self: Recipient, id: u64) void {
        if (self == .observed) self.observed.state = .{ .lookup = id };
    }

    /// Transfer one actual local capability retain, without a wire projection.
    pub fn foundLocal(self: Recipient, host: *Host, id: u64, reference: capability.Ref) void {
        switch (self) {
            .action => host.actions.pushReserved(.{ .settled = .{ .peer_handle = null, .vow_id = id, .value = .{ .capability = reference } } }),
            .observed => |owned| owned.state = .{ .ready = .{ .capability = reference, .provenance = .verified } },
        }
    }

    pub fn failedLocal(self: Recipient, host: *Host, id: u64, kind: action.VowFailure, reason: []const u8) void {
        switch (self) {
            .action => host.actions.pushReserved(.{ .failed = .{ .peer_handle = null, .vow_id = id, .failure = kind, .message = action.retainFailureMessage(host.allocator, reason) } }),
            .observed => |owned| owned.fail(kind, reason),
        }
    }

    pub fn park(self: Recipient, id: u64, ticket: engine.Node.PendingId) void {
        if (self == .observed) self.observed.state = .{ .dialing = .{ .id = id, .ticket = ticket } };
    }

    pub fn observe(self: Recipient, host: *Host, session: *HostSession, row: *settlement.VowRow, provenance: host_mod.PeerProvenance) !void {
        if (self == .action) return;
        if (row.answer_release == .peer_visible)
            row.observer_release = try session.served.port.peer.reserveAnswerRelease();
        // A pending dial can resume in another native archive's code image.
        // Retain the installed listener rather than reconstructing its address
        // in the archive that later destroys this operation.
        const observer = self.observed.listener();
        row.inner = observer;
        self.observed.state = .{ .fetching = .{ .id = row.id, .peer = session.peer_handle, .provenance = provenance, .observer = observer } };
        std.debug.assert(self.observed.host == host);
    }

    pub fn cached(self: Recipient, host: *Host, session: *HostSession, id: u64, reference: model.Reference, provenance: host_mod.PeerProvenance) void {
        switch (self) {
            .action => @import("../vows/completion.zig").queueCachedCompletion(host, session, id, reference),
            .observed => |owned| owned.receive(session, reference, provenance, .cached),
        }
    }
};
