//! pancake is an OCapN / CapTP implementation you use as a library, written in
//! Zig.
//!
//! New here? Read the layers from the top down. Each one only leans on the ones
//! above it, so you can stop wherever you have what you need.
//!
//! - `foundation` is the raw material: wire bytes, who owns a frame, the peer and
//!   session IDs, and the crypto the handshake relies on.
//! - `model` is the message itself. There's one codec-neutral shape, both codecs
//!   produce it, and the engine acts on it. Everyone agrees on this vocabulary.
//! - `codec` turns that message into bytes and back. Syrup and Cap'n Proto each
//!   do it their own way. Neither one decides what counts as valid.
//! - `session` is the part that does decide. It holds the authoritative state and
//!   checks every message against the protocol before it applies it.
//! - `engine` is the `Peer` you actually hold and drive. It's synchronous and
//!   does no I/O of its own: no sockets, no threads, no hidden scheduler.
//! - `c_abi` is the C interface, `libpancake` plus `pancake.h`. We keep it boring
//!   on purpose.
//! - `net_adapter` is the one place real I/O lives. It drives a `Peer` over a byte
//!   stream and adds no protocol behavior of its own.
//! - `conformance` runs fixed scenarios and hands back their wire bytes, so a
//!   consumer can check that it behaves like everyone else.
//!
//! The whole core, foundation through engine, is deterministic, synchronous, and
//! free of I/O. The adapters are where the outside world gets in. For the bigger
//! picture, see `docs/architecture.md`.

pub const codec = @import("codec/mod.zig");
pub const conformance = @import("conformance/mod.zig");
pub const c_abi = @import("c_abi/mod.zig");
pub const foundation = @import("foundation/mod.zig");
pub const model = @import("model/mod.zig");
pub const net_adapter = @import("net_adapter/mod.zig");
pub const engine = @import("engine/mod.zig");
pub const session = @import("session/mod.zig");

comptime {
    _ = c_abi;
}
