//! Resource names include an owner namespace and slot incarnation.
//! They support comparison and lookup only. None carries invocation authority.
const std = @import("std");

/// Stable authority-store identity. A fresh store requires a fresh identity.
/// Recreating an empty store with an old identity is not restoration.
pub const OwnerId = enum(u128) { _ };
/// The generation a slot's first occupant carries. A reused slot counts up.
pub const first_generation: u64 = 1;
pub const KindId = enum(u64) { _ };
pub const Revision = enum(u64) {
    _,

    /// The revision after this one, or null at the end of the sequence.
    pub fn next(self: Revision) ?Revision {
        return @fromBackingInt(std.math.add(u64, @backingInt(self), 1) catch return null);
    }
};

/// Whether `parent` can hold `id`: the same owner, a live generation, and
/// not `id` itself.
pub fn validParent(id: anytype, parent: @TypeOf(id)) bool {
    return parent.owner == id.owner and parent.generation != 0 and !parent.eql(id);
}

/// A managed access record name. Passing this data confers no use or control
/// authority. A grant ledger retains revoked slots and never reuses them.
pub const GrantId = struct {
    owner: OwnerId,
    slot: u32,
    generation: u64,

    pub fn eql(a: GrantId, b: GrantId) bool {
        return std.meta.eql(a, b);
    }
};

pub const ResourceId = struct {
    owner: OwnerId,
    slot: u32,
    generation: u64,

    pub fn eql(a: ResourceId, b: ResourceId) bool {
        return std.meta.eql(a, b);
    }

    /// Strict total order for canonical resource selections.
    pub fn lessThan(a: ResourceId, b: ResourceId) bool {
        if (a.owner != b.owner) return @backingInt(a.owner) < @backingInt(b.owner);
        if (a.slot != b.slot) return a.slot < b.slot;
        return a.generation < b.generation;
    }
};
