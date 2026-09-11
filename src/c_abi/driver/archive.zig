//! Artifact entry root for `libglowcap_driver`.
//!
//! `mod.zig` is also imported as the driver C vocabulary. Keeping export
//! rooting here makes archive ownership structural: importing that vocabulary
//! cannot make another archive emit the `glowcap_driver_*` family.

pub const std_options = @import("c_abi_shared").library_options;

const api = @import("mod.zig");

comptime {
    for (api.symbols.symbols) |symbol| _ = @field(api, symbol.name);
}
