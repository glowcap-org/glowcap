//! Persisted restart markers for an embedding's live reference lifetime.
//! Store opening fences writers; this row independently fences Host restarts.
const std = @import("std");
const core = @import("loam_core");

const epoch_schema: core.Schema = .{ .id = 0x4c4f414d4c495601, .version = 1, .max_payload = 24, .max_edges = 0 };

/// Descriptive lifetime identity, never authority to restore a capability.
/// The hosting owner must check the current row before admitting a live field.
pub const Epoch = struct {
    object: core.ObjectId,
    generation: u64,
    opening: struct { incarnation: u64, sequence: u64 },
    pub const schema = epoch_schema;

    /// A marker proposed in the existing Store transaction. Activation requires
    /// confirmed installation and a new current lease over this exact row.
    pub const Proposed = struct {
        epoch: Epoch,

        pub fn confirm(self: Proposed, store: *core.Store, lease: core.Lease) !Epoch {
            try self.epoch.check(store, lease);
            return self.epoch;
        }
    };

    pub fn read(store: *core.Store, lease: core.Lease) !Epoch {
        if (store.phase != .idle) return error.EpochUnconfirmed;
        return decode(try store.currentView(lease));
    }

    /// A current checked lease supplies the marker; equal Store incarnations
    /// alone do not establish that a live reference belongs to this lifetime.
    pub fn check(self: Epoch, store: *core.Store, lease: core.Lease) !void {
        const current = try read(store, lease);
        if (!current.object.eql(self.object) or current.generation != self.generation or !std.meta.eql(current.opening, self.opening)) return error.LiveReferenceExpired;
    }
    /// Allocate a new rooted lifetime row in the caller's transaction. The caller
    /// retains its object name as trusted startup metadata, alongside owner names.
    pub fn stageFresh(store: *core.Store) !Proposed {
        if (store.phase != .staging) return error.WrongPhase;
        const object = try store.allocateId();
        return stage(store, object, 1, null);
    }

    /// Advance once before the embedding opens admissions for a restarted Host.
    /// The checked row and expected revision make competing restarts conflict.
    /// No record or grant population is visited. Exhaustion refuses before staging.
    pub fn stageRestart(store: *core.Store, lease: core.Lease) !Proposed {
        if (store.phase != .staging) return error.WrongPhase;
        const view = try store.currentView(lease);
        const prior = try decode(view);
        if (try store.proposed(prior.object) != null) return error.EpochAlreadyStaged;
        const generation = std.math.add(u64, prior.generation, 1) catch return error.EpochExhausted;
        return stage(store, prior.object, generation, view.revision);
    }
};

fn stage(store: *core.Store, object: core.ObjectId, generation: u64, expected: ?u64) !Epoch.Proposed {
    const ticket = store.ticket.?;
    const epoch: Epoch = .{ .object = object, .generation = generation, .opening = .{ .incarnation = ticket.incarnation, .sequence = ticket.sequence } };
    var payload: [24]u8 = undefined;
    std.mem.writeInt(u64, payload[0..8], epoch.generation, .big);
    std.mem.writeInt(u64, payload[8..16], epoch.opening.incarnation, .big);
    std.mem.writeInt(u64, payload[16..24], epoch.opening.sequence, .big);
    // Store.putCopying owns the single encoded proposal and its allocation.
    try store.putCopying(.{ .id = epoch.object, .revision = 0, .schema = epoch_schema.id, .rooted = true, .payload = &payload }, expected);
    return .{ .epoch = epoch };
}

fn decode(view: core.RecordView) !Epoch {
    if (view.schema != epoch_schema.id or view.schema_version != epoch_schema.version or !view.rooted or view.payload.len != 24 or view.edge_count != 0) return error.InvalidLiveEpoch;
    const generation = std.mem.readInt(u64, view.payload[0..8], .big);
    const incarnation = std.mem.readInt(u64, view.payload[8..16], .big);
    const sequence = std.mem.readInt(u64, view.payload[16..24], .big);
    if (generation == 0 or incarnation == 0 or sequence == 0) return error.InvalidLiveEpoch;
    return .{ .object = view.id, .generation = generation, .opening = .{ .incarnation = incarnation, .sequence = sequence } };
}
