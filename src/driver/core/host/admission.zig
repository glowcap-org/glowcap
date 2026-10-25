//! Host thread ownership, reentrancy, and operation admission.
//!
//! This internal owner is the one gate for configuration, application, and
//! session work. The Host keeps the counters and lifecycle state. Supported
//! queries and admissions remain direct aliases on `Host`.

const std = @import("std");
const builtin = @import("builtin");

const engine = @import("engine");
const foundation = @import("foundation");

const host_mod = @import("../host.zig");
const session_wire = @import("session.zig");
const host_pump = @import("pump.zig");

const Host = host_mod.Host;
const HostError = host_mod.HostError;
const HostSession = session_wire.HostSession;

pub const tracks_thread_affinity = builtin.os.tag != .freestanding;
const OwnerThread = foundation.thread_affinity.OwnerThread(tracks_thread_affinity);
const unclaimed_owner_thread_id = OwnerThread.unclaimed;
pub const OwnerThreadId = OwnerThread.Id;
pub const initial_owner_thread_id = OwnerThread.initial;

/// The Host's reentrancy latch. While it is held, the Host-driving verbs
/// refuse `ReenteredHost` and a nested verb tail leaves its pump to the
/// outermost one, so a callback cannot free a row its caller still borrows.
/// A hold restores the state it found, so releasing a nested hold never
/// unlatches the holder outside it. `held` is read and written only here.
pub const CallbackLatch = struct {
    held: bool = false,

    pub const Hold = struct {
        latch: *CallbackLatch,
        prior: bool,

        pub fn release(self: Hold) void {
            std.debug.assert(self.latch.held);
            self.latch.held = self.prior;
        }
    };

    pub fn hold(self: *CallbackLatch) Hold {
        const prior = self.held;
        self.held = true;
        return .{ .latch = self, .prior = prior };
    }

    pub fn isHeld(self: CallbackLatch) bool {
        return self.held;
    }
};

fn currentOwnerThreadId() OwnerThreadId {
    if (comptime !tracks_thread_affinity) return {};
    return OwnerThread.token(@intCast(std.Thread.getCurrentId()));
}

/// A committed owner-level operation whose terminal outcome still has to cross
/// an adapter boundary. The Host owns close accounting. The adapter owns only
/// this linear completion authority while its effect is live.
pub const PendingWorkLease = struct {
    host: ?*Host,

    /// A borrowed work proof is meaningful only at its actual owning Host.
    /// Validate before another boundary allocates or publishes child effects.
    pub fn checkHost(self: *const PendingWorkLease, expected: *Host) !void {
        try claimOwner(expected);
        const owner = self.host orelse return error.NoPendingWork;
        if (owner != expected) return error.ForeignWork;
        if (!expected.lifecyclePhase().serving()) return error.HostClosing;
    }

    /// Derive child custody from an actual live operation. Finish preserves
    /// this authority. Cancellation and completed leases cannot mint work.
    pub fn fork(self: *const PendingWorkLease) !PendingWorkLease {
        const host = self.host orelse return error.NoPendingWork;
        try (WorkAdmission{ .retained = self }).check(host);
        beginOperation(host);
        return .{ .host = host };
    }

    /// Bounded child delivery uses the same producers and reply owners as a
    /// top-level call. The actual capability determines its local/wire home.
    pub fn call(self: *const PendingWorkLease, allocator: std.mem.Allocator, target: @import("../capability.zig").Ref, verb: []const u8, args: []const @import("../value.zig").Value, reply_bytes: usize) !*@import("owned_call.zig").Call {
        const host = self.host orelse return error.NoPendingWork;
        const admission: WorkAdmission = .{ .retained = self };
        try admission.check(host);
        if (host.localActorFor(target) != null)
            return @import("local_delivery.zig").callAdmitted(host, allocator, target, verb, args, reply_bytes, admission);
        const session = (try host.capabilitySession(target)) orelse return error.UnknownCapability;
        return @import("owned_call.zig").callAdmitted(host, allocator, session, target, verb, args, reply_bytes, admission);
    }

    /// Cold reference preparation remains a child of the admitted operation.
    /// Existing Enliven rows and dial tickets own all asynchronous completion.
    pub fn enliven(self: *const PendingWorkLease, host: *Host, allocator: std.mem.Allocator, sturdyref: @import("model").SturdyRef) !*@import("../enliven.zig").Enliven {
        return @import("../enliven.zig").enlivenAdmitted(host, allocator, sturdyref, .{ .retained = self });
    }

    pub fn complete(self: *PendingWorkLease) void {
        const host = self.host orelse return;
        finishOperation(host);
        self.host = null;
    }
};

