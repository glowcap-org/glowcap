//! CapTP lab geometry (pure). Interactive/graphic design — no I/O.
//!
//! The REPL is one vertical column (transcript → completion → prompt). The
//! CapTP rail matches that column's full height so the prompt never spans
//! sideways under the instrument.
const std = @import("std");

pub const Mode = enum {
    /// Wide: REPL column + CapTP right rail (same height).
    split,
    /// Narrow: CapTP count strip above full-width REPL column.
    stacked,
    /// Tiny: status+prompt only; transcript squeezed; rail/strip omitted.
    compact,
};

pub const Geom = struct {
    mode: Mode,
    status_h: u16,
    stage_h: u16,
    strip_h: u16, // CapTP counts in stacked mode; 0 otherwise
    /// Height of the REPL column stack (= rail height in split mode).
    main_h: u16,
    transcript_h: u16,
    menu_h: u16,
    prompt_h: u16,
    repl_w: u16,
    rail_w: u16,
    cols: u16,
    rows: u16,
};

pub const split_min_cols: u16 = 80;
pub const rail_min_w: u16 = 26;
pub const rail_max_w: u16 = 36;
/// Prompt dock: border + input + footer tip = 4 when roomy.
pub const prompt_comfort_h: u16 = 4;
pub const prompt_min_h: u16 = 3;

/// Compute a robust layout for any winsize. Never panics; clamps to fit.
/// `guide` reserves the stage strip for the optional CapTP walkthrough.
pub fn compute(cols: u16, rows: u16, menu_open: bool, menu_n: usize, guide: bool) Geom {
    const c = @max(cols, @as(u16, 1));
    const r = @max(rows, @as(u16, 1));

    var status_h: u16 = 1;
    var stage_h: u16 = if (guide and r >= 8) 1 else 0;
    var prompt_h: u16 = if (r >= 10) prompt_comfort_h else prompt_min_h;
    if (r < 6) {
        status_h = 1;
        stage_h = 0;
        prompt_h = 1;
    }

    var menu_h: u16 = if (!menu_open or menu_n == 0)
        0
    else blk: {
        const items_shown: u16 = if (menu_n >= 6) 6 else @intCast(menu_n);
        const want: u16 = items_shown + 3;
        break :blk @max(@as(u16, 3), @min(@as(u16, 9), want));
    };

    var mode: Mode = if (r < 8 or c < 40)
        .compact
    else if (c < split_min_cols)
        .stacked
    else
        .split;

    var strip_h: u16 = switch (mode) {
        .stacked => if (r >= 12) 3 else 1,
        else => 0,
    };

    // Chrome above the REPL column (status/stage/strip only).
    var top = status_h + stage_h + strip_h;
    if (top + prompt_h >= r) {
        // Emergency: status + bare prompt + whatever remains for transcript.
        status_h = 1;
        stage_h = 0;
        strip_h = 0;
        menu_h = 0;
        prompt_h = 1;
        mode = .compact;
        top = 1;
        const main_h: u16 = if (r > top + prompt_h) r - top else 1;
        const transcript_h: u16 = if (main_h > prompt_h) main_h - prompt_h else 1;
        return .{
            .mode = .compact,
            .status_h = status_h,
            .stage_h = 0,
            .strip_h = 0,
            .main_h = @max(main_h, prompt_h + 1),
            .transcript_h = transcript_h,
            .menu_h = 0,
            .prompt_h = prompt_h,
            .repl_w = c,
            .rail_w = 0,
            .cols = c,
            .rows = r,
        };
    }

    var main_h = r - top;
    // menu + prompt live inside main_h (REPL column), not below a shared body.
    if (menu_h + prompt_h >= main_h) {
        menu_h = 0;
    }
    if (prompt_h >= main_h) {
        prompt_h = 1;
    }
    var transcript_h = main_h -| (menu_h + prompt_h);
    if (transcript_h == 0) {
        transcript_h = 1;
        if (menu_h > 0) {
            menu_h = 0;
            transcript_h = main_h -| prompt_h;
        }
        if (transcript_h == 0) {
            prompt_h = 1;
            transcript_h = main_h -| 1;
        }
        main_h = transcript_h + menu_h + prompt_h;
    }

    const rail_w: u16 = switch (mode) {
        .split => blk: {
            const pct = (c * 32) / 100;
            break :blk @max(rail_min_w, @min(rail_max_w, pct));
        },
        else => 0,
    };
    const repl_w: u16 = if (mode == .split and c > rail_w) c - rail_w else c;

    return .{
        .mode = mode,
        .status_h = status_h,
        .stage_h = stage_h,
        .strip_h = strip_h,
        .main_h = main_h,
        .transcript_h = transcript_h,
        .menu_h = menu_h,
        .prompt_h = prompt_h,
        .repl_w = repl_w,
        .rail_w = rail_w,
        .cols = c,
        .rows = r,
    };
}

