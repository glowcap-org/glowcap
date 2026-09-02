//! Artifact entry root for `libglowcap_driver`.
//!
//! `mod.zig` is also imported as the driver C vocabulary. Keeping export
//! rooting here makes archive ownership structural: importing that vocabulary
//! cannot make another archive emit the `glowcap_driver_*` family.

const api = @import("mod.zig");

comptime {
    for (api.symbols.symbols) |symbol| _ = @field(api, symbol.name);
}
