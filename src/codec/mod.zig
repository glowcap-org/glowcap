//! The two wire codecs, plus the switch that picks between them.
//!
//! `syrup` works in byte records, `capnp` in 8-byte words, but they agree on
//! everything that matters: decode either one and you get the same borrowed
//! `model.view.Body`, and encode the same message through either and you get
//! equivalent bytes. `dispatch` is what routes a frame to whichever codec the
//! session negotiated, so the engine above never has to name a codec itself.
//! Either way, a codec only reads and writes bytes. It never decides what's valid.

pub const syrup = @import("syrup/mod.zig");
pub const capnp = @import("capnp/mod.zig");
pub const dispatch = @import("dispatch.zig");
