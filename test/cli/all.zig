//! Root for `zig build cli-test`: registry meta and session/capture goldens.
comptime {
    _ = @import("rooms_session_command_cases.zig");
    _ = @import("rooms_product_cases.zig");
    _ = @import("registry_cases.zig");
    _ = @import("session_cases.zig");
    _ = @import("captp_cases.zig");
    _ = @import("cmd_cases.zig");
    _ = @import("ergonomics_cases.zig");
    _ = @import("repl_cases.zig");
    _ = @import("griddle_cases.zig");
}
