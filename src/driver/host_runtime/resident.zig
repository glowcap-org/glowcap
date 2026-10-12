//! Stable identities and retained state for multiplexed transport runtimes.

const net = @import("net");
const lifecycle = @import("lifecycle.zig");

/// One resident runtime, stored once no matter how many profiles it realizes.
/// Registration validates and caches the readiness descriptor. Request and
/// listener ids are minted inside this provider-local namespace.
pub const Registered = struct {
    resident: net.MultiplexedResident,
    readiness_fd: i32,
    next_request: usize = 1,
    next_listener_route: usize = 1,
};

/// One host-minted resident dial awaiting its matching connect record.
pub const DialWait = struct { ready: bool = false };
/// A request id is scoped to its resident runtime.
pub const RequestKey = struct { resident: usize, request: usize };
/// A connection id is scoped to its resident runtime.
pub const ConnectionKey = struct { resident: usize, conn: usize };
/// An accept route id is scoped to its resident runtime.
pub const ListenerKey = struct { resident: usize, route: usize };

pub const Listener = struct {
    listener: net.MultiplexedResident.Listener,
    transport: []const u8,
    observation: lifecycle.SessionAcceptObservation,
};