/// How many lines up from the bottom the viewport is scrolled. 0 = pinned to end.
pub fn clampScroll(scroll_off: usize, line_count: usize, view_h: usize) usize {
    if (view_h == 0 or line_count <= view_h) return 0;
    const max_off = line_count - view_h;
    return @min(scroll_off, max_off);
}

/// First line index to draw for a bottom-aligned viewport with scroll_off.
pub fn transcriptStart(scroll_off: usize, line_count: usize, view_h: usize) usize {
    if (view_h == 0 or line_count == 0) return 0;
    const off = clampScroll(scroll_off, line_count, view_h);
    if (line_count <= view_h) return 0;
    return line_count - view_h - off;
}

pub fn scrollBy(scroll_off: usize, line_count: usize, view_h: usize, delta: i32) usize {
    const cur = clampScroll(scroll_off, line_count, view_h);
    if (delta >= 0) {
        const add: usize = @intCast(delta);
        return clampScroll(cur + add, line_count, view_h);
    }
    const sub: usize = @intCast(-delta);
    return if (sub >= cur) 0 else cur - sub;
}

/// Screen rect in the same coordinate space as vaxis mouse `col`/`row`.
pub const ScreenRect = struct {
    x: u16 = 0,
    y: u16 = 0,
    w: u16 = 0,
    h: u16 = 0,

    pub fn contains(self: ScreenRect, col: i16, row: i16) bool {
        if (col < 0 or row < 0) return false;
        const c: u16 = @intCast(col);
        const r: u16 = @intCast(row);
        return c >= self.x and r >= self.y and c < self.x +| self.w and r < self.y +| self.h;
    }
};

/// Inside a vaxis child created with `.border = .all` (1 cell each side).
pub fn insideAllBorder(frame_x: u16, frame_y: u16, frame_w: u16, frame_h: u16) ScreenRect {
    return .{
        .x = frame_x +| 1,
        .y = frame_y +| 1,
        .w = frame_w -| 2,
        .h = frame_h -| 2,
    };
}

/// Line viewport under a 1-row title inside an all-bordered frame.
/// Matches: `win.child(.{border=.all})` then title on row 0, content at y_off=1.
pub fn contentBelowTitle(frame_x: u16, frame_y: u16, frame_w: u16, frame_h: u16) ScreenRect {
    const inner = insideAllBorder(frame_x, frame_y, frame_w, frame_h);
    if (inner.h <= 1) return inner;
    return .{
        .x = inner.x,
        .y = inner.y +| 1,
        .w = inner.w,
        .h = inner.h -| 1,
    };
}

/// Drawable transcript rows inside a bordered pane with a 1-row title.
/// `transcript_h` is the outer frame height passed to `win.child` (includes border).
pub fn transcriptInnerH(transcript_h: u16) u16 {
    return contentBelowTitle(0, 0, 80, transcript_h).h;
}
