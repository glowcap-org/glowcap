//! Pointer input for the CapTP lab TUI.
//!
//! `tui.zig` owns the frame loop and key intents. This module owns how a
//! mouse event becomes hover, drag-select, click-to-toggle, link
//! activation, or a completion pick. It also owns the OSC-52 copy the drag
//! commits, which the keyboard copy intent reuses.
const std = @import("std");
const vaxis = @import("vaxis");
const Ctx = @import("../ctx.zig").Ctx;
const complete = @import("complete.zig");
const layout = @import("layout.zig");
const panes = @import("panes.zig");
const blocks = @import("blocks.zig");
const links = @import("links.zig");
const select_mod = @import("select.zig");
const width_mod = @import("width.zig");
const prompt_edit = @import("prompt_edit.zig");
const ecs = @import("ecs/mod.zig");

const drag_threshold_cells: u16 = 1;

pub fn handleMouse(
    vx: *vaxis.Vaxis,
    lab: *ecs.LabWorld,
    store: *blocks.Store,
    text_input: *vaxis.widgets.TextInput,
    line_scratch: []u8,
    m: vaxis.Mouse,
    view_h: usize,
    transcript_inner: layout.ScreenRect,
    jump_btn: ?panes.JumpButton,
    menu_open: *bool,
    menu_items: []const complete.Candidate,
    menu_sel: *usize,
    selection_text: *std.ArrayList(u8),
    ctx: *Ctx,
) !void {
    // Shift+drag: leave the event to the terminal's native selection.
    if (m.mods.shift) {
        vx.setMouseShape(.default);
        return;
    }

    if (m.button == .wheel_up and (m.type == .press or m.type == .drag)) {
        store.scroll(view_h, 1);
        updateHoverAndCursor(vx, lab, store, view_h, transcript_inner, jump_btn, menu_open.*, menu_items.len, m.col, m.row);
        return;
    }
    if (m.button == .wheel_down and (m.type == .press or m.type == .drag)) {
        store.scroll(view_h, -1);
        updateHoverAndCursor(vx, lab, store, view_h, transcript_inner, jump_btn, menu_open.*, menu_items.len, m.col, m.row);
        return;
    }

    if (m.type == .motion or m.type == .drag or m.type == .press or m.type == .release) {
        updateHoverAndCursor(vx, lab, store, view_h, transcript_inner, jump_btn, menu_open.*, menu_items.len, m.col, m.row);
    }

    // Extend selection while pressed/dragging (not after linger).
    if ((m.type == .drag or m.type == .motion) and m.button == .left) {
        if (lab.res.jump_pressed) return;
        switch (lab.res.selection.phase) {
            .pressed, .dragging => {
                const col: u16 = @intCast(@max(m.col, 0));
                const row: u16 = @intCast(@max(m.row, 0));
                lab.res.selection.anchors.b = .{ .col = col, .row = row };
                if (lab.res.selection.phase == .pressed and
                    lab.res.selection.cellDist(col, row) >= drag_threshold_cells)
                {
                    lab.res.selection.phase = .dragging;
                }
                if (lab.res.selection.phase == .dragging) {
                    autoScrollWhileSelecting(store, view_h, transcript_inner, row);
                }
            },
            .idle, .lingering => {},
        }
        return;
    }

    if (m.type == .release and m.button == .left) {
        if (lab.res.jump_pressed) {
            lab.res.jump_pressed = false;
            if (jump_btn) |jb| {
                if (jb.contains(m.col, m.row)) store.pinLive();
            }
            return;
        }
        const phase = lab.res.selection.phase;
        if (phase == .dragging) {
            try fillAndCopySelection(ctx, selection_text, store, lab, view_h, transcript_inner, width_mod.ofScreen(&vx.screen));
            lab.res.selection.phase = .lingering;
            return;
        }
        const was_pressed = phase == .pressed;
        lab.res.selection.clear();
        if (!was_pressed) return;

        if (transcript_inner.contains(m.col, m.row)) {
            if (jump_btn) |jb| {
                if (jb.contains(m.col, m.row)) {
                    store.pinLive();
                    return;
                }
            }
            const local_row: usize = @intCast(@as(i32, m.row) - @as(i32, transcript_inner.y));
            if (m.mods.ctrl) {
                const local_col: usize = @intCast(@as(i32, m.col) - @as(i32, transcript_inner.x));
                if (flatLineAt(store, view_h, local_row)) |line| {
                    // Cell to byte offset, as in hover: the click has to open
                    // the link the pointer was over.
                    if (select_mod.byteAtCell(line, local_col, width_mod.ofScreen(&vx.screen))) |offset| {
                        var spans: [4]links.Span = undefined;
                        if (links.atByte(line, offset, &spans)) |sp| {
                            try activateLink(ctx, text_input, sp.slice(line), sp.kind);
                        }
                    }
                }
                return;
            }
            if (store.blockAtViewRow(view_h, local_row)) |bi| {
                store.toggle(bi);
                return;
            }
        }

        if (menu_open.* and menu_items.len > 0) {
            if (lab.menu_e) |me| {
                if (lab.rect.get(me)) |mr| {
                    if (mr.contains(m.col, m.row) and mr.h > 0) {
                        const local: usize = @intCast(@as(i32, m.row) - @as(i32, mr.y));
                        const start = complete.menuScrollStart(menu_sel.*, menu_items.len, mr.h);
                        const idx = start + local;
                        if (idx < menu_items.len) {
                            menu_sel.* = idx;
                            try prompt_edit.acceptCandidate(text_input, line_scratch, menu_items[idx].token);
                            menu_open.* = false;
                            lab.res.mode = .prompt;
                        }
                        return;
                    }
                }
            }
        }

        if (lab.prompt_e) |pe| {
            if (lab.rect.get(pe)) |r| {
                if (r.contains(m.col, m.row)) {
                    lab.res.panel = .prompt;
                    lab.res.mode = .prompt;
                }
            }
        }
        return;
    }

    if (m.type != .press or m.button != .left) return;

    lab.res.selection.clear();

    if (jump_btn) |jb| {
        if (jb.contains(m.col, m.row)) {
            lab.res.jump_pressed = true;
            return;
        }
    }

    lab.res.jump_pressed = false;
    const p = select_mod.Point{
        .col = @intCast(@max(m.col, 0)),
        .row = @intCast(@max(m.row, 0)),
    };
    lab.res.selection = .{
        .phase = .pressed,
        .anchors = .{ .a = p, .b = p },
    };
}

