//! Crossing annotations for `libglowcap_net_transport_relay`.

const shared = @import("c_abi_shared");

pub const Symbol = shared.symbols.Symbol;

pub const symbols = [_]Symbol{
    .{ .name = "glowcap_relay_archive_fingerprint" },
    .{ .name = "glowcap_relay_last_error", .out_params = &.{0} },
    .{ .name = "glowcap_relay_clear_last_error" },
    .{ .name = "glowcap_relay_runtime_new", .out_params = &.{1} },
    .{ .name = "glowcap_relay_transport_provider", .out_params = &.{1} },
    .{
        .name = "glowcap_relay_runtime_release",
        .out_params = &.{ 1, 3 },
        .blocking = true,
        .nonblocking = true,
    },
    .{
        .name = "glowcap_relay_runtime_new_in",
        .out_params = &.{2},
    },
};
