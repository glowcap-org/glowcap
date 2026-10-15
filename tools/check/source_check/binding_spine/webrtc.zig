//! WebRTC cap policy pins across the Zig resident, Rust sidecar, and TS browser
//! adapter.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;
const expectFileContains = util.expectFileContains;
const fileContains = util.fileContains;

/// WebRTC's resident owns packet, signaling, and ICE admission caps. Native
/// sidecars consume generated mirrors, and the TS browser adapter must apply
/// text caps as UTF-8 bytes rather than JS string units.
pub fn checkSignalAndIceCaps(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const zig_root_path = "src/net/transport/webrtc.zig";
    const zig_sidecar_path = "src/net/transport/webrtc/sidecar.zig";
    const rust_path = "transports/webrtc/src/lib.rs";
    const rust_gen_path = "transports/webrtc/src/constants_gen.rs";
    const ts_peer_path = "bindings/ts/webrtc/peer.ts";
    try expectFileContains(io, gpa, root, violations, zig_root_path, &.{
        "pub const max_packet_bytes = known_transport.metadata().max_packet_bytes;",
        "pub const max_signal_bytes = sidecar.max_signal_bytes;",
        "pub const max_ice_candidate_bytes = sidecar.max_ice_candidate_bytes;",
        "pub const max_ice_servers = sidecar.max_ice_servers;",
        "pub const max_ice_urls_per_server = sidecar.max_ice_urls_per_server;",
        "pub const max_ice_url_bytes = sidecar.max_ice_url_bytes;",
        "pub const max_ice_credential_bytes = sidecar.max_ice_credential_bytes;",
        "pub const max_pending_ice_candidates: usize = 256;",
        "pub const pending_ice_candidate_queue_bytes: usize = 64 * 1024;",
        "pub const data_channel_queue_bytes: usize = 1 * 1024 * 1024;",
        "pub const sctp_receive_buffer_bytes: usize = data_channel_queue_bytes;",
    });
    try expectFileContains(io, gpa, root, violations, rust_gen_path, &.{
        "src/net/transport/webrtc.zig. Do not edit.",
        "pub(crate) const TRANSPORT_WEBRTC_MAX_PACKET_BYTES: usize =",
        "pub(crate) const MAX_SIGNAL_BYTES: usize =",
        "pub(crate) const MAX_ICE_CANDIDATE_BYTES: usize =",
        "pub(crate) const MAX_ICE_SERVERS: usize =",
        "pub(crate) const MAX_ICE_URLS_PER_SERVER: usize =",
        "pub(crate) const MAX_ICE_URL_BYTES: usize =",
        "pub(crate) const MAX_ICE_CREDENTIAL_BYTES: usize =",
        "pub(crate) const MAX_PENDING_ICE_CANDIDATES: usize =",
        "pub(crate) const PENDING_ICE_CANDIDATE_QUEUE_BYTES: usize =",
        "pub(crate) const DATA_CHANNEL_QUEUE_BYTES: usize =",
        "pub(crate) const SCTP_RECEIVE_BUFFER_BYTES: usize =",
    });
    try expectFileContains(io, gpa, root, violations, zig_sidecar_path, &.{
        "const rc_signal_too_large: i32 = -4;",
        "const rc_closed: i32 = -5;",
        "pub const max_signal_bytes: usize = 16 * 1024;",
        "pub const max_ice_candidate_bytes: usize = max_signal_bytes;",
        "pub const max_ice_servers: usize = 16;",
        "pub const max_ice_urls_per_server: usize = 16;",
        "pub const max_ice_url_bytes: usize = 2 * 1024;",
        "pub const max_ice_credential_bytes: usize = 4 * 1024;",
    });
    try expectFileContains(io, gpa, root, violations, rust_path, &.{
        "const SIGNAL_TOO_LARGE: i32 = -4;",
        "const CLOSED: i32 = -5;",
        "mod constants_gen;",
        "const MAX_PACKET_BYTES: usize = constants_gen::TRANSPORT_WEBRTC_MAX_PACKET_BYTES;",
        "const MAX_SIGNAL_BYTES: usize = constants_gen::MAX_SIGNAL_BYTES;",
        "const MAX_ICE_CANDIDATE_BYTES: usize = constants_gen::MAX_ICE_CANDIDATE_BYTES;",
        "const MAX_PENDING_CANDIDATES: usize = constants_gen::MAX_PENDING_ICE_CANDIDATES;",
        "const CANDIDATE_QUEUE_BYTES: usize = constants_gen::PENDING_ICE_CANDIDATE_QUEUE_BYTES;",
        "const INBOUND_BUFFER_BOUND: usize = constants_gen::DATA_CHANNEL_QUEUE_BYTES;",
        "const SCTP_RECEIVE_BUFFER_BOUND: usize = constants_gen::SCTP_RECEIVE_BUFFER_BYTES;",
        "const OUTBOUND_BUFFER_BOUND: usize = constants_gen::DATA_CHANNEL_QUEUE_BYTES;",
        "const MAX_ICE_SERVERS: usize = constants_gen::MAX_ICE_SERVERS;",
        "const MAX_ICE_URLS_PER_SERVER: usize = constants_gen::MAX_ICE_URLS_PER_SERVER;",
        "const MAX_ICE_URL_BYTES: usize = constants_gen::MAX_ICE_URL_BYTES;",
        "const MAX_ICE_CREDENTIAL_BYTES: usize = constants_gen::MAX_ICE_CREDENTIAL_BYTES;",
    });
    try expectFileContains(io, gpa, root, violations, "bindings/ts/webrtc/signal.ts", &.{
        "export function utf8ByteLengthUpTo(text: string, stopAfter?: number): number",
    });
    try expectFileContains(io, gpa, root, violations, ts_peer_path, &.{
        "WEBRTC_MAX_ICE_CANDIDATE_BYTES",
        "WEBRTC_MAX_PENDING_ICE_CANDIDATES",
        "WEBRTC_PENDING_ICE_CANDIDATE_QUEUE_BYTES",
        "import { assertSignalBytes, utf8ByteLengthUpTo } from \"./signal.ts\";",
        "const MAX_PENDING_ICE_CANDIDATES = WEBRTC_MAX_PENDING_ICE_CANDIDATES;",
        "const MAX_ICE_CANDIDATE_BYTES = WEBRTC_MAX_ICE_CANDIDATE_BYTES;",
        "const MAX_PENDING_ICE_CANDIDATE_BYTES = WEBRTC_PENDING_ICE_CANDIDATE_QUEUE_BYTES;",
        "textBytes += utf8ByteLengthUpTo(text, MAX_ICE_CANDIDATE_BYTES - textBytes);",
    });
    try expectFileContains(io, gpa, root, violations, "bindings/ts/webrtc/channel.ts", &.{
        "WEBRTC_DATA_CHANNEL_QUEUE_BYTES",
        "const rtcSendHighWaterBytes = WEBRTC_DATA_CHANNEL_QUEUE_BYTES;",
        "const rtcReceiveMaxQueuedBytes = WEBRTC_DATA_CHANNEL_QUEUE_BYTES;",
    });
    try expectFileContains(io, gpa, root, violations, "bindings/ts/webrtc/connector.ts", &.{
        "Session.establishDialedLocator(",
        "request.handshakeTimeoutMs,",
        "// Directory signaling was scoped to this designator, and DTLS binds",
        "locator.designator,",
    });
    try expectFileContains(io, gpa, root, violations, "bindings/ts/webrtc/listener.ts", &.{
        "Session.establishAccepted(host, {",
        "// The signaling authority scoped this exchange to the offerer, and",
        "verifiedChannelKey: designator,",
        "WEBRTC_MAX_ACCEPTS_IN_FLIGHT",
    });
    if (try fileContains(io, gpa, root, ts_peer_path, "TEXT_UNITS")) {
        try appendViolation(gpa, violations, "{s}: forbidden `TEXT_UNITS` - WebRTC candidate caps are UTF-8 byte caps", .{ts_peer_path});
    }
    if (try fileContains(io, gpa, root, ts_peer_path, "textUnits")) {
        try appendViolation(gpa, violations, "{s}: forbidden `textUnits` - WebRTC candidate accounting is UTF-8 byte accounting", .{ts_peer_path});
    }
    if (try fileContains(io, gpa, root, ts_peer_path, "MAX_ICE_CANDIDATE_BYTES = 4 * 1024")) {
        try appendViolation(gpa, violations, "{s}: forbidden local ICE candidate cap - use WEBRTC_MAX_ICE_CANDIDATE_BYTES", .{ts_peer_path});
    }
}
