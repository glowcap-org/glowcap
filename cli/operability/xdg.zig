//! XDG Base Directory paths for the glowcap CLI (ergonomics pass).
const std = @import("std");

/// Which default state root to use when `GLOWCAP_STATE` is unset.
pub const StatePosture = enum {
    /// Argv / REPL: XDG state (`~/.local/state/glowcap` …).
    product,
    /// MCP front: cwd-relative clone-local dir so the agent peer does not share
    /// identity with a human argv/REPL session in the same checkout.
    mcp_local,
};

/// Product / MCP state directory: lock file and default identity live here.
///
/// Order: `GLOWCAP_STATE`, else posture default (see `StatePosture`), else
/// `$XDG_STATE_HOME/glowcap` / `~/.local/state/glowcap` / `/tmp/glowcap`.
pub fn defaultStateDir(buf: []u8, environ: *const std.process.Environ.Map, posture: StatePosture) ![]const u8 {
    // XDG: empty env var ≡ unset; fall through.
    if (environ.get("GLOWCAP_STATE")) |state| {
        if (state.len > 0) {
            if (state.len >= buf.len) return error.PathTooLong;
            @memcpy(buf[0..state.len], state);
            return buf[0..state.len];
        }
    }
    if (posture == .mcp_local) {
        return try std.fmt.bufPrint(buf, ".local/glowcap-mcp-state", .{});
    }
    if (environ.get("XDG_STATE_HOME")) |xdg| {
        if (xdg.len > 0) {
            return try std.fmt.bufPrint(buf, "{s}/glowcap", .{xdg});
        }
    }
    if (environ.get("HOME")) |home| {
        if (home.len > 0) {
            return try std.fmt.bufPrint(buf, "{s}/.local/state/glowcap", .{home});
        }
    }
    return try std.fmt.bufPrint(buf, "/tmp/glowcap", .{});
}

/// Default CapTP identity seed path.
///
/// 1. `GLOWCAP_IDENTITY`
/// 2. `$STATE_DIR/identity`
pub fn defaultIdentityPath(buf: []u8, environ: *const std.process.Environ.Map, posture: StatePosture) ![]const u8 {
    if (environ.get("GLOWCAP_IDENTITY")) |p| {
        if (p.len > 0) {
            if (p.len >= buf.len) return error.PathTooLong;
            @memcpy(buf[0..p.len], p);
            return buf[0..p.len];
        }
    }

    var state_buf: [std.fs.max_path_bytes]u8 = undefined;
    const state = try defaultStateDir(&state_buf, environ, posture);
    return try std.fmt.bufPrint(buf, "{s}/identity", .{state});
}
