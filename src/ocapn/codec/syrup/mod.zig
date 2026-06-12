//! Syrup codec barrel. See `shared` for the error sets both halves use; the
//! implementations live in `decode.zig` and `encode.zig`, the same
//! decode/encode/shared split the `codec.capnp` barrel uses.

pub const shared = @import("shared.zig");
pub const decode = @import("decode.zig");
pub const encode = @import("encode.zig");

pub const Error = shared.Error;
pub const WalkError = shared.WalkError;
pub const EncodeError = shared.EncodeError;

pub const decodeBody = decode.decodeBody;
pub const decodePrefix = decode.decodePrefix;
pub const decodeOwned = decode.decodeOwned;
pub const readBytes = decode.readBytes;
pub const readHintsOwned = decode.readHintsOwned;
pub const readLocatorOwned = decode.readLocatorOwned;
pub const spanSignedHandoffGive = decode.spanSignedHandoffGive;

pub const encodeMessage = encode.encodeMessage;
pub const encodeMessageForProfile = encode.encodeMessageForProfile;
pub const canonicalLocationSignedBytes = encode.canonicalLocationSignedBytes;
pub const canonicalLocationSignedBytesRaw = encode.canonicalLocationSignedBytesRaw;
pub const canonicalHandoffGiveSignedBytes = encode.canonicalHandoffGiveSignedBytes;
pub const canonicalHandoffReceiveSignedBytes = encode.canonicalHandoffReceiveSignedBytes;
pub const handoffGiveRecordBytesRawLocation = encode.handoffGiveRecordBytesRawLocation;
pub const wrapSignedHandoffGive = encode.wrapSignedHandoffGive;
