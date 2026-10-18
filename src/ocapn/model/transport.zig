//! OCapN transport symbols and the shared locator-hint name.
//!
//! These are locator vocabulary, not I/O: every netlayer resident and the
//! sans-io driver (`driver_core.vocab`) must use the same bytes. Residents
//! derive `transport_name` and locator posture from `Known.metadata`. Keeping
//! those facts here, under `model`, which both `net` and `driver_core` may
//! import, prevents parallel registries across the I/O ban.

const std = @import("std");

/// What a transport's locator designator means. The locator vocabulary owns
/// this distinction because handshake admission and netlayer dispatch must
/// interpret the same transport symbol identically.
pub const DesignatorScheme = enum { address, key };

/// Where a host-port realization obtains its dial address. This is locator
/// grammar, not an I/O backend choice: TCP uses it, and an extension transport
/// with the same locator shape can use it without claiming to be TCP.
pub const AddressSource = enum { none, designator, direct_addresses_hint };

/// The host-integration shape required to open a locator. This classifies the
/// authority an adapter needs without selecting a concrete implementation.
pub const DialShape = enum { unsupported, host_port, peer_id, signaling, rendezvous, route_bundle };

/// How a transport presents CapTP frames to the host once the channel exists.
/// Byte streams need ADR-0110's outer Syrup byte-string envelope. Transports
/// that preserve message boundaries carry one bare codec frame per message.
pub const WireFraming = enum { byte_stream, message };

pub const Metadata = struct {
    symbol: []const u8,
    designator_scheme: DesignatorScheme,
    address_source: AddressSource = .none,
    dial_shape: DialShape = .unsupported,
    sealed_channel: bool = false,
    wire_framing: WireFraming = .byte_stream,
    /// Maximum single transport packet payload. Zero means the transport adds
    /// no packet cap below the session's frame cap.
    max_packet_bytes: usize = 0,

    pub fn eql(left: Metadata, right: Metadata) bool {
        return std.mem.eql(u8, left.symbol, right.symbol) and
            left.designator_scheme == right.designator_scheme and
            left.address_source == right.address_source and
            left.dial_shape == right.dial_shape and
            left.sealed_channel == right.sealed_channel and
            left.wire_framing == right.wire_framing and
            left.max_packet_bytes == right.max_packet_bytes;
    }

    pub fn provesKeyDesignator(self: Metadata) bool {
        if (self.designator_scheme != .key) return false;
        return self.sealed_channel or self.dial_shape == .peer_id or self.dial_shape == .signaling;
    }
};

/// The transport symbols whose locator semantics glowcap defines. Extensions
/// remain legal at runtime, but the exhaustive metadata switch gives each
/// first-party symbol exactly one policy definition.
pub const Known = enum {
    tcp,
    onion,
    keyed_tcp,
    inproc,
    iroh,
    keyed_relay,
    webrtc,
    noise_tcp,
    noise_relay,
    id,

    pub fn metadata(self: Known) Metadata {
        return switch (self) {
            .tcp => .{ .symbol = "tcp", .designator_scheme = .address, .address_source = .designator, .dial_shape = .host_port },
            .onion => .{ .symbol = "onion", .designator_scheme = .address },
            .keyed_tcp => .{ .symbol = "keyed-tcp", .designator_scheme = .key, .address_source = .direct_addresses_hint, .dial_shape = .host_port },
            .inproc => .{ .symbol = "inproc", .designator_scheme = .address },
            .iroh => .{ .symbol = "iroh", .designator_scheme = .key, .dial_shape = .peer_id },
            .keyed_relay => .{ .symbol = "keyed-relay", .designator_scheme = .key, .dial_shape = .rendezvous },
            .webrtc => .{ .symbol = "webrtc", .designator_scheme = .key, .dial_shape = .signaling, .wire_framing = .message, .max_packet_bytes = 16 * 1024 },
            .noise_tcp => .{ .symbol = "noise-tcp", .designator_scheme = .key, .address_source = .direct_addresses_hint, .dial_shape = .host_port, .sealed_channel = true },
            .noise_relay => .{ .symbol = "noise-relay", .designator_scheme = .key, .dial_shape = .rendezvous, .sealed_channel = true },
            .id => .{ .symbol = "id", .designator_scheme = .key, .dial_shape = .route_bundle },
        };
    }
};

