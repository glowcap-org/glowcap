//! The passes of one inline-Passable transaction over its tree's inventory.
//!
//! The recipient session inventoried the tree once (`session/inventory.zig`),
//! so every pass here is a loop over the slots that hold references: count the
//! projections, collect them, rewrite each slot at commit preparation, and
//! restore it on rollback. A settlement's root is held by value in the batch's
//! payload, and `Outbound.resolutionRoot` resolves that slot.

const std = @import("std");
const model = @import("model");
const session = @import("session");
const Error = @import("../../node_services.zig").OutboundStagingError;
const Node = @import("../../node.zig").Node;
const PeerHandle = @import("../../peer_handle.zig").PeerHandle;
const passable = @import("../passable.zig");
const Batch = @import("batches.zig").Batch;
const ProjectionRoute = @import("leases.zig").ProjectionRoute;

pub const Counts = struct {
    objects: usize = 0,
    promises: usize = 0,

    pub fn add(self: Counts, other: Counts) Counts {
        return .{ .objects = self.objects + other.objects, .promises = self.promises + other.promises };
    }

    pub fn total(self: Counts) usize {
        return self.objects + self.promises;
    }
};

pub fn count(node: *Node, recipient_peer: PeerHandle, payload: *passable.Outbound, inventory: session.Inventory) Error!Counts {
    const root = payload.resolutionRoot();
    var counts: Counts = .{};
    for (inventory.slots) |slot| {
        const reference = switch (slot.read(root).*) {
            .reference => |reference| reference,
            else => continue,
        };
        const projection = (try node.inlineProjectionRoute(recipient_peer, reference)) orelse continue;
        counts = counts.add(switch (projection.kind) {
            .object => .{ .objects = 1 },
            .promise => .{ .promises = 1 },
        });
    }
    return counts;
}

pub fn collect(
    node: *Node,
    recipient_peer: PeerHandle,
    payload: *passable.Outbound,
    inventory: session.Inventory,
    gifts: []passable.Gift,
    promises: []passable.PromiseProjection,
) Error!void {
    const root = payload.resolutionRoot();
    var gift_index: usize = 0;
    var promise_index: usize = 0;
    for (inventory.slots) |slot| {
        const reference = switch (slot.read(root).*) {
            .reference => |reference| reference,
            else => continue,
        };
        const projection = (try node.inlineProjectionRoute(recipient_peer, reference)) orelse continue;
        switch (projection.kind) {
            .object => {
                gifts[gift_index] = .{
                    .route_id = projection.route_id,
                    .home = projection.home,
                    .slot = slot,
                    .original = reference,
                    .gifted = projection.source,
                };
                gift_index += 1;
            },
            .promise => {
                promises[promise_index] = .{
                    .route_id = projection.route_id,
                    .home = projection.home,
                    .slot = slot,
                    .original = reference,
                    .source = projection.source,
                };
                promise_index += 1;
            },
        }
    }
    std.debug.assert(gift_index == gifts.len);
    std.debug.assert(promise_index == promises.len);
}

/// Rewrite every collected slot to its projection. Each slot is re-derived
/// against the Node's current routes, so a route that moved since collection
/// refuses the batch instead of publishing a stale projection. A reference
/// that came to need projection only after collection stays as it is and
/// fails closed at lowering, which refuses a foreign route it cannot lower.
pub fn replace(node: *Node, batch: *Batch) Error!void {
    const root = batch.payload.resolutionRoot();
    for (batch.gifts) |*gift| {
        const argument = gift.slot.at(root);
        const projection = try projectionAt(node, batch.recipient_peer, argument, gift.route_id, gift.home, gift.original);
        if (projection.kind != .object) return error.RouteNotLowerable;
        const handoff = gift.handoff orelse return error.RouteNotLowerable;
        argument.* = .{ .handoff = handoff };
        gift.handoff = null;
        gift.inserted_handoff = handoff;
    }
    for (batch.promises) |*promise| {
        const argument = promise.slot.at(root);
        const projection = try projectionAt(node, batch.recipient_peer, argument, promise.route_id, promise.home, promise.original);
        if (projection.kind != .promise) return error.RouteNotLowerable;
        argument.* = .{ .reference = promise.projected orelse return error.RouteNotLowerable };
        promise.inserted = true;
    }
}

fn projectionAt(
    node: *Node,
    recipient_peer: PeerHandle,
    argument: *const model.Argument,
    route_id: model.CapabilityRouteId,
    home: PeerHandle,
    original: model.Reference,
) Error!ProjectionRoute {
    const reference = switch (argument.*) {
        .reference => |reference| reference,
        else => return error.RouteNotLowerable,
    };
    const projection = (try node.inlineProjectionRoute(recipient_peer, reference)) orelse
        return error.RouteNotLowerable;
    if (projection.route_id != route_id or projection.home != home or !std.meta.eql(original, reference))
        return error.RouteNotLowerable;
    return projection;
}

/// Put every rewritten slot back to the reference the caller handed over.
pub fn restore(batch: *Batch) void {
    const root = batch.payload.resolutionRoot();
    for (batch.gifts) |*gift| {
        const handoff = gift.inserted_handoff orelse continue;
        gift.handoff = handoff;
        gift.inserted_handoff = null;
        gift.slot.at(root).* = .{ .reference = gift.original };
    }
    for (batch.promises) |*promise| {
        if (!promise.inserted) continue;
        promise.slot.at(root).* = .{ .reference = promise.original };
        promise.inserted = false;
    }
}
