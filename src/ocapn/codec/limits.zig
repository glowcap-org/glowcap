//! Shared codec refusal limits.
//!
//! These bounds protect native decode walks over untrusted frames.
//! They live above the sibling codecs so Syrup and Cap'n Proto ask one owner
//! instead of restating matching recursion ceilings.

const std = @import("std");

const model = @import("model");

/// Native recursion bound for codec decode walks. It sits above
/// `model.max_value_depth`, so a codec never refuses a frame the model
/// materializer would still admit.
pub const max_decode_nesting: usize = 512;

comptime {
    std.debug.assert(max_decode_nesting > model.max_value_depth);
}