comptime {
    const values = std.enums.values(Known);
    for (values, 0..) |known, i| {
        const left = known.metadata();
        if (left.symbol.len == 0) @compileError("a transport symbol cannot be empty");
        for (values[i + 1 ..]) |other| {
            const right = other.metadata();
            if (std.mem.eql(u8, left.symbol, right.symbol))
                @compileError("transport metadata contains a duplicate symbol");
        }
    }
}

pub fn parseKnown(symbol: []const u8) ?Known {
    inline for (std.enums.values(Known)) |known| {
        if (std.mem.eql(u8, symbol, known.metadata().symbol)) return known;
    }
    return null;
}

pub const SymbolError = error{InvalidTransportSymbol};

/// Validate the OCapN peer-locator transport symbol. The locator grammar uses
/// the final `.` as its designator/transport separator and the Syrup form
/// explicitly forbids `.` inside the transport symbol.
pub fn validateSymbol(symbol: []const u8) SymbolError!void {
    if (symbol.len == 0 or std.mem.indexOfScalar(u8, symbol, '.') != null)
        return error.InvalidTransportSymbol;
}

/// Expand the portable provider claim into this model's complete metadata.
/// Provider ABIs need only carry the locator-level facts every implementation
/// shares. First-party dial planning remains canonical here and extensions
/// retain the conservative defaults they declared.
pub fn metadataFromClaim(
    symbol: []const u8,
    designator_scheme: DesignatorScheme,
    sealed_channel: bool,
    wire_framing: WireFraming,
    max_packet_bytes: usize,
) (SymbolError || error{TransportSemanticsConflict})!Metadata {
    try validateSymbol(symbol);
    if (parseKnown(symbol)) |known| {
        const metadata = known.metadata();
        if (metadata.designator_scheme != designator_scheme or
            metadata.sealed_channel != sealed_channel or
            metadata.wire_framing != wire_framing or
            metadata.max_packet_bytes != max_packet_bytes)
            return error.TransportSemanticsConflict;
        return metadata;
    }
    return .{
        .symbol = symbol,
        .designator_scheme = designator_scheme,
        .sealed_channel = sealed_channel,
        .wire_framing = wire_framing,
        .max_packet_bytes = max_packet_bytes,
    };
}

/// Plain TCP: designator is `host:port` (cleartext conformance transport).
pub const tcp = Known.tcp.metadata().symbol;

/// Tor onion service: designator is the version 3 service id, without its
/// `.onion` suffix, which the locator's transport label supplies. The one
/// transport symbol the OCapN draft standardizes, and the one upstream Spritely
/// Goblins ships (ADR-0108).
///
/// The designator stays an address even though a version 3 service id encodes an
/// Ed25519 public key. Tor's rendezvous handshake proves the far end holds that
/// key, but what the key names is the rendezvous service. The CapTP peer is
/// whoever holds the local endpoint the service forwards to. ADR-0108 derives
/// this, and the pinned Goblins dials and is dialed on the same reading.
pub const onion = Known.onion.metadata().symbol;

/// Keyed TCP: designator is the partner Ed25519 key. Socket address rides the
/// `direct-addresses` hint (ADR-0075).
pub const keyed_tcp = Known.keyed_tcp.metadata().symbol;

/// In-process pipes: designator is a switchboard name, no sockets.
pub const inproc = Known.inproc.metadata().symbol;

/// Iroh encrypted QUIC: designator is the endpoint node id (Ed25519 key).
pub const iroh = Known.iroh.metadata().symbol;

