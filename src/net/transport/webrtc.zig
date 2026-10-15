//! WebRTC DataChannel transport: a peer-to-peer channel for keyed OCapN
//! sessions. Unlike TCP or iroh, there is no dialable address. The channel is
//! established by an SDP signaling exchange (offer, answer, ICE candidates).
//! A `Resident` owns the shared sidecar runtime and readiness fd. Callers create
//! `Peer`s from it, drive signaling directly, then move one codec frame per
//! DataChannel message through packet-shaped try-I/O.
//!
//! The readiness path owns channel progress and non-blocking packet I/O.
//!
//! ## Usage sequence
//!
//! 1. Call `Resident.init`, register `Resident.readinessFd`, then create a peer
//!    in one signaling role with `resident.newPeer(is_offerer)`.
//! 2. Submit offers, answers, and remote candidates outside the reactor turn.
//!    Peer creation and signaling submissions are synchronous control calls.
//! 3. When the fd wakes, call `Resident.drainReady` and route each record by its
//!    stable `PeerId`. Drain local candidates on `ev_candidate`. Call `checkOpen`
//!    on `ev_open` and stop on `ev_closed`. A blocking owner can use
//!    `Resident.pollReady`, which performs the same ordered drain.
//! 4. Once open, use `tryReceivePacket` / `trySendPacket` from that readiness
//!    loop.
//!
//! ## Dial posture
//!
//! A `Resident` has no `dial` or `listen`: a bare WebRTC locator
//! carries no signaling authority. The dial classifier still recognizes the
//! transport symbol and validates the key designator. `driver_core.planDial` returns
//! `DialPlan.signaling`, and `GLOWCAP_DIAL_SHAPE_SIGNALING` ships in every
//! binding's constants table. The resident compiles and type-checks under
//! `zig build check` but is not a `Netlayer`. Generic Host integration is the
//! completion `Backend` below: as a `net.completion_resident` on
//! `driver.HostRuntime` it serves adopted answerers and drives offerer dials
//! through a configured `SignalingAuthority` (`zig build webrtc-loop`. The
//! three-party redeem over a bare webrtc give is `zig build webrtc-redeem`). A
//! blocking caller may still drive signaling and adopt the channel
//! explicitly.
//!
//! ## Sidecar posture
//!
//! The resident wraps the `glowcap_webrtc_sidecar` C ABI (`transports/webrtc/`).
//! It compiles as its own module outside the `glowcap` root namespace, so its
//! externs resolve only when the sidecar staticlib links. A hermetic object build
//! type-checks it under plain `zig build check` with no cargo.

const foundation = @import("foundation");
const model = @import("model");
const net = @import("net");

/// The transport symbol this resident signs into `op:start-session`. The dial
/// classifier recognizes it. The resident is not registered as a `Netlayer`
/// (see "Dial posture" above).
const known_transport = model.transport.Known.webrtc;
pub const transport_name = known_transport.metadata().symbol;
pub const max_packet_bytes = known_transport.metadata().max_packet_bytes;
pub const max_signal_bytes = sidecar.max_signal_bytes;
pub const max_ice_candidate_bytes = sidecar.max_ice_candidate_bytes;
pub const max_ice_servers = sidecar.max_ice_servers;
pub const max_ice_urls_per_server = sidecar.max_ice_urls_per_server;
pub const max_ice_url_bytes = sidecar.max_ice_url_bytes;
pub const max_ice_credential_bytes = sidecar.max_ice_credential_bytes;
pub const max_pending_ice_candidates: usize = 256;
/// How many accepts one listener holds at once, still signaling or opened and
/// not yet claimed. Each holds a peer connection, so an offer past it is
/// refused instead of queued.
pub const max_accepts_in_flight: usize = 64;
pub const pending_ice_candidate_queue_bytes: usize = 64 * 1024;
pub const data_channel_queue_bytes: usize = 1 * 1024 * 1024;
pub const sctp_receive_buffer_bytes: usize = data_channel_queue_bytes;

/// WebRTC locators name peers by keyed-session identity even though this
/// resident exposes no address-based `Netlayer` vtable.
pub const designator_scheme: net.netlayer.DesignatorScheme = known_transport.metadata().designator_scheme;

/// The peer's Ed25519 designator length, the same key width keyed-tcp and iroh
/// name their peers by.
pub const designator_len = foundation.crypto.PeerKey.designator_len;

/// Build the hint-free locator for a WebRTC peer's keyed identity. Signaling
/// authority belongs to the dialing Host, not to the locator.
pub fn locator(designator: []const u8) model.PeerLocator {
    return .{
        .transport = transport_name,
        .designator = designator,
        .hints = model.Hints.emptyFalse(),
    };
}

const sidecar = @import("webrtc/sidecar.zig");
const backend = @import("webrtc/backend/state.zig");

// Supported WebRTC surface. Leaf `pub` declarations are cross-file visibility;
// this facade is the consumer namespace.
pub const ev_open = sidecar.ev_open;
pub const ev_candidate = sidecar.ev_candidate;
pub const ev_readable = sidecar.ev_readable;
pub const ev_writable = sidecar.ev_writable;
pub const ev_closed = sidecar.ev_closed;
pub const ReadyEvent = sidecar.ReadyEvent;
pub const PeerId = sidecar.PeerId;
pub const StringView = sidecar.StringView;
pub const IceServerConfig = sidecar.IceServerConfig;
pub const SignalError = sidecar.SignalError;
pub const Peer = sidecar.Peer;
pub const Resident = sidecar.Resident;
pub const DialResolver = backend.DialResolver;
pub const SignalingAuthority = backend.SignalingAuthority;
pub const Backend = backend.Backend;
/// `Backend` as a HostRuntime resident's transport policy:
/// `net.completion_resident.Resident(Backend, ResidentPolicy)`.
pub const ResidentPolicy = @import("webrtc/resident_policy.zig").ResidentPolicy(Backend);

/// The provider profile a driver registration names for this transport.
pub const transport_profile = known_transport.metadata();
/// The completion-loop resident a driver hosts: one `Backend` behind the
/// shared readiness policy, dialed through `glowcap.driver.connect`.
pub const CompletionResident = net.completion_resident.Resident(Backend, ResidentPolicy);
