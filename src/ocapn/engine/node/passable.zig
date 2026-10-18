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
    outbound_answer: session.OutboundAnswerTarget,
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

    /// The answer a failed publication must break, by identity. A send whose
    /// answer position was never reserved has no observer to break, because
    /// a listener installs only on a reserved or live question.
    pub fn failureTarget(self: Outbound, state: *const session.Session) ?FailureTarget {
        return switch (self) {
            .answer_settlement => |settlement| .{ .inbound_answer = settlement.target },
            .message => if (self.answerProduced()) |answer|
                if (state.outbound_answers.targetOf(answer)) |target| .{ .outbound_answer = target } else null
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

    /// The by-value root an inventory's `root` slot names: a settlement's
    /// fulfillment. A deliver's roots are heap slots, so it has none.
    pub fn resolutionRoot(self: *Outbound) ?*model.Argument {
        const resolution: *model.Resolution = switch (self.*) {
            .message => return null,
            .answer_settlement => |*settlement| &settlement.resolution,
        };
        return if (resolution.* == .fulfill) &resolution.fulfill else null;
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

pub const Gift = struct {
    route_id: model.CapabilityRouteId,
    home: PeerHandle,
    /// The exact tree slot this projection rewrites at commit preparation and
    /// restores on rollback. Slot identity, rather than reference equality,
    /// keeps rollback immune to another argument legitimately carrying the
    /// same numeric position.
    slot: session.inventory.Slot,
    original: model.Reference,
    gifted: model.FarRef,
    capability_lease: ?u64 = null,
    gift_id: [model.handoff_gift_id_bytes]u8 = undefined,
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
