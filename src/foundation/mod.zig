//! The foundation layer, gathered in one place. These are the primitives every
//! other layer moves around: `frame` for wire bytes and who owns them, `spill`
//! for the stream bytes that have arrived but not yet been consumed as a frame, status-allow: pending state or quoted runtime label
//! `id` for the `PeerId` and `SessionId`, `crypto` for the Ed25519 and
//! SHA-256 work the handshake and handoff signatures need, `noise` for the
//! Noise_XK state machine ADR-0041 names, and `sealed` for the sealed byte
//! channel composed over it, down here because both stream tiers run one and
//! neither imports the other, the same argument that homes `spill`.
//! `stream_framing` is the outer length-prefix syntax a byte stream wraps
//! around each frame, and `failure_chain` is the plain first-and-consequence
//! failure record a cleanup path retains. `error_sets` spells an exact error
//! set where Zig cannot infer one, and `id_issuer` spends an in-memory id only
//! when the operation it names commits. Nothing down here knows a thing about the
//! message model above it.

pub const id = @import("id.zig");
pub const handle_table = @import("handle_table.zig");
pub const bearer_table = @import("bearer_table.zig");
pub const frame = @import("frame.zig");
pub const spill = @import("spill.zig");
pub const failure_chain = @import("failure_chain.zig");
pub const error_sets = @import("error_sets.zig");
pub const id_issuer = @import("id_issuer.zig");
pub const stream_framing = @import("stream_framing.zig");
pub const decimal = @import("decimal.zig");
pub const utf8 = @import("utf8.zig");
pub const crypto = @import("crypto.zig");
pub const noise = @import("noise.zig");
pub const sealed = @import("sealed.zig");
pub const thread_affinity = @import("thread_affinity.zig");
pub const identity_hash = @import("identity_hash.zig");
pub const inline_rows = @import("inline_rows.zig");

pub const Frame = frame.Frame;
pub const FrameShape = frame.FrameShape;
pub const FrameView = frame.FrameView;
pub const Spill = spill.Spill;
pub const FailureChain = failure_chain.FailureChain;
pub const FailureClassification = failure_chain.Classification;
pub const latchFailure = failure_chain.latch;
pub const PeerId = id.PeerId;
pub const SessionId = id.SessionId;
pub const PeerKey = crypto.PeerKey;
pub const SecretKey = crypto.SecretKey;
pub const Signature = crypto.Signature;
pub const CryptoError = crypto.CryptoError;
