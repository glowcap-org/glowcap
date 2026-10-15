//! Owned semantic payloads crossing Node's recursive Passable projection seam.
//!
//! An answer settlement is not a wire `op:resolve`: its `AnswerName` may be a
//! session-local virtual name. Keeping that distinction in the carrier lets
//! the Node project nested foreign references without inventing a wire
//! position or adding a second tree walker.

const std = @import("std");
const model = @import("model");
const session = @import("session");
const PeerHandle = @import("../peer_handle.zig").PeerHandle;

pub const AnswerSettlement = struct {
    target: session.AnswerTarget,
    payload: *session.AnswerPayload,
    resolution: model.Resolution,
};

/// The one operation a delayed outbound projection must fail if it cannot be
/// published. An outbound answer is a question this peer asked. An inbound
/// answer is a question it owes the partner. Tells carry no target and retire
/// without turning one unreachable argument into a session failure.
pub const FailureTarget = union(enum) {
    outbound_answer: model.AnswerPosition,
    inbound_answer: session.AnswerTarget,
};

pub const Outbound = union(enum) {
    message: model.Message,
    answer_settlement: AnswerSettlement,

    pub fn answerProduced(self: Outbound) ?model.AnswerPosition {
        return switch (self) {
            .message => |message| answerProducedBy(message),
            .answer_settlement => null,
        };
    }

    pub fn failureTarget(self: Outbound) ?FailureTarget {
        return switch (self) {
            .answer_settlement => |settlement| .{ .inbound_answer = settlement.target },
            .message => if (self.answerProduced()) |answer|
                .{ .outbound_answer = answer }
            else
                null,
        };
    }

    pub fn deinit(self: Outbound, owner: *session.Session) void {
        switch (self) {
            .message => |message| model.freeMessage(owner.allocator, message),
            .answer_settlement => |settlement| {
                model.freeResolution(owner.allocator, settlement.resolution);
                owner.releaseAnswerPayload(settlement.payload);
            },
        }
    }

    /// The carrier's retained bytes, with the tree's share read from the
    /// inventory its owner took.
    pub fn retainedBytes(self: Outbound, inventory: session.Inventory) model.view.ProjectError!usize {
        const envelope: usize = switch (self) {
            .message => |message| try model.measureMessageEnvelopeBytes(message),
            .answer_settlement => @sizeOf(AnswerSettlement),
        };
        return std.math.add(usize, envelope, inventory.owned_bytes) catch error.MalformedView;
    }
};

pub fn answerProducedBy(message: model.Message) ?model.AnswerPosition {
    return switch (message) {
        .deliver => |deliver| deliver.answer,
        .get => |get| get.answer,
        .index => |index| index.answer,
        .untag => |untag| untag.answer,
        else => null,
    };
}

pub const BatchId = enum(u64) { _ };

pub const Payload = union(enum) {
    outbound: Outbound,
    relayed_resolution: model.Resolution,

    pub fn deinit(self: Payload, allocator: std.mem.Allocator, owner: *session.Session) void {
        switch (self) {
            .outbound => |value| value.deinit(owner),
            .relayed_resolution => |resolution| model.freeResolution(allocator, resolution),
        }
    }

    pub fn retainedBytes(self: Payload, inventory: session.Inventory) model.view.ProjectError!usize {
        return switch (self) {
            .outbound => |value| value.retainedBytes(inventory),
            .relayed_resolution => inventory.owned_bytes,
        };
    }

    /// The by-value root an inventory's `root` slot names: a settlement's
    /// fulfillment. A deliver's roots are heap slots, so it has none.
    pub fn resolutionRoot(self: *Payload) ?*model.Argument {
        const resolution: *model.Resolution = switch (self.*) {
            .outbound => |*value| switch (value.*) {
                .message => return null,
                .answer_settlement => |*settlement| &settlement.resolution,
            },
            .relayed_resolution => |*resolution| resolution,
        };
        return if (resolution.* == .fulfill) &resolution.fulfill else null;
    }
};

pub const Gift = struct {
    route_id: model.CapabilityRouteId,
    home: PeerHandle,
    /// The exact tree slot this projection rewrites at commit preparation and
    /// restores on rollback. Slot identity, rather than reference equality,
    /// keeps rollback immune to another argument legitimately carrying the
    /// same numeric position.
    slot: session.inventory.Slot,
    original: model.Reference,
    gifted: model.Reference,
    capability_lease: ?u64 = null,
    gift_id: [model.HANDOFF_GIFT_ID_BYTES]u8 = undefined,
    handoff: ?*model.Handoff = null,
    inserted_handoff: ?*model.Handoff = null,
};

pub const PromiseProjection = struct {
    route_id: model.CapabilityRouteId,
    home: PeerHandle,
    /// See `Gift.slot`.
    slot: session.inventory.Slot,
    original: model.Reference,
    source: model.FarRef,
    capability_lease: ?u64 = null,
    projected: ?model.Reference = null,
    inserted: bool = false,
};
