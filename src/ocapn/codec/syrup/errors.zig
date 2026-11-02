//! The error sets both halves of the Syrup codec share: the structural `Error`,
//! the recursive walkers' `WalkError`, and the public `EncodeError`.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");

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
};

/// The error set of the mutually-recursive encode/decode walkers, the encoder
/// cycle, where `writeArgument`, `writeArgumentList`, and `writeCanonicalSet`
/// call one another, and the handoff readers. Zig cannot infer an error set
/// around a recursive cycle, so
/// these would otherwise have to fall back to the fully-erased error set and lose
/// exhaustiveness at every call site. Naming the union, the codec's structural
/// `Error`, the allocator's `OutOfMemory`, and the projection error, keeps them
/// typed.
pub const WalkError = Error || std.mem.Allocator.Error || model.view.ProjectError;

/// The public encode entry points' error set: the recursive walk's `WalkError`
/// plus the frame constructor's shape refusal, the same named-set posture as
/// the capnp codec's `layout.EncodeError`.
pub const EncodeError = WalkError || foundation.Frame.Error;
