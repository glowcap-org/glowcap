//! Singleton resources for the CapTP lab world.
const std = @import("std");
const layout = @import("../layout.zig");
const select_mod = @import("../select.zig");

pub const Mode = enum {
    prompt,
    complete,
    transcript,
    quiet,
    help,
};

pub const AutoFollow = struct {
    paused: bool = false,
    new_while_paused: usize = 0,
};

/// In-app transcript selection (plain drag). Shift+drag bypasses to the terminal.
pub const Selection = select_mod.Selection;

pub const PanelFocus = enum { prompt, transcript, rail_exports, rail_imports, rail_answers };

pub const Resources = struct {
    mode: Mode = .prompt,
    auto_follow: AutoFollow = .{},
    selection: Selection = .{},
    geom: layout.Geom = undefined,
    panel: PanelFocus = .prompt,
    reduced_motion: bool = false,
    /// When true, mouse reporting is off (`GLOWCAP_REPL_NO_MOUSE=1`).
    no_mouse: bool = false,
    /// Jump-to-live button is held (mouse-down visual).
    jump_pressed: bool = false,
    /// Last mouse cell (jump-chip hover / cursor shape).
    mouse_col: i16 = 0,
    mouse_row: i16 = 0,
};