/// Synchronous admission proof borrowed through an existing owner's prepare /
/// commit boundary. It adds no state to queued work or completion owners.
pub const WorkAdmission = union(enum) {
    application,
    retained: *const PendingWorkLease,

    pub fn check(self: WorkAdmission, host: *Host) !void {
        switch (self) {
            .application => {
                try claimOwner(host);
                try admitApplicationOperation(host);
            },
            .retained => |lease| try lease.checkHost(host),
        }
    }
};

pub fn assertOwner(self: *Host) void {
    if (comptime !tracks_thread_affinity) return;
    const tid = currentOwnerThreadId();
    if (self.owner_tid != unclaimed_owner_thread_id) {
        std.debug.assert(self.owner_tid == tid);
    } else {
        self.owner_tid = tid;
    }
}

/// Relinquish the single-thread driver claim at a quiescent adapter boundary.
/// The current owner calls this only after it has stopped dispatching Host
/// work. A later public verb may then claim the Host from another thread. This
/// is a sequential ownership transfer, not permission for concurrent access.
pub fn releaseDriverOwnership(self: *Host) void {
    if (comptime !tracks_thread_affinity) return;
    std.debug.assert(!self.callback_latch.isHeld());
    if (self.owner_tid != unclaimed_owner_thread_id) {
        std.debug.assert(self.owner_tid == currentOwnerThreadId());
        self.owner_tid = unclaimed_owner_thread_id;
    }
}

/// Setup may publish reachability before the runtime thread starts. Once
/// a runtime operation claims the Host, locator updates must stay on that
/// same thread like every other Host mutation.
pub fn claimOwner(self: *Host) error{WrongThread}!void {
    if (comptime !tracks_thread_affinity) return;
    const tid = currentOwnerThreadId();
    if (self.owner_tid != unclaimed_owner_thread_id) {
        if (self.owner_tid != tid) return error.WrongThread;
    } else {
        self.owner_tid = tid;
    }
}

pub fn checkOwnerIfClaimed(self: *const Host) error{WrongThread}!void {
    if (comptime !tracks_thread_affinity) return;
    if (self.owner_tid != unclaimed_owner_thread_id and self.owner_tid != currentOwnerThreadId())
        return error.WrongThread;
}

/// Admit setup/configuration mutation without claiming an unowned Host.
/// Construction may configure a Host before handing it to its driver thread.
/// Once claimed, the same mutation obeys ordinary affinity.
pub fn admitConfigurationMutation(self: *Host) error{ ReenteredHost, WrongThread, HostClosing }!void {
    try checkOwnerIfClaimed(self);
    try admitApplicationOperation(self);
    if (withinCallback(self)) return error.ReenteredHost;
}

/// Refuse independent driving during a Host callback or Vat execution
/// and pin the owning thread under runtime safety.
pub fn refuseReentry(self: *Host) error{ ReenteredHost, WrongThread }!void {
    try claimOwner(self);
    if (withinCallback(self)) return error.ReenteredHost;
}

/// Whether a Host callback or Vat execution owns the current boundary. This
/// lifetime query keeps borrowed callback storage alive. Top-level admission
/// uses refuseReentry instead.
pub fn withinCallback(self: *const Host) bool {
    return self.callback_latch.isHeld() or self.vat.isExecuting();
}

pub fn checkLive(session: *const HostSession) HostError!void {
    if (session.lifecyclePhase().condemned()) return error.SessionCondemned;
}

