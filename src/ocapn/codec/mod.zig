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

pub const syrup = @import("syrup");
pub const capnp = @import("capnp");

comptime {
    // The two codecs' decode-depth caps are one bound: a frame one codec
    // refuses for depth must refuse under the other too, and both sit above
    // the owned materializer's `model.max_value_depth` so decode never rejects
    // a frame the model walk would still admit.
    std.debug.assert(syrup.decode.max_decode_nesting == capnp.decode.max_charge_depth);
    std.debug.assert(syrup.decode.max_decode_nesting > model.max_value_depth);
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
/// The open set of codecs this build speaks. Declare `pub const pancake_codecs`
/// in your root source file to add your own (see `registry.Spec`).
pub const registry = @import("registry.zig");
