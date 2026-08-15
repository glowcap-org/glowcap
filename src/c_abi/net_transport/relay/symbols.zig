//! Crossing annotations for `libpancake_net_transport_relay`.

const shared = @import("c_abi_shared");

pub const Symbol = shared.symbols.Symbol;
pub const omitted_families = [_]shared.symbols.OmittedFamily{};

pub const symbols = [_]Symbol{
    .{ .name = "pancake_relay_last_error", .out_params = &.{0} },
    .{ .name = "pancake_relay_clear_last_error" },
    .{ .name = "pancake_relay_runtime_new", .out_params = &.{1} },
    .{ .name = "pancake_relay_transport_provider", .out_params = &.{1} },
    .{
        .name = "pancake_relay_runtime_release",
        .blocking = true,
        .nonblocking = true,
        .ts_omit = shared.symbols.diagnosed.ts_uses_companion,
    },
    .{
        .name = "pancake_relay_runtime_release_with_diagnostic",
        .out_params = &.{ 1, 3 },
        .blocking = true,
        .nonblocking = true,
        .rust_omit = shared.symbols.diagnosed.rust_uses_tls,
        .python_omit = shared.symbols.diagnosed.python_uses_tls,
        .racket_omit = shared.symbols.diagnosed.racket_uses_tls,
    },
    .{
        .name = "pancake_relay_runtime_new_in",
        .out_params = &.{2},
        .ts_omit = "unused: the TypeScript binding keeps transport runtimes on the library allocator",
        .python_omit = "unused: the Python binding keeps transport runtimes on the library allocator",
        .racket_omit = "unused: the Racket binding keeps transport runtimes on the library allocator",
    },
};
