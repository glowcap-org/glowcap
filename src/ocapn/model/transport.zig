//! OCapN transport symbols and the shared locator-hint name.
//!
//! These are locator vocabulary, not I/O: every netlayer resident and the
//! sans-io driver (`driver_core.vocab`) must use the same bytes. Residents
//! alias `transport_name` to one of these constants; vocab policy tables
//! compare against them. Keeping the literals here — under `model`, which both
//! `net` and `driver_core` may import — is what prevents the strings from
//! drifting apart across the I/O ban.

const std = @import("std");

/// Plain TCP: designator is `host:port` (cleartext conformance transport).
pub const tcp = "tcp";

/// Keyed TCP: designator is the partner Ed25519 key; socket address rides the
/// `direct-addresses` hint (ADR-0075).
pub const keyed_tcp = "keyed-tcp";

/// In-process pipes: designator is a switchboard name, no sockets.
pub const inproc = "inproc";

/// Iroh encrypted QUIC: designator is the endpoint node id (Ed25519 key).
pub const iroh = "iroh";

/// Relay rendezvous: designator is the peer's Ed25519 key, and there is no
/// dialable address — the peer holds an inbound socket at a relay under this
/// key, and a dialer is bridged onto it (ADR-0088 cold-dial rendezvous). The
/// byte channel is the relay leg; the keyed handshake runs end to end. Used to
/// reach a peer that opens no listening socket, such as a browser.
pub const keyed_relay = "keyed-relay";

/// WebRTC DataChannel: designator is the peer's Ed25519 key, and the offer,
/// answer, and ICE candidates that bring the channel up ride a signaling
/// capability rather than a dialable address (ADR-0089).
pub const webrtc = "webrtc";

/// What a transport's locator designator means. The locator vocabulary owns
/// this distinction because handshake admission and netlayer dispatch must
/// interpret the same transport symbol identically.
pub const DesignatorScheme = enum { address, key };

pub fn designatorScheme(transport: []const u8) DesignatorScheme {
    if (std.mem.eql(u8, transport, keyed_tcp)) return .key;
    if (std.mem.eql(u8, transport, iroh)) return .key;
    if (std.mem.eql(u8, transport, keyed_relay)) return .key;
    if (std.mem.eql(u8, transport, webrtc)) return .key;
    return .address;
}

/// Locator hint entry name that carries dial addresses when the designator is
/// a key (`keyed-tcp`, `iroh`).
pub const hint_direct_addresses = "direct-addresses";

/// Hint entry names that carry a peer's preferred wire profile: the CapTP
/// version in the same representation the version field uses
/// (`CaptpVersion.wireString`), the codec by the stable `u16` identity
/// `CodecId` declares, in decimal, and the optional feature set as a
/// comma-separated list of `FeatureSet` field names.
///
/// They ride the locator a hello signs — the sender's own `acceptable_location`
/// — beside `direct-addresses`, so a peer states its profile the same way it
/// states its addresses, and both ends do it symmetrically. Not the locator a
/// dialer was handed: nothing reads these there, because the handshake is the
/// baseline whatever the dialer knew and the settle runs off the two hellos.
///
/// Three names because the axes are independent: a peer that understands one
/// settles that axis and takes the baseline on the other.
///
/// The version cannot go in the version field itself. A Goblins vat aborts on
/// any version string but its own, so stating a preference there would refuse
/// every partner that did not already share it. A hint is ignorable, which is
/// the property needed.
pub const hint_captp_version = "pancake/captp-version";
pub const hint_codec = "pancake/codec";
pub const hint_features = "pancake/features";

pub fn isProfileHintName(name: []const u8) bool {
    return std.mem.eql(u8, name, hint_captp_version) or
        std.mem.eql(u8, name, hint_codec) or
        std.mem.eql(u8, name, hint_features);
}