/// Relay rendezvous: designator is the peer's Ed25519 key, and there is no
/// dialable address, the peer holds an inbound socket at a relay under this
/// key, and a dialer is bridged onto it (ADR-0088 cold-dial rendezvous). The
/// byte channel is the relay leg. The keyed handshake runs end to end. Used to
/// reach a peer that opens no listening socket, such as a browser.
pub const keyed_relay = Known.keyed_relay.metadata().symbol;

/// WebRTC DataChannel: designator is the peer's Ed25519 key, and the offer,
/// answer, and ICE candidates that bring the channel up ride a signaling
/// capability rather than a dialable address (ADR-0089).
pub const webrtc = Known.webrtc.metadata().symbol;

/// Noise-sealed TCP (ADR-0107): `tcp` sockets carrying the sealed byte
/// channel. The designator is the responder's durable Ed25519 key and the
/// socket address rides the `direct-addresses` hint, as `keyed-tcp`.
/// What differs is the wire, where the two CapTP peers complete a Noise_XK
/// handshake before any CapTP byte moves.
pub const noise_tcp = Known.noise_tcp.metadata().symbol;

/// Noise-sealed relay rendezvous (ADR-0107): the same sealed channel over a
/// relay's WebSocket pipe, so the relay forwards ciphertext. The designator
/// is the registered responder's Ed25519 key, as `keyed-relay`. The
/// relay transport owns the same registered byte-pipe realization, while the
/// Host selected by this symbol owns the sealed channel.
/// The completion-loop tier composes the same channel at its backend byte seam
/// because that tier has no HostSession.
pub const noise_relay = Known.noise_relay.metadata().symbol;

/// Transport-independent peer identity: the designator is the durable public
/// key and concrete carrier locators ride the transport-owned route hint below.
pub const id = Known.id.metadata().symbol;

/// Locator hint entry name that carries dial addresses when the designator is
/// a key (`keyed-tcp`, `iroh`).
pub const hint_direct_addresses = "direct-addresses";

/// Locator hint entry name carrying an ordered, pipe-separated list of complete
/// peer URIs to try after the locator carrying this hint. Pipe is outside the
/// URI query safe set, so a pipe inside a nested locator remains percent-encoded
/// and cannot become a list boundary after outer URI decoding. The value is
/// routing advice, not peer identity: the recipient owns the fallback policy
/// and the exporter locator remains the signed authority for the redeem.
pub const hint_alt_locators = "alt-locators";

/// Id route-bundle hint. The name is transport-local: only `id` interprets it,
/// and `model.route_bundle` owns its parser.
pub const hint_via = "via";

/// Hint entry names that carry a peer's preferred wire profile: the CapTP
/// version as `CaptpVersion.hintToken`, the codec as `CodecId.hintToken`, and
/// the optional feature set as a comma-separated list of `FeatureSet` field
/// names. A token for a version or codec glowcap owns carries this build's
/// own-wire fingerprint (ADR-0252), and a token this build does not write
/// reads as the baseline on its axis.
///
/// They ride the locator a hello signs, the sender's own `acceptable_location`
/// beside `direct-addresses`, so a peer states its profile the same way it
/// states its addresses, and both ends do it symmetrically. On the locator a
/// dialer was handed they are read once, as knowledge rather than as a
/// preference: their presence on an onion address marks the acceptor as
/// glowcap (ADR-0118), and the settle still runs off the two hellos alone.
///
/// Three names because the axes are independent: a peer that understands one
/// settles that axis and takes the baseline on the other.
///
/// The version cannot go in the version field itself. A Goblins vat aborts on
/// any version string but its own, so stating a preference there would refuse
/// every partner that did not already share it. A hint is ignorable, which is
/// the property needed.
pub const hint_captp_version = "glowcap/captp-version";
pub const hint_codec = "glowcap/codec";
pub const hint_features = "glowcap/features";

pub fn isProfileHintName(name: []const u8) bool {
    return std.mem.eql(u8, name, hint_captp_version) or
        std.mem.eql(u8, name, hint_codec) or
        std.mem.eql(u8, name, hint_features);
}