/// Prove both halves of the application boundary: the session belongs to this
/// Host, then it is still usable. A peer handle alone is insufficient. Every
/// Host starts its own handle space at the same value.
pub fn checkSession(self: *const Host, session: *const HostSession) HostError!void {
    try checkOwnedSession(self, session);
    return checkLive(session);
}

/// Core-internal preflight shared with the sibling application-verb modules. It
/// must run before any retry-visible state moves. Cleanup and terminal traffic
/// bypass it so a full queue cannot pin authority or prevent closure.
pub fn checkOutboundAdmission(self: *Host, session: *HostSession) HostError!void {
    try checkOwnedSession(self, session);
    if (!session.sessionOpen()) return;
    if (session.served.queuedOutboundBytes() >= session.outbound_high_water_bytes)
        return error.OutboundBackpressure;
}

/// Admit application work on one session. Protocol ingress and teardown
/// bypass this gate so finish can continue driving already-admitted work.
pub fn admitSessionOperation(self: *const Host, session: *const HostSession) HostError!void {
    try checkOwnedSession(self, session);
    try switch (session.lifecyclePhase()) {
        .active => {},
        .finishing => error.SessionClosing,
        .cancel_pending, .terminating => error.SessionCondemned,
    };
    if (session.pendingOperations() == std.math.maxInt(u24))
        return error.SessionOperationLimitReached;
}

/// Account one committed session operation at the row authority that owns its
/// terminal settlement. Core-internal. Sibling implementation files share the
/// Host type through public aliases.
pub fn beginSessionOperation(self: *Host, session: *HostSession) void {
    assertOwner(self);
    std.debug.assert(session.lifecyclePhase() == .active);
    // Every path reserves this representable slot through
    // `admitSessionOperation` before its effect commits. Enrollment is the
    // sole exception and starts from a freshly zeroed shell.
    std.debug.assert(session.control.pending_operations != std.math.maxInt(u24));
    session.control.pending_operations += 1;
    beginOperation(self);
}

/// Retire one committed session operation. A finishing session reuses the
/// dirty-work queue as its O(1) close-ready notification.
pub fn finishSessionOperation(self: *Host, session: *HostSession) void {
    assertOwner(self);
    std.debug.assert(session.pendingOperations() != 0);
    session.control.pending_operations -= 1;
    finishOperation(self);
    if (session.pendingOperations() == 0 and session.lifecyclePhase() == .finishing)
        host_pump.markDirty(self, session.peer_handle);
}

/// Admit one owner-level effect whose completion lives outside the sans-I/O
/// Host, such as publication of a transport-open outcome. The returned
/// lease keeps Host finish pending without moving policy into the adapter.
pub fn admitPendingWork(self: *Host) error{HostClosing}!PendingWorkLease {
    assertOwner(self);
    try admitApplicationOperation(self);
    beginOperation(self);
    return .{ .host = self };
}

pub fn beginOperation(self: *Host) void {
    // Every count has a distinct allocated operation/session row. One
    // byte per row would exhaust the address space before usize could
    // overflow, so this is an internal ownership invariant rather than a
    // runtime failure mode.
    std.debug.assert(self.pending_operations != std.math.maxInt(usize));
    self.pending_operations += 1;
}

pub fn finishOperation(self: *Host) void {
    assertOwner(self);
    std.debug.assert(self.pending_operations != 0);
    self.pending_operations -= 1;
}

/// Refuse new application work after the close barrier while leaving
/// settlement, feed, release, and action-drain verbs available.
pub fn admitApplicationOperation(self: *const Host) error{HostClosing}!void {
    if (self.lifecyclePhase() != .active) return error.HostClosing;
}

/// Ownership-only half for teardown and condemned-session no-op paths,
/// which must remain legal after ordinary verbs start refusing the session.
pub fn checkOwnedSession(self: *const Host, session: *const HostSession) HostError!void {
    if (session.host != self) return error.ForeignSession;
}

/// Resolve an action's stable peer handle to its still-retained shell. Adapter
/// projections use this instead of reading the Host session index.
pub fn sessionForPeer(self: *const Host, peer_handle: engine.PeerHandle) ?*HostSession {
    return self.sessions.get(peer_handle);
}
