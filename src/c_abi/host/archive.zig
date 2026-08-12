//! Artifact entry root for `libpancake_host`.
//!
//! `mod.zig` is also imported by the native driver for shared opaque types and
//! ownership operations. Keeping export rooting here makes archive ownership
//! structural: importing the Host implementation cannot make another archive
//! emit the `pancake_host_*` family.

const api = @import("mod.zig");

comptime {
    for (api.symbols.symbols) |symbol| _ = @field(api, symbol.name);
}
