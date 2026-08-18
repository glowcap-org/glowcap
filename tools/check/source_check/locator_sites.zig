//! The Zig call sites held to the core locator grammar. Callers with parsed
//! addresses use `locatorFromAddress`; callers with text already in hand use
//! `locator`. Neither hand-formats host:port, and each row bans the exact
//! shortcut its file once took. Consumed by `captp_io_spine.zig`.

// Zig callers with parsed addresses use locatorFromAddress; callers with
// text already in hand use locator. Neither hand-formats host:port.
pub const zig_demo_locator = [_]struct { path: []const u8, required: []const u8, banned: []const []const u8 }{
    .{
        .path = "apps/tasks/zig/client.zig",
        .required = "tcp.locatorFromAddress(",
        .banned = &.{ "bufPrint(&designator_buf, \"{s}:{d}\"", "127.0.0.1:{d}" },
    },
    .{
        .path = "apps/tools/zig/agent.zig",
        .required = "tcp.locatorFromAddress(",
        .banned = &.{ "bufPrint(&designator_buf, \"{s}:{d}\"", "127.0.0.1:{d}" },
    },
    .{
        .path = "examples/zig/02_introduce_and_redeem.zig",
        .required = "tcp.locatorFromAddress(",
        .banned = &.{ "lastIndexOfScalar(u8, bound, ':')", "127.0.0.1:{d}" },
    },
    .{
        .path = "test/driver/bridge_test.zig",
        .required = "tcp.locatorFromAddress(",
        .banned = &.{"127.0.0.1:{d}"},
    },
    .{
        .path = "test/driver/bridge_lifecycle_test.zig",
        .required = "tcp.locatorFromAddress(",
        .banned = &.{"127.0.0.1:{d}"},
    },
    .{
        .path = "test/driver/blocking_session/loopback_test.zig",
        .required = "tcp.locatorFromAddress(",
        .banned = &.{ "bufPrint(&designator_buf, \"{f}\"", "127.0.0.1:{d}" },
    },
    .{
        .path = "test/driver/pluggability_test.zig",
        .required = "tcp.locatorFromAddress(",
        .banned = &.{ "bufPrint(&designator_buf, \"{f}\"", "127.0.0.1:{d}" },
    },
    .{
        .path = "interop/tcp_loop/driver.zig",
        .required = "net.tcp.locatorFromAddress(",
        .banned = &.{"127.0.0.1:{d}"},
    },
    .{
        .path = "interop/goblins_interop/handoff_driver.zig",
        .required = "tcp.locatorFromAddress(",
        .banned = &.{"127.0.0.1:{d}"},
    },
    .{
        .path = "interop/goblins_interop/driver.zig",
        .required = "tcp.locatorFromAddress(",
        .banned = &.{ "host ++ \":1\"", "127.0.0.1:{d}" },
    },
    .{
        .path = "interop/goblins_interop/converse.zig",
        .required = "tcp.locatorFromAddress(",
        .banned = &.{ "host ++ \":1\"", "127.0.0.1:{d}" },
    },
    .{
        .path = "bench/peer_scaling_bench.zig",
        .required = "net.tcp.locatorFromAddress(",
        .banned = &.{"127.0.0.1:{d}"},
    },
    .{
        .path = "conformance/ocapn-conformance/handoff.zig",
        .required = "tcp.locatorFromAddress(",
        .banned = &.{ "bufPrint(&designator_buf, \"{s}:{d}\"", "allocPrint(allocator, \"{s}:{s}\"", "indexOfScalar(u8, exporter_location, ':')" },
    },
};
