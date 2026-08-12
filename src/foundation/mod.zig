//! The foundation layer, gathered in one place. These are the primitives every
//! other layer moves around: `frame` for wire bytes and who owns them, `spill`
//! for the stream bytes that have arrived but not yet been consumed as a frame,
//! `id` for the `PeerId` and `SessionId`, `crypto` for the Ed25519 and
//! SHA-256 work the handshake and handoff signatures need, `noise` for the
//! Noise_XK state machine ADR-0107 names, and `sealed` for the sealed byte
//! channel composed over it — down here because both stream tiers run one and
//! neither imports the other, the same argument that homes `spill`. Nothing
//! down here knows a thing about the message model above it.

pub const id = @import("id.zig");
pub const frame = @import("frame.zig");
pub const spill = @import("spill.zig");
pub const stream_framing = @import("stream_framing.zig");
pub const crypto = @import("crypto.zig");
pub const noise = @import("noise.zig");
pub const sealed = @import("sealed.zig");

pub const Frame = frame.Frame;
pub const FrameShape = frame.FrameShape;
pub const FrameView = frame.FrameView;
pub const Spill = spill.Spill;
pub const PeerId = id.PeerId;
pub const SessionId = id.SessionId;
pub const PeerKey = crypto.PeerKey;
pub const SecretKey = crypto.SecretKey;
pub const Signature = crypto.Signature;
pub const CryptoError = crypto.CryptoError;
