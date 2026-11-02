//! Cap'n Proto codec barrel. See `decode` for the borrowed-view decode path,
//! `encode` for rendering, `layout` for layout/reader vocabulary, and `wire`
//! for the word-aligned wire primitives they build on.

pub const decode = @import("decode.zig");
pub const encode = @import("encode.zig");
pub const layout = @import("layout.zig");
pub const wire = @import("wire.zig");

pub const Error = layout.Error;
pub const EncodeError = layout.EncodeError;
pub const Kind = layout.Kind;

pub const decodeMessageView = decode.decodeMessageView;
pub const decodeBody = decode.decodeBody;
pub const decodeBodyForProfile = decode.decodeBodyForProfile;
pub const decodeBodyInto = decode.decodeBodyInto;
pub const decodeOwned = decode.decodeOwned;
pub const encodeMessage = encode.encodeMessage;
pub const encodeMessageForProfile = encode.encodeMessageForProfile;
pub const encodeBody = encode.encodeBody;
pub const encodeBodyForProfile = encode.encodeBodyForProfile;
/// Cap'n Proto sizes its own segments: no meter walks a tree ahead of its
/// encode.
pub const meter: ?type = null;
