//! Artifact entry root. Importing the implementation does not root exports.
pub const std_options = @import("c_abi_shared").library_options;
const api = @import("mod.zig");
comptime {
    for (api.symbols.symbols) |symbol| @export(&@field(api, symbol.name), .{ .name = symbol.name });
}
