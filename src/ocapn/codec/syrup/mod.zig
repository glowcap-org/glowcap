//! Syrup codec barrel. See `shared` for the error sets both halves use; the
//! implementations live in `decode.zig` and `encode.zig`, the same
//! decode/encode/shared split the `codec.capnp` barrel uses.

pub const shared = @import("shared.zig");
pub const decode = @import("decode.zig");
pub const encode = @import("encode.zig");
pub const canonical = @import("canonical.zig");

pub const Error = shared.Error;

pub const decodeBody = decode.decodeBody;
pub const decodePrefix = decode.decodePrefix;
pub const decodeOwned = decode.decodeOwned;
pub const readLocatorOwned = decode.readLocatorOwned;
pub const decodeSignedHandoffGiveOwned = decode.decodeSignedHandoffGiveOwned;
pub const spanSignedHandoffGive = decode.spanSignedHandoffGive;

pub const encodeMessage = encode.encodeMessage;
pub const encodeMessageForProfile = encode.encodeMessageForProfile;
pub const canonicalLocationSignedBytes = canonical.canonicalLocationSignedBytes;
pub const canonicalLocationSignedBytesRaw = canonical.canonicalLocationSignedBytesRaw;
pub const canonicalHandoffGiveSignedBytes = canonical.canonicalHandoffGiveSignedBytes;
pub const canonicalHandoffReceiveSignedBytes = canonical.canonicalHandoffReceiveSignedBytes;
pub const handoffGiveRecordBytesRawLocation = canonical.handoffGiveRecordBytesRawLocation;
pub const wrapSignedHandoffGive = canonical.wrapSignedHandoffGive;
pub const encodePeerLocatorRecord = encode.encodePeerLocatorRecord;
