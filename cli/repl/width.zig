//! The display-width authority the transcript's selection geometry measures
//! with.
//!
//! `select.zig` is pure arithmetic and cannot ask a terminal how wide it draws a
//! character, so paint and copy pass the answer in. The answer is vaxis's own
//! grapheme width, read from the live screen, which is the measurement
//! `vaxis.Window.print` places cells by: selection columns and drawn cells are
//! then the same thing.
const vaxis = @import("vaxis");
const select = @import("select.zig");

fn measure(ctx: ?*const anyopaque, character: []const u8) u16 {
    const screen: *const vaxis.Screen = @ptrCast(@alignCast(ctx.?));
    return vaxis.gwidth.gwidth(character, screen.width_method);
}

/// Measure the way `screen` draws, so a highlight covers the glyphs the reader
/// sees. The terminal's reported capabilities move `screen.width_method`, so
/// this reads it per character rather than capturing it. The result borrows
/// `screen` and is valid while it lives.
pub fn ofScreen(screen: *const vaxis.Screen) select.CellWidth {
    return .{ .ctx = screen, .measure = measure };
}
