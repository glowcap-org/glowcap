//! Syrup codec barrel. See `shared` for the error sets both halves use; the
//! implementations live in `decode.zig` and `encode.zig`, the same
//! decode/encode/shared split the `codec.capnp` barrel uses.

pub const shared = @import("shared.zig");
pub const decode = @import("decode.zig");
pub const encode = @import("encode.zig");
pub const canonical = @import("canonical.zig");
pub const render = @import("render.zig");
const signing = @import("signing.zig");

pub const Error = shared.Error;

pub const decodeBody = decode.decodeBody;
pub const decodeBodyForProfile = decode.decodeBodyForProfile;
pub const decodePrefix = decode.decodePrefix;
pub const decodePrefixForProfile = decode.decodePrefixForProfile;
pub const framePrefix = decode.framePrefix;
pub const scanStream = decode.scanStream;
// Syrup's grammar is self-delimiting, so a partial frame must be scanned
// incrementally; the registry checks this declaration against `scanStream`'s
// presence.
pub const self_delimiting = true;
pub const decodeOwned = decode.decodeOwned;
pub const readLocatorOwned = decode.readLocatorOwned;
pub const readLocatorView = decode.readLocatorView;
pub const decodeSignedHandoffGiveOwned = decode.decodeSignedHandoffGiveOwned;

pub const encodeMessage = encode.encodeMessage;
pub const encodeMessageForProfile = encode.encodeMessageForProfile;
pub const canonicalLocationSignedBytes = canonical.canonicalLocationSignedBytes;
pub const canonicalLocationSignedBytesRaw = canonical.canonicalLocationSignedBytesRaw;
pub const canonicalHandoffGiveSignedBytes = canonical.canonicalHandoffGiveSignedBytes;
pub const canonicalHandoffGiveViewSignedBytes = canonical.canonicalHandoffGiveViewSignedBytes;
pub const canonicalHandoffReceiveSignedBytes = canonical.canonicalHandoffReceiveSignedBytes;
pub const canonicalHandoffReceiveViewSignedBytes = canonical.canonicalHandoffReceiveViewSignedBytes;
pub const handoffGiveRecordBytesRawLocation = canonical.handoffGiveRecordBytesRawLocation;
pub const wrapSignedHandoffGive = canonical.wrapSignedHandoffGive;
pub const encodePeerLocatorRecord = signing.encodePeerLocatorRecord;
