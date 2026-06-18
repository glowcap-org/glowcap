//! pancake is an OCapN / CapTP implementation you use as a library, written in
//! Zig.
//!
//! New here? Read the layers from the top down. Each one only leans on the ones
//! above it, so you can stop wherever you have what you need.
//!
//! - `foundation` is the raw material: wire bytes, who owns a frame, the peer and
//!   session IDs, and the crypto the handshake relies on.
//! - `ocapn` is the protocol itself, the four layers that *are* OCapN / CapTP.
//!   Everything else is built on top and adds no protocol of its own:
//!   - `ocapn.model` is the message itself. There's one codec-neutral shape, both
//!     codecs produce it, and the engine acts on it. Everyone agrees on it.
//!   - `ocapn.codec` turns that message into bytes and back. Syrup and Cap'n Proto
//!     each do it their own way. Neither one decides what counts as valid.
//!   - `ocapn.session` is the part that does decide. It holds the authoritative
//!     state and checks every message against the protocol before applying it.
//!   - `ocapn.engine` is the `Peer` you actually hold and drive. It's synchronous
//!     and does no I/O of its own: no sockets, no threads, no hidden scheduler.
//! - `actors` is the Goblins-shaped layer above the engine: a `Vat` of local
//!   objects with near-call and eventual-send, local or far over a bound peer. It
//!   stays in the sync, no-I/O core and adds no protocol the engine lacks.
//! - `net` is the one place real I/O lives. It drives a `Peer` over a byte
//!   stream and adds no protocol behavior of its own.
//! - `driver` sits above both `actors` and `net`: `driver.connect` and
//!   `driver.listen` each hand back an owning `Connection`, so a Zig app gets
//!   `connect`/`listen`/`fetch`/`publish`/`spawn`/`send`/`tell`/`serve`/`close`
//!   instead of a hand-written pump loop. It composes; it adds no protocol.
//!
//! Two more layers live under `src/` but not on this namespace, because a Zig
//! consumer has no use for them here. `c_abi` is the C interface — it is
//! compiled into the `libpancake_ocapn` archive, and a C consumer reaches it
//! through `pancake_ocapn.h` (plus the per-transport headers).
//! `conformance` runs fixed scenarios and hands back their wire bytes; it is
//! the test suite's oracle, not part of the runtime path, and the tests import
//! it directly.
//!
//! The whole core, foundation through engine, is deterministic, synchronous, and
//! free of I/O. The adapters are where the outside world gets in. For the bigger
//! picture, see `docs/architecture.md`.

pub const foundation = @import("foundation");

/// The OCapN / CapTP protocol core. These four layers *are* the protocol: the
/// codec-neutral `model`, the wire `codec`s, the authoritative `session`, and the
/// `engine` you drive. They are grouped under one namespace because everything
/// around them — `actors`, the adapters, the surfaces — adds no protocol of its
/// own. Reach them as `pancake.ocapn.engine.Peer`, `pancake.ocapn.model.Message`,
/// and so on.
pub const ocapn = struct {
    pub const model = @import("model");
    pub const codec = @import("codec");
    pub const session = @import("session");
    pub const engine = @import("engine");
};

pub const actors = @import("actors");
pub const net = @import("net");
pub const driver = @import("driver");

/// The sync, no-I/O peer you hold and drive — the front door of the engine.
pub const Peer = ocapn.engine.Peer;

/// A vat of local actor objects with near-call and eventual-send above the engine.
pub const Vat = actors.Vat;

/// The owning application connection `driver.connect` and `driver.listen` hand back.
pub const Connection = driver.Connection;

/// Owned wire bytes for one frame; the borrowed counterpart is `Frame.view`.
pub const Frame = foundation.Frame;

// `c_abi` is referenced here so its exported `pancake_*` symbols are compiled
// into the `libpancake_ocapn` archive, without exposing the module on the Zig namespace.
comptime {
    _ = @import("c_abi");
}
