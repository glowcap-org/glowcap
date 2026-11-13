//! Singleton resources for the CapTP lab world.
const std = @import("std");
const select_mod = @import("../select.zig");

pub const Mode = enum {
    prompt,
    complete,
    transcript,
    quiet,
    help,
};

/// In-app transcript selection (plain drag). Shift+drag bypasses to the terminal.
pub const Selection = select_mod.Selection;

pub const PanelFocus = enum { prompt, transcript, rail_exports, rail_imports, rail_answers };

pub const Resources = struct {
    mode: Mode = .prompt,
    selection: Selection = .{},
    panel: PanelFocus = .prompt,
    /// When true, mouse reporting is off (`GLOWCAP_REPL_NO_MOUSE=1`).
    no_mouse: bool = false,
    /// Jump-to-live button is held (mouse-down visual).
    jump_pressed: bool = false,
    /// Last mouse cell (jump-chip hover / cursor shape).
    mouse_col: i16 = 0,
    mouse_row: i16 = 0,
};
