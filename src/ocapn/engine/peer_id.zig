//! The typed name of one peer registered under an engine `Node`.

/// A connection id: the embedder's handle to one registered peer. Stable for
/// the life of the registration; freed ids are not reused within a node's life,
/// so a stale id fails closed rather than aliasing a later connection. Keep the
/// type in this leaf because bootstrap projection, lowering, and Node routing
/// all cross the same identity boundary without depending on one another.
pub const PeerId = enum(u64) {
    _,

    pub fn from(n: u64) PeerId {
        return @enumFromInt(n);
    }

    pub fn int(self: PeerId) u64 {
        return @intFromEnum(self);
    }
};
