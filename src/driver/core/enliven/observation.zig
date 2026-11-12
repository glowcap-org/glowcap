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

pub const not_capability: engine.Broken = .{ .detail = "NotCapability", .cause = engine.BreakCause.local(.refused) };

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
    release_node: host_mod.Host.DeferredRelease = .{ .run = runRelease },

    comptime {
        // The exact listener fits beneath the existing inline failure arm;
        // cancellation adds neither operation bytes nor allocation.
        const State = @FieldType(Enliven, "state");
        std.debug.assert(@sizeOf(@FieldType(State, "fetching")) <= @sizeOf(@FieldType(State, "failed")));
    }

    pub const Result = union(enum) {
        pending,
        ready: struct { capability: capability.Ref, provenance: host_mod.PeerProvenance },
        failed: struct { kind: action.VowFailure, message: []const u8, cause: engine.BreakCause },
    };

    /// The result capability and failure text borrow this operation. The
    /// capability keeps its original Host identity and current session lifetime.
    pub fn result(self: *const Enliven) Result {
        return switch (self.state) {
            .dialing, .fetching, .lookup => .pending,
            .ready => |ready| .{ .ready = .{ .capability = ready.capability, .provenance = ready.provenance } },
            .failed => |*failed| .{ .failed = .{ .kind = failed.kind, .message = failed.text.message(), .cause = failed.text.cause } },
            .starting, .taken => unreachable,
        };
    }

    /// Transfer the completed capability retain. Destroy the operation after
    /// taking. Pending and failed operations leave their state unchanged.
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

    /// Detach pending observation or release its result. A shared dial stays
    /// owned by Host until its executor reports a terminal outcome. At the top
    /// level this runs before returning. Inside a Host callback it runs when
    /// the callback's verb tail does. Either way the operation is the Host's
    /// from this call on. Call on the owner thread, before destroying Host.
    pub fn deinit(self: *Enliven) void {
        self.host.releaseAtTopLevel(&self.release_node);
    }

    fn runRelease(node: *host_mod.Host.DeferredRelease) void {
        const self: *Enliven = @alignCast(@fieldParentPtr("release_node", node));
        switch (self.state) {
            .lookup => |id| {
                const lookup = self.host.publication_lookup orelse unreachable;
                lookup.cancel(lookup.context, .{ .origin = .{ .local = id } });
            },
            .dialing => |dialing| @import("../enliven.zig").cancelParkedObservation(self.host, self, dialing.id, dialing.ticket),
            .fetching => |fetching| release.cancelObserved(self.host, fetching.id, fetching.observer),
            .ready => |ready| self.host.releaseCapabilityTerminal(ready.capability, null),
            .failed, .taken => {},
            .starting => unreachable,
        }
        self.allocator.destroy(self);
    }

    pub fn fail(self: *Enliven, kind: action.VowFailure, reason: engine.Broken) void {
        self.state = .{ .failed = .{ .kind = kind, .text = FailureText.init(.{ .detail = reason.detail, .cause = reason.cause.withFetch() }) } };
    }

    fn receive(self: *Enliven, session: *HostSession, reference: model.Reference, provenance: host_mod.PeerProvenance, occurrence: enum { wire, cached }) void {
        const ref = self.host.liftCapability(session, reference) catch |err| {
            // A cache hit contributes no wire occurrence. Another unprojected
            // completion may still own the import that cache entry names.
            if (occurrence == .wire) self.host.discardCapabilityObservation(session, .fromOwned(&reference));
            self.fail(.broken, engine.Broken.unnamed(@errorName(err)));
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
                const session = self.host.sessions.get(fetching.peer) orelse return self.fail(.closed, engine.Broken.unnamed("session closed"));
                if (value != .reference) {
                    self.host.discardValueObservation(session, value);
                    return self.fail(.broken, not_capability);
                }
                self.receive(session, value.reference, fetching.provenance, .wire);
            },
            .broken => |reason| self.fail(@import("../vows/completion.zig").classifyFailure(self.host, fetching.peer), reason),
            .give => self.fail(.broken, not_capability),
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

    pub fn failedLocal(self: Recipient, host: *Host, id: u64, kind: action.VowFailure, reason: engine.Broken) void {
        switch (self) {
            .action => host.actions.pushReserved(.{ .failed = .{ .peer_handle = null, .vow_id = id, .failure = kind, .message = action.retainFailureMessage(host.allocator, reason.detail), .cause = reason.cause } }),
            .observed => |owned| owned.fail(kind, reason),
        }
    }

    pub fn park(self: Recipient, id: u64, ticket: engine.Node.PendingId) void {
        if (self == .observed) self.observed.state = .{ .dialing = .{ .id = id, .ticket = ticket } };
    }

    pub fn observe(self: Recipient, host: *Host, session: *HostSession, row: *settlement.VowRow, provenance: host_mod.PeerProvenance) !void {
        if (self == .action) return;
        if (row.answer_release == .owned)
            row.observer_release = try session.served.port.peer.reserveAnswerRelease();
        // A pending dial can resume in another Zig archive's code image.
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
