//! The optional borrowed-read group of `MultiplexedResident`.
//!
//! `try_read` copies into the caller's buffer, which a resident whose bytes
//! live across a foreign boundary needs. A resident that already holds each
//! received chunk in memory it owns between calls lends that chunk instead,
//! and the runtime feeds the core from the loan with no copy. The iroh and
//! WebRTC sidecars cannot lend and leave the group absent.

pub const Lend = union(enum) {
    /// The connection's next received bytes, one packet on a message-framed
    /// transport. Valid until `release` or a close of this connection.
    bytes: []const u8,
    would_block,
    end_of_stream,
    dead,
};

pub const VTable = struct {
    lend: *const fn (ctx: *anyopaque, conn: usize) Lend,
    /// The caller is done with every lent byte. A no-op for a connection that
    /// closed while lent.
    release: *const fn (ctx: *anyopaque, conn: usize) void,
};
