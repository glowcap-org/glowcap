//! CapTP lab visual system. Quiet terminal chrome: amber ink for focus,
//! muted idle borders, reverse fill reserved for selection / press / flash.
const vaxis = @import("vaxis");

pub const Color = vaxis.Color;
pub const Style = vaxis.Style;

// ── Palette ──────────────────────────────────────────────────────────
pub const accent = Color{ .index = 214 }; // amber — focus / brand
pub const accent_dim = Color{ .index = 172 };
pub const muted = Color{ .index = 243 };
pub const chrome_fg = Color{ .index = 249 };
pub const body_fg = Color{ .index = 255 };
pub const result_fg = Color{ .index = 116 };
pub const gloss_fg = Color{ .index = 111 };
pub const danger_fg = Color{ .index = 203 };
pub const tip_fg = Color{ .index = 221 };
pub const open_fg = Color{ .index = 114 };
pub const link_fg = Color{ .index = 75 };
pub const user_fg = Color{ .index = 229 };
pub const surface = Color{ .index = 234 };
pub const surface_hi = Color{ .index = 236 };
/// Selection wash — bright enough to read as “selected” on dark surfaces.
pub const select_bg = Color{ .index = 61 };
pub const status_bg = Color{ .index = 235 };

pub fn styleChrome() Style {
    return .{ .fg = chrome_fg };
}
pub fn styleMuted() Style {
    return .{ .fg = muted };
}
pub fn styleAccent() Style {
    return .{ .fg = accent, .bold = true };
}
pub fn styleBody() Style {
    return .{ .fg = body_fg };
}
pub fn styleUser() Style {
    return .{ .fg = user_fg, .bold = true };
}
pub fn styleResult() Style {
    return .{ .fg = result_fg };
}
pub fn styleGloss() Style {
    return .{ .fg = gloss_fg, .dim = true, .italic = true };
}
pub fn styleDanger() Style {
    return .{ .fg = danger_fg, .bold = true };
}
pub fn styleTip() Style {
    return .{ .fg = tip_fg };
}
pub fn styleOpen() Style {
    return .{ .fg = open_fg, .bold = true };
}
pub fn styleMono() Style {
    return .{ .fg = chrome_fg };
}
/// Transient CapTP-table flash (event-tied). Only reverse-amber chrome fill.
pub fn styleFlash() Style {
    return .{ .fg = Color{ .index = 0 }, .bg = accent, .bold = true };
}
/// Focus title / chip: amber ink, no fill.
pub fn styleFocus() Style {
    return .{ .fg = accent, .bold = true };
}
pub fn styleLink() Style {
    return .{ .fg = link_fg, .ul_style = .single };
}
pub fn styleExpandable() Style {
    return .{ .fg = muted, .italic = true };
}
pub fn styleSelected() Style {
    return .{ .fg = body_fg, .bg = select_bg };
}
pub fn styleButton() Style {
    return .{ .fg = Color{ .index = 0 }, .bg = accent, .bold = true };
}
pub fn styleButtonHover() Style {
    return .{ .fg = Color{ .index = 0 }, .bg = tip_fg, .bold = true };
}
pub fn styleButtonDown() Style {
    return .{ .fg = Color{ .index = 15 }, .bg = accent_dim, .bold = true };
}
pub fn styleStatusBar() Style {
    return .{ .fg = chrome_fg, .bg = status_bg };
}
pub fn styleStatusOpen() Style {
    return .{ .fg = open_fg, .bg = status_bg, .bold = true };
}
pub fn styleScrollbar() Style {
    return .{ .fg = accent_dim };
}
pub fn styleScrollbarTrack() Style {
    return .{ .fg = Color{ .index = 238 } };
}
pub fn styleStageDone() Style {
    return .{ .fg = open_fg };
}
pub fn styleStageCurrent() Style {
    return styleAccent();
}
pub fn styleStageTodo() Style {
    return .{ .fg = muted };
}
/// Menu / completion selected row (list cursor wash).
pub fn styleListCursor() Style {
    return .{ .fg = Color{ .index = 0 }, .bg = accent, .bold = true };
}

const light: [6][]const u8 = .{ "┌", "─", "┐", "│", "┘", "└" };

pub fn borderIdle() vaxis.Window.BorderOptions {
    return .{ .where = .all, .style = .{ .fg = muted }, .glyphs = .{ .custom = light } };
}

pub fn borderFocus() vaxis.Window.BorderOptions {
    return .{ .where = .all, .style = .{ .fg = accent, .bold = true }, .glyphs = .{ .custom = light } };
}
