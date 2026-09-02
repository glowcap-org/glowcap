//! glowcap is an OCapN / CapTP implementation you use as a library, written in
//! Zig.
//!
//! New here? Read the layers from the bottom up. Each layer leans only on the
//! ones below it, so you can stop wherever you have what you need.
//!
//! - `foundation` is the raw material: wire bytes, who owns a frame, the peer and
//!   session IDs, and the crypto the handshake relies on.
//! - `ocapn` is the protocol itself, the four layers that *are* OCapN / CapTP.
//!   Everything else is built on top and adds no protocol of its own:
//!   - `ocapn.model` is the message itself. There's one codec-neutral shape, both
//!     codecs produce it, and the engine acts on it.
//!   - `ocapn.codec` turns that message into bytes and back. Syrup and Cap'n Proto
//!     each do it their own way. Neither one decides what counts as valid.
//!   - `ocapn.session` is the part that does decide. It holds the authoritative
//!     state and checks every message against the protocol before applying it.
//!   - `ocapn.engine` is the `Peer` you actually hold and drive. It's synchronous
//!     and does no I/O of its own: no sockets, no threads, no hidden scheduler.
//! - `actors` is the Goblins-shaped layer above the engine: a `Vat` of local
//!   objects, plus session `Port`s that route far sends over the owning peer. It
//!   stays in the sync, no-I/O core and adds no protocol the engine lacks.
//! - `net` owns transport realization and connection loops. It drives a `Peer`
//!   over byte streams and adds no protocol behavior of its own.
//! - `driver` sits above both `actors` and `net`: `driver.connect` and
//!   `driver.listen` each hand back an owning `Session`, so a Zig app gets
//!   `connect`, `listen`, `fetch`, `publish`, `spawn`, `send`, `tell`,
//!   `serve`, and `close` (plus `call`, the blocking send-and-await) instead
//!   of a hand-written pump loop. A `Session` is a view onto a `driver.HostRuntime`, which owns the
//!   transport I/O around one core `Host`; you construct the `HostRuntime`
//!   explicitly only when several sessions must share one Host identity, and
//!   that sharing is what lets an introduction from one partner settle as a
//!   live capability from another. It composes; it adds no protocol.
//!
//! More layers live under `src/` but not on this namespace, because a Zig
//! consumer reaches them through sharper roots. `c_abi` is the C interface; it
//! is compiled into archive families, and a C consumer reaches it through the
//! generated headers. `persistent` and `diagnostics` are opt-in module roots.
//! `oracle` runs fixed scenarios and hands back their wire bytes; it is the test
//! suite's reference of truth, not part of the runtime path, and tests import it
//! directly.
//!
//! The whole core, foundation through engine, is deterministic, synchronous, and
//! free of I/O. The adapters are where the outside world gets in. For the bigger
//! picture, see `docs/architecture.md`.

pub const foundation = @import("foundation");

/// The OCapN / CapTP protocol core. These four layers *are* the protocol: the
/// codec-neutral `model`, the wire `codec`s, the authoritative `session`, and the
/// `engine` you drive. They are grouped under one namespace because everything
/// around them — `actors`, the adapters, the surfaces — adds no protocol of its
/// own. Reach them as `glowcap.ocapn.engine.Peer`, `glowcap.ocapn.model.Message`,
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

/// The sync, no-I/O peer you hold and drive, the front door of the engine.
pub const Peer = ocapn.engine.Peer;

/// A vat of local actor objects with near-call and eventual-send above the engine.
pub const Vat = actors.Vat;

/// The owning application session `driver.connect` and `driver.listen` hand back.
pub const Session = driver.Session;

/// Owned wire bytes for one frame; the borrowed counterpart is `Frame.view`.
pub const Frame = foundation.Frame;

// `c_abi` is referenced here so its exported `glowcap_*` symbols are compiled
// into the `libglowcap_ocapn` archive, without exposing the module on the Zig namespace.
comptime {
    _ = @import("c_abi");
}
