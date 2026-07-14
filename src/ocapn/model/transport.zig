//! OCapN transport symbols and the shared locator-hint name.
//!
//! These are locator vocabulary, not I/O: every netlayer resident and the
//! sans-io driver (`driver_core.vocab`) must spell the same bytes. Residents
//! alias `transport_name` to one of these constants; vocab policy tables
//! compare against them. Keeping the literals here — under `model`, which both
//! `net` and `driver_core` may import — is what prevents the strings from
//! drifting apart across the I/O ban.

/// Plain TCP: designator is `host:port` (cleartext conformance transport).
pub const tcp = "tcp";

/// Keyed TCP: designator is the partner Ed25519 key; socket address rides the
/// `direct-addresses` hint (ADR-0075).
pub const keyed_tcp = "keyed-tcp";

/// In-process pipes: designator is a switchboard name, no sockets.
pub const inproc = "inproc";

/// Iroh encrypted QUIC: designator is the endpoint node id (Ed25519 key).
pub const iroh = "iroh";

/// Locator hint entry name that carries dial addresses when the designator is
/// a key (`keyed-tcp`, `iroh`).
pub const hint_direct_addresses = "direct-addresses";
