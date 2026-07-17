//! XDG Base Directory paths for the pancake CLI (ergonomics pass).
const std = @import("std");

const Io = std.Io;

/// Which default state root to use when `PANCAKE_STATE` is unset.
pub const StatePosture = enum {
    /// Argv / REPL: XDG state (`~/.local/state/pancake` …).
    product,
    /// MCP front: cwd-relative clone-local dir so the agent peer does not share
    /// identity with a human argv/REPL session in the same checkout.
    mcp_local,
};

/// Product / MCP state directory: lock file and default identity live here.
///
/// Order: `PANCAKE_STATE`, else posture default (see `StatePosture`), else
/// `$XDG_STATE_HOME/pancake` / `~/.local/state/pancake` / `/tmp/pancake`.
pub fn defaultStateDir(buf: []u8, environ: *const std.process.Environ.Map, posture: StatePosture) ![]const u8 {
    // XDG: empty env var ≡ unset; fall through.
    if (environ.get("PANCAKE_STATE")) |state| {
        if (state.len > 0) {
            if (state.len >= buf.len) return error.PathTooLong;
            @memcpy(buf[0..state.len], state);
            return buf[0..state.len];
        }
    }
    if (posture == .mcp_local) {
        return try std.fmt.bufPrint(buf, ".local/pancake-mcp-state", .{});
    }
    if (environ.get("XDG_STATE_HOME")) |xdg| {
        if (xdg.len > 0) {
            return try std.fmt.bufPrint(buf, "{s}/pancake", .{xdg});
        }
    }
    if (environ.get("HOME")) |home| {
        if (home.len > 0) {
            return try std.fmt.bufPrint(buf, "{s}/.local/state/pancake", .{home});
        }
    }
    return try std.fmt.bufPrint(buf, "/tmp/pancake", .{});
}

fn pathExists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Default CapTP identity seed path.
///
/// 1. `PANCAKE_IDENTITY`
/// 2. `$STATE_DIR/identity` when present, or when no legacy file exists
/// 3. Legacy `$HOME/.config/pancake/identity` for load when (2) is absent and
///    the legacy file exists (new mints still target (2) via `mintIdentityPath`).
pub fn defaultIdentityPath(io: Io, buf: []u8, environ: *const std.process.Environ.Map, posture: StatePosture) ![]const u8 {
    if (environ.get("PANCAKE_IDENTITY")) |p| {
        if (p.len > 0) {
            if (p.len >= buf.len) return error.PathTooLong;
            @memcpy(buf[0..p.len], p);
            return buf[0..p.len];
        }
    }

    var state_buf: [std.fs.max_path_bytes]u8 = undefined;
    const state = try defaultStateDir(&state_buf, environ, posture);
    const preferred = try std.fmt.bufPrint(buf, "{s}/identity", .{state});

    if (pathExists(io, preferred)) return preferred;

    if (environ.get("HOME")) |home| {
        if (home.len > 0) {
            var legacy_buf: [std.fs.max_path_bytes]u8 = undefined;
            const legacy = try std.fmt.bufPrint(&legacy_buf, "{s}/.config/pancake/identity", .{home});
            if (pathExists(io, legacy)) {
                if (legacy.len >= buf.len) return error.PathTooLong;
                @memcpy(buf[0..legacy.len], legacy);
                return buf[0..legacy.len];
            }
        }
    }

    return preferred;
}

/// Preferred mint path (always under state dir / `PANCAKE_IDENTITY`), ignoring
/// legacy config. Used when `init` must not write into `~/.config`.
pub fn mintIdentityPath(buf: []u8, environ: *const std.process.Environ.Map, posture: StatePosture) ![]const u8 {
    if (environ.get("PANCAKE_IDENTITY")) |p| {
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
