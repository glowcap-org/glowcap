//! Transactional admission for application-owned exporter dials.
//!
//! Preparation acquires every Node allocation without publishing a pending
//! row or action. The Host can then acquire its own parking state before the
//! infallible commit makes the dial externally actionable.

const model = @import("model");
const session = @import("session");

const node_mod = @import("../../../node.zig");
const actions = @import("../../actions.zig");
const dials = @import("../dials.zig");
const plan = @import("../plan.zig");
const attempts = @import("attempts.zig");

const Node = node_mod.Node;
const PeerHandle = @import("../../../peer_handle.zig").PeerHandle;
const id_route = session.id_route;

pub const Stage = union(enum) {
    open: PeerHandle,
    pending: dials.PendingId,
};

pub const PreparedStage = union(enum) {
    open: PeerHandle,
    existing: dials.PendingId,
    fresh: struct {
        pending_id: dials.PendingId,
        plan: plan.Owned,
        /// The first wave of routes, sized when the actions were reserved.
        batch: attempts.Batch,
    },
    consumed,

    pub fn view(self: PreparedStage) Stage {
        return switch (self) {
            .open => |peer_handle| .{ .open = peer_handle },
            .existing => |pending_id| .{ .pending = pending_id },
            .fresh => |fresh| .{ .pending = fresh.pending_id },
            .consumed => unreachable,
        };
    }

    pub fn commit(self: *PreparedStage, node: *Node) Stage {
        const staged = self.*;
        self.* = .consumed;
        return switch (staged) {
            .open => |peer_handle| commit_open: {
                node.exporterApplicationOwned(peer_handle);
                break :commit_open .{ .open = peer_handle };
            },
            .existing => |pending_id| commit_existing: {
                node.redeems.dials.pending.getPtr(pending_id).?.dialing.application_owned = true;
                break :commit_existing .{ .pending = pending_id };
            },
            .fresh => |fresh| commit_fresh: {
                dials.publishFresh(node, fresh.pending_id, .{ .plan = fresh.plan, .application_owned = true }, fresh.batch);
                break :commit_fresh .{ .pending = fresh.pending_id };
            },
            .consumed => unreachable,
        };
    }

    pub fn deinit(self: *PreparedStage, node: *Node) void {
        switch (self.*) {
            .fresh => |*fresh| fresh.plan.deinit(node.allocator),
            .open, .existing, .consumed => {},
        }
        self.* = .consumed;
    }
};

fn prepareOwned(self: *Node, owned: plan.Owned) !PreparedStage {
    var staged = owned;
    var staged_owned = true;
    defer if (staged_owned) staged.deinit(self.allocator);
    const state = &self.redeems.dials;
    if (state.exporters.get(staged.identity)) |exporter_peer| {
        return .{ .open = exporter_peer };
    }
    if (state.by_identity.get(staged.identity)) |pending_id| {
        const entry = &state.pending.getPtr(pending_id).?.dialing;
        if (!model.route_bundle.samePaths(entry.plan, staged))
            return error.ConflictingDialPlan;
        return .{ .existing = pending_id };
    }

    try state.pending.ensureUnusedCapacity(self.allocator, 1);
    try state.by_identity.ensureUnusedCapacity(self.allocator, 1);
    const initial = attempts.State.initial(staged);
    try actions.reserve(self, initial.len);
    const pending_id = try actions.claimTicketRange(self, 1);
    staged_owned = false;
    return .{ .fresh = .{ .pending_id = pending_id, .plan = staged, .batch = initial } };
}

fn stageOwned(self: *Node, owned: plan.Owned) !Stage {
    var prepared = try prepareOwned(self, owned);
    defer prepared.deinit(self);
    return prepared.commit(self);
}

pub fn stage(self: *Node, locator: []const u8) !Stage {
    if (locator.len == 0) return error.UnparseableExporterLocator;
    return stageOwned(self, try plan.parse(self.allocator, locator));
}

pub fn prepareDialLocator(self: *Node, locator: model.PeerLocator) !PreparedStage {
    return prepareOwned(self, try plan.fromLocator(self.allocator, locator));
}

/// Validate and prepare an identity-route bundle. Ownership transfers on every
/// outcome, including errors.
pub fn prepareIdRouteBundle(self: *Node, bundle: plan.Owned) !PreparedStage {
    if (bundle.source != .id) {
        var invalid = bundle;
        invalid.deinit(self.allocator);
        return error.UnsupportedId;
    }
    id_route.validateBundle(bundle) catch |err| {
        var invalid = bundle;
        invalid.deinit(self.allocator);
        return err;
    };
    return prepareOwned(self, bundle);
}
