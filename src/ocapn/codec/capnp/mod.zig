//! Cap'n Proto codec barrel. See `decode` for the borrowed-view decode path,
//! `encode` for rendering, `shared` for layout/reader vocabulary, and `wire`
//! for the word-aligned wire primitives they build on.

pub const decode = @import("decode.zig");
pub const encode = @import("encode.zig");
pub const shared = @import("shared.zig");
pub const wire = @import("wire.zig");

pub const Error = shared.Error;
pub const Kind = shared.Kind;

pub const decodeMessageView = decode.decodeMessageView;
pub const decodeBody = decode.decodeBody;
pub const decodeBodyForProfile = decode.decodeBodyForProfile;
pub const decodePrefix = decode.decodePrefix;
pub const decodePrefixForProfile = decode.decodePrefixForProfile;
pub const framePrefix = decode.framePrefix;
// A Cap'n Proto frame's length is computable from its segment table, so there
// is no incremental `scanStream`; the registry checks this declaration against
// that absence.
pub const self_delimiting = false;
pub const decodeOwned = decode.decodeOwned;
pub const encodeMessage = encode.encodeMessage;
pub const encodeMessageForProfile = encode.encodeMessageForProfile;
