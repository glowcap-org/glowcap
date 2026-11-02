//! The wire op symbol of each message-level `model.Message` kind, the one
//! source both Syrup halves read so the encoder and the decoder's dispatch
//! cannot disagree on a name.

const std = @import("std");

const model = @import("model");

/// The wire op symbol for each message-level `model.Message` kind, the one
/// source both codec halves read so the encoder's `writeSymbol` and the
/// decoder's dispatch table cannot disagree on a name. The switch is
/// exhaustive over the message tag, so a new `model.Message` kind fails to
/// compile here until it is named, and the decoder (which builds its dispatch
/// over the same tag set) gains the entry in the same breath. `op:gc-exports`
/// is not a mechanical transform of the kind name, which is why the
/// mapping is explicit.
pub fn messageOp(comptime kind: std.meta.Tag(model.Message)) []const u8 {
    return switch (kind) {
        .abort => "op:abort",
        .deliver => "op:deliver",
        .resolve => "op:resolve",
        .gc_export => "op:gc-exports",
        .gc_answer => "op:gc-answers",
        .get => "op:get",
        .index => "op:index",
        .untag => "op:untag",
        .listen => "op:listen",
        .start_session => "op:start-session",
    };
}