fn autoScrollWhileSelecting(
    store: *blocks.Store,
    view_h: usize,
    transcript_inner: layout.ScreenRect,
    screen_row: u16,
) void {
    if (transcript_inner.h < 2) return;
    const top = transcript_inner.y;
    const bot = transcript_inner.y +| (transcript_inner.h -| 1);
    if (screen_row <= top) {
        store.scroll(view_h, 1);
    } else if (screen_row >= bot) {
        store.scroll(view_h, -1);
    }
}

fn updateHoverAndCursor(
    vx: *vaxis.Vaxis,
    lab: *ecs.LabWorld,
    store: *const blocks.Store,
    view_h: usize,
    transcript_inner: layout.ScreenRect,
    jump_btn: ?panes.JumpButton,
    menu_open: bool,
    menu_n: usize,
    col: i16,
    row: i16,
) void {
    lab.res.mouse_col = col;
    lab.res.mouse_row = row;
    var shape: vaxis.Mouse.Shape = .default;

    if (jump_btn) |jb| {
        if (jb.contains(col, row)) {
            shape = .pointer;
            vx.setMouseShape(shape);
            return;
        }
    }

    if (menu_open and menu_n > 0) {
        if (lab.menu_e) |me| {
            if (lab.rect.get(me)) |mr| {
                if (mr.contains(col, row)) {
                    shape = .pointer;
                    vx.setMouseShape(shape);
                    return;
                }
            }
        }
    }

    if (lab.prompt_e) |pe| {
        if (lab.rect.get(pe)) |r| {
            if (r.contains(col, row)) {
                shape = .text;
                vx.setMouseShape(shape);
                return;
            }
        }
    }

    if (transcript_inner.contains(col, row)) {
        const local_row: usize = @intCast(@as(i32, row) - @as(i32, transcript_inner.y));
        if (store.blockAtViewRow(view_h, local_row)) |bi| {
            if (bi < store.items.items.len and store.items.items[bi].hasMore()) {
                shape = .pointer;
                vx.setMouseShape(shape);
                return;
            }
        }
        const local_col: usize = @intCast(@as(i32, col) - @as(i32, transcript_inner.x));
        if (flatLineAt(store, view_h, local_row)) |line| {
            // The pointer names a cell and a scanned link is a byte range, so
            // the column converts through the same walk the underline is
            // painted from. Compared raw, a wide glyph earlier in the line status-allow: event or source ordering
            // pointed hover at a different link than the reader sees.
            if (select_mod.byteAtCell(line, local_col, width_mod.ofScreen(&vx.screen))) |offset| {
                var spans: [4]links.Span = undefined;
                if (links.atByte(line, offset, &spans) != null) {
                    shape = .pointer;
                    vx.setMouseShape(shape);
                    return;
                }
            }
        }
        shape = .text; // selectable transcript
    }

    vx.setMouseShape(shape);
}

