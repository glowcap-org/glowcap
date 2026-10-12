//! Resource names include an owner namespace and slot incarnation.
//! They support comparison and lookup only. None carries invocation authority.

/// Stable authority-store identity. A fresh store requires a fresh identity.
/// Recreating an empty store with an old identity is not restoration.
pub const OwnerId = enum(u128) { _ };
pub const KindId = enum(u64) { _ };
pub const Revision = enum(u64) { _ };

/// A managed access record name. Passing this data confers no use or control
/// authority. A grant ledger retains revoked slots and never reuses them.
pub const GrantId = struct {
    owner: OwnerId,
    slot: u32,
    generation: u64,

    pub fn eql(a: GrantId, b: GrantId) bool {
        return a.owner == b.owner and a.slot == b.slot and a.generation == b.generation;
    }
};

pub const ResourceId = struct {
    owner: OwnerId,
    slot: u32,
    generation: u64,

    pub fn eql(a: ResourceId, b: ResourceId) bool {
        return a.owner == b.owner and a.slot == b.slot and a.generation == b.generation;
    }

    /// Strict total order for canonical resource selections.
    pub fn lessThan(a: ResourceId, b: ResourceId) bool {
        if (a.owner != b.owner) return @backingInt(a.owner) < @backingInt(b.owner);
        if (a.slot != b.slot) return a.slot < b.slot;
        return a.generation < b.generation;
    }
};
