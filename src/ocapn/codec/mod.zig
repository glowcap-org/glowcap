//! The two wire codecs, plus the switch that picks between them.
//!
//! `syrup` works in byte records, `capnp` in 8-byte words, but they agree on
//! everything that matters: decode either one and you get the same borrowed
//! `model.view.Body`, and encode the same message through either and you get
//! equivalent bytes. `dispatch` is what routes a frame to whichever codec the
//! session negotiated, so the engine above never has to name a codec itself.
//! Either way, a codec only reads and writes bytes. It never decides what's valid.

pub const syrup = @import("syrup");
pub const capnp = @import("capnp");
/// Codec-neutral set/struct sort + adjacent-dupe refusal (ADR-0003).
pub const order = @import("codec_order");
pub const dispatch = @import("dispatch.zig");
/// The open set of codecs this build speaks. Declare `pub const pancake_codecs`
/// in your root source file to add your own (see `registry.Spec`).
pub const registry = @import("registry.zig");
