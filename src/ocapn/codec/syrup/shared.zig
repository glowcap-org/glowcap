//! The types both halves of the Syrup codec share: the `Error` and
//! `WalkError` sets.
//!
//! Syrup is the byte-record format, the self-delimiting alternative to Cap'n
//! Proto. It carries the same `model.Message` tree as length-prefixed records
//! (`<...>`), lists (`[...]`), symbols, strings, and integers. The encode half
//! lives in `encode` (`encodeMessage` and the `write*` primitives beneath it)
//! and the decode half lives in `decode` (`decodeBody`, profile-aware
//! `decodePrefix`, structural `framePrefix`, and `decodeOwned`, which is
//! `decodeBody` followed by `model.view.Body.toOwned`). Both halves come out
//! through the `syrup` barrel in `mod.zig`, and `codec.capnp` is the
//! word-aligned counterpart with the same decode/encode/shared split.
//!
//! As everywhere in the codec layer, this only describes and routes bytes. It
//! holds no session authority. Every frame the decoder reads is untrusted,
//! so the length math on each prefix is checked and the recursive
//! readers stop at a fixed nesting bound, which means a deeply nested frame fails
//! loudly instead of running off the stack.

const std = @import("std");

const foundation = @import("foundation");
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

pub const Error = error{
    InvalidFrameShape,
    MalformedFrame,
    UnsupportedArgument,
    UnsupportedMessage,
    UnsupportedReference,
    /// The exact-size encoder's measure and fill passes disagreed. Both pass
    /// through one generic walker, so caller data cannot induce this. Keeping
    /// it typed still contains an encoder defect to the operation instead of
    /// terminating an embedding process.
    EncoderInvariantViolation,
    /// The buffer ends inside a message, a leaf reader ran past the available
    /// bytes. This is an internal framing signal, not a public decode failure:
    /// the whole-frame `decodeBody` folds it into `MalformedFrame` (a frame
    /// must be complete), while the streaming `decodePrefix` surfaces it as
    /// `.incomplete` so the caller reads more bytes. No structurally-valid
    /// frame ever yields it from `decodeBody`.
    Incomplete,
    /// The in-flight message cannot fit inside the streaming byte cap, a
    /// length prefix declared a body past `max_frame_bytes`, or the decode walk
    /// crossed it. Like `Incomplete`, this is an internal framing signal: only
    /// `decodePrefix` can raise it (it threads the cap into the walk per
    /// ADR-0029) and it surfaces as the `.too_large` verdict. Whole-frame entry
    /// points decode uncapped and never yield it.
    FrameTooLarge,
};

/// The error set of the mutually-recursive encode/decode walkers, the encoder
/// cycle, where `writeArgument`, `writeArgumentList`, and `writeCanonicalSet`
/// call one another, and the handoff readers. Zig cannot infer an error set
/// around a recursive cycle, so
/// these would otherwise have to fall back to the fully-erased error set and lose
/// exhaustiveness at every call site. Naming the union, the codec's structural
/// `Error`, the allocator's `OutOfMemory`, and `NoSpaceLeft`, keeps them
/// typed. (`NoSpaceLeft` is unreachable: unsigned decimal write is
/// hand-rolled into a 20-byte stack buffer sized for a u64. The name stays so
/// WalkError callers do not churn.)
pub const WalkError = Error || std.mem.Allocator.Error || error{NoSpaceLeft};

/// The public encode entry points' error set: the recursive walk's `WalkError`
/// plus the frame constructor's shape refusal, the same named-set posture as
/// the capnp codec's `shared.EncodeError`.
pub const EncodeError = WalkError || foundation.Frame.Error;
