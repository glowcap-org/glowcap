//! Root for `zig build cli-test`: registry meta and session/capture goldens.
comptime {
    _ = @import("registry_cases.zig");
    _ = @import("session_cases.zig");
    _ = @import("captp_cases.zig");
    _ = @import("cmd_cases.zig");
    _ = @import("ergonomics_cases.zig");
    _ = @import("rooms_peer_cases.zig");
    _ = @import("rooms_peer_phase_cases.zig");
    _ = @import("repl_cases.zig");
    _ = @import("griddle_cases.zig");
}
