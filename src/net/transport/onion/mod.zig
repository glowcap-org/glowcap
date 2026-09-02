//! The `onion` netlayer: the one transport the OCapN draft standardizes.
//!
//! glowcap reaches Tor the way the pinned Spritely Goblins does, by talking to a
//! daemon the deployment already started. There is no embedded Tor, no spawned
//! process, and nothing supervised, so the whole transport is two conversations
//! with that daemon over local sockets
//! ([ADR-0108](../../../../docs/decisions/adr/ADR-0108-onion-netlayer.md)).
//!
//! Outbound is SOCKS5: `socks5.zig` builds and checks the bytes for connecting
//! to `<serviceid>.onion` on port 9045, and what comes back is an ordinary byte
//! stream that glowcap's existing frame reader carries unchanged. Hosting is the
//! Tor control protocol: `control.zig` formats the authenticate, create, and
//! restore requests and classifies the reply lines they answer with.
//!
//! Those two modules are bytes only, opening no socket, so the conformance
//! evidence runs with no Tor daemon and no network: the tests compare
//! their buffers to the two reference implementations. `endpoint.zig` says where a
//! local Tor listens, `session.zig` carries those bytes over real streams, and
//! `resident.zig` presents the pair as a netlayer the driver dials and hosts
//! against.
//!
//! The loopback checks drive fake SOCKS and control daemons on loopback. The
//! opt-in `onion-interop` and `goblins-onion` steps cross real Tor circuits,
//! including both directions against Goblins' own onion netlayer.
//! `src/c_abi/net_transport/onion/` carries this transport to C, and all four
//! language bindings wrap that archive. The blocking `driver.listen`/`Server`
//! path drives a `Resident`; no completion loop adopts it yet, so each blocking
//! connection still has its own I/O owner.

/// The SOCKS5 client that dials an onion service through a local Tor. See
/// `socks5.zig`.
pub const socks5 = @import("socks5.zig");

/// The Tor control protocol conversation that creates and restores a version 3
/// onion service. See `control.zig`.
pub const control = @import("control.zig");

/// Where a local Tor daemon listens: an address and port, or a Unix socket path.
/// See `endpoint.zig`.
pub const endpoint = @import("endpoint.zig");
pub const Endpoint = endpoint.Endpoint;

/// The scalable completion-loop adapter. It composes Tor SOCKS and service
/// publication over a platform completion backend without owning a second loop.
pub const completion = @import("completion.zig");

/// The live conversations over those endpoints: the SOCKS handshake and the
/// control session a hosting listener holds open. See `session.zig`.
pub const session = @import("session.zig");

/// The netlayer resident: dial and accept over the ADR-0043 contract. See
/// `resident.zig`.
pub const resident = @import("resident.zig");
pub const Resident = resident.Resident;
pub const Listener = resident.Listener;
pub const Config = resident.Config;
pub const transport_name = resident.transport_name;
pub const locator = resident.locator;
