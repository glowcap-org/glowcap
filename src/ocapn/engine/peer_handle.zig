//! The typed name of one peer registered under an engine `Node`.

/// The embedder's handle to one registered peer. Stable for the life of the
/// registration. Freed handles are not reused within a node's life, so a stale
/// handle fails closed rather than aliasing a later connection. Keep the type in
/// this leaf because bootstrap projection, lowering, and Node routing all cross
/// the same boundary without depending on one another.
pub const PeerHandle = enum(u64) {
    _,

    pub fn from(n: u64) PeerHandle {
        return @fromBackingInt(@intCast(n));
    }

    pub fn int(self: PeerHandle) u64 {
        return @backingInt(self);
    }
};
