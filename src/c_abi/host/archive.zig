//! Artifact entry root for `libglowcap_host`.
//!
//! `mod.zig` is also imported by the native driver for shared opaque types and
//! ownership operations. Keeping export rooting here makes archive ownership
//! structural: importing the Host implementation cannot make another archive
//! emit the `glowcap_host_*` family.

pub const std_options = @import("c_abi_shared").library_options;

const api = @import("mod.zig");

comptime {
    for (api.symbols.symbols) |symbol| @export(&@field(api, symbol.name), .{ .name = symbol.name });
}
