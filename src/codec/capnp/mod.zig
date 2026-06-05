//! Cap'n Proto codec barrel. See [`core`] for the codec body and [`wire`] for
//! the word-aligned wire primitives it builds on.

pub const core = @import("core.zig");
pub const wire = @import("wire.zig");

pub const Error = core.Error;
pub const Kind = core.Kind;

pub const decodeView = core.decodeView;
pub const decodeBody = core.decodeBody;
pub const decodeOwned = core.decodeOwned;
pub const ownedFromView = core.ownedFromView;
pub const encodeMessage = core.encodeMessage;
pub const encodeMessageForProfile = core.encodeMessageForProfile;

pub const MessageView = core.MessageView;