fn flatLineAt(store: *const blocks.Store, view_h: usize, row_in_view: usize) ?[]const u8 {
    const line_count = store.flatLineCount();
    const start = layout.transcriptStart(store.scroll_off, line_count, view_h);
    var flat: usize = 0;
    for (store.items.items) |b| {
        const text = if (b.expanded) b.body else b.summary;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            if (flat == start + row_in_view) return line;
            flat += 1;
        }
    }
    return null;
}

fn activateLink(ctx: *Ctx, text_input: *vaxis.widgets.TextInput, url: []const u8, kind: links.Kind) !void {
    switch (kind) {
        .ocapn => {
            text_input.clearRetainingCapacity();
            try text_input.insertSliceAtCursor("dial ");
            try text_input.insertSliceAtCursor(url);
        },
        .https => {
            // Prefer xdg-open; fall back to insert into the prompt.
            const argv_open = [_][]const u8{ "xdg-open", url };
            var child = std.process.spawn(ctx.io, .{
                .argv = &argv_open,
                .environ_map = ctx.environ,
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .ignore,
            }) catch {
                text_input.clearRetainingCapacity();
                try text_input.insertSliceAtCursor(url);
                return;
            };
            // best-effort: the opener already launched; a failed wait loses
            // only its exit status.
            _ = child.wait(ctx.io) catch {};
        },
    }
}

pub fn fillAndCopySelection(
    ctx: *Ctx,
    buf: *std.ArrayList(u8),
    store: *const blocks.Store,
    lab: *const ecs.LabWorld,
    view_h: usize,
    transcript_inner: layout.ScreenRect,
    cells: select_mod.CellWidth,
) !void {
    buf.clearRetainingCapacity();
    if (transcript_inner.h == 0) return;
    // One store walk (same shape as paint); forbid per-row flatLineAt re-scan.
    var view_lines: std.ArrayList([]const u8) = .empty;
    defer view_lines.deinit(ctx.gpa);
    try collectViewLines(store, view_h, &view_lines, ctx.gpa);
    try select_mod.appendSelected(
        lab.res.selection.anchors.a,
        lab.res.selection.anchors.b,
        transcript_inner.x,
        transcript_inner.y,
        view_lines.items,
        buf,
        ctx.gpa,
        cells,
    );
    if (buf.items.len == 0) return;
    try osc52Copy(ctx, buf.items);
}

fn collectViewLines(
    store: *const blocks.Store,
    view_h: usize,
    out: *std.ArrayList([]const u8),
    gpa: std.mem.Allocator,
) !void {
    out.clearRetainingCapacity();
    const line_count = store.flatLineCount();
    const start = layout.transcriptStart(store.scroll_off, line_count, view_h);
    var flat: usize = 0;
    var row: usize = 0;
    for (store.items.items) |b| {
        const text = if (b.expanded) b.body else b.summary;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            if (flat >= start and row < view_h) {
                try out.append(gpa, line);
                row += 1;
            }
            flat += 1;
            if (row >= view_h) return;
        }
    }
}

pub fn osc52Copy(ctx: *Ctx, text: []const u8) !void {
    const enc = std.base64.standard.Encoder;
    const n = enc.calcSize(text.len);
    const b64 = try ctx.gpa.alloc(u8, n);
    defer ctx.gpa.free(b64);
    _ = enc.encode(b64, text);
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(ctx.gpa);
    try msg.appendSlice(ctx.gpa, "\x1b]52;c;");
    try msg.appendSlice(ctx.gpa, b64);
    try msg.appendSlice(ctx.gpa, "\x07");
    // best-effort: OSC 52 copy is fire-and-forget toward the terminal.
    std.Io.File.stdout().writeStreamingAll(ctx.io, msg.items) catch {};
}
