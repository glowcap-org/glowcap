//! The two wire codecs, plus the switch that picks between them.
//!
//! `syrup` works in byte records, `capnp` in 8-byte words, but they agree on
//! everything that matters: decode either one and you get the same borrowed
//! `model.view.Body`, and encode the same message through either and you get
//! equivalent bytes. `dispatch` is what routes a frame to whichever codec the
//! session negotiated, so the engine above never has to name a codec itself.
//! Either way, a codec only reads and writes bytes. It never decides what's valid.

const std = @import("std");
const model = @import("model");

const limits = @import("codec_limits");

pub const syrup = @import("syrup");
pub const capnp = @import("capnp");

comptime {
    std.debug.assert(syrup.decode.max_decode_nesting == limits.max_decode_nesting);
    std.debug.assert(capnp.decode.max_charge_depth == limits.max_decode_nesting);
    std.debug.assert(limits.max_decode_nesting > model.max_value_depth);
}
/// The verdicts a codec gives a byte-stream framer, and the resumable scan
/// that keeps a frame arriving in pieces from being re-walked per piece.
pub const framing = @import("framing");
/// Codec-neutral set/struct sort + adjacent-dupe refusal (ADR-0003).
pub const order = @import("codec_order");
pub const dispatch = @import("dispatch.zig");

/// The byte form OCapN signatures are defined over: Syrup, whatever codec the
/// session negotiated. The engine reaches signature bytes only through here.
pub const signed = @import("signed.zig");
/// The open set of codecs this build speaks. Declare `pub const glowcap_codecs`
/// in your root source file to add your own (see `registry.Spec`).
pub const registry = @import("registry.zig");
