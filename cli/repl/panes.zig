//! CapTP lab layout: status, stage, REPL transcript, CapTP rail, prompt dock.
//!
//! libvaxis cells store grapheme *slices* until `vx.render`. Any dynamic string
//! passed to `printLine` must therefore outlive the frame — use `frame`
//! (arena) for formatted lines; literals and transcript-owned lines are fine.
const std = @import("std");
const vaxis = @import("vaxis");
const pancake = @import("pancake");
const copy = @import("copy.zig");
const theme = @import("theme.zig");
const teach = @import("teach.zig");
const complete = @import("complete.zig");
const layout = @import("layout.zig");
const Ctx = @import("../ctx.zig").Ctx;

const Window = vaxis.Window;
const session_mod = pancake.ocapn.session;
const Slot = session_mod.slot.Slot;

pub fn slotKindLabel(s: Slot) []const u8 {
    return switch (s) {
        .local_value => "near",
        .local_unresolved => "promise",
        .remote_value => "far",
        .remote_unresolved => "answer",
        .broken => "broken",
    };
}

pub const Flash = @import("flash.zig").Flash;

/// Print one row, no wrap. `text` must remain valid until after `vx.render`.
/// Truncation is by cell width (not bytes) so UTF-8 lines cannot spill sideways.
pub fn printLine(win: Window, row: u16, col: u16, text: []const u8, style: vaxis.Style) void {
    if (row >= win.height or col >= win.width) return;
    const max_w = win.width - col;
    // vaxis wrap=.none already stops at width; pass the full slice (arena/static
    // lifetime). Avoid byte-slicing UTF-8, which produced sideways garbage.
    _ = max_w;
    _ = win.print(&.{.{ .text = text, .style = style }}, .{
        .row_offset = row,
        .col_offset = col,
        .wrap = .none,
    });
}

fn printFmt(
    win: Window,
    row: u16,
    col: u16,
    style: vaxis.Style,
    frame: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
) void {
    const line = std.fmt.allocPrint(frame, fmt, args) catch return;
    printLine(win, row, col, line, style);
}

/// Content under a 1-row title inside a window that is *already* border-inset
/// by vaxis (`child` with `.border = .all` returns the inner area).
/// Do not call this on a pre-border outer frame — that double-insets.
pub fn belowTitle(win: Window) Window {
    if (win.height < 2) return win;
    return win.child(.{
        .x_off = 0,
        .y_off = 1,
        .width = win.width,
        .height = win.height -| 1,
    });
}

fn fillRowBg(win: Window, row: u16, style: vaxis.Style) void {
    var col: u16 = 0;
    while (col < win.width) : (col += 1) {
        printLine(win, row, col, " ", style);
    }
}

fn drawBorderTitle(win: Window, title: []const u8, style: vaxis.Style) void {
    // Titles are ASCII product chrome (`REPL`, `CapTP`); never byte-slice UTF-8.
    if (win.width < 4 or win.height < 1) return;
    const max = win.width -| 4;
    const shown = if (title.len > max) title[0..max] else title;
    printLine(win, 0, 2, shown, style);
}

pub fn drawStatus(win: Window, ctx: *Ctx, frame: std.mem.Allocator, panel_label: []const u8) void {
    fillRowBg(win, 0, theme.styleStatusBar());
    const id: []const u8 = if (ctx.secret) |secret| blk: {
        const d = secret.publicKey().toDesignator();
        break :blk d[0..@min(12, d.len)];
    } else "-";
    const sess: []const u8 = if (ctx.session != null) "open" else "none";
    const style = if (ctx.session != null) theme.styleStatusOpen() else theme.styleStatusBar();
    if (ctx.last_locator) |loc| {
        const show = if (loc.len > 28) loc[0..28] else loc;
        printFmt(win, 0, 1, style, frame, "◆ pancake  id={s}  session={s}  {s}", .{ id, sess, show });
    } else {
        printFmt(win, 0, 1, style, frame, "◆ pancake  id={s}  session={s}", .{ id, sess });
    }
    if (panel_label.len > 0 and win.width > panel_label.len + 3) {
        const chip_x = win.width -| @as(u16, @intCast(panel_label.len + 2));
        printFmt(win, 0, chip_x, theme.styleAccent(), frame, " {s} ", .{panel_label});
    }
}

pub fn drawStage(win: Window, progress: *const teach.Progress, frame: std.mem.Allocator) void {
    const stages = [_]teach.Stage{ .identity, .connect, .session, .fetch, .deliver, .tables };
    const cur = progress.current();
    var col: u16 = 1;
    printLine(win, 0, col, "stage", theme.styleMuted());
    col += 6;
    for (stages) |st| {
        const done = progress.completed(st);
        const is_cur = st == cur;
        // Final stage stays "current" forever once reached — prefer ✓ when done.
        const mark: []const u8 = if (done) "✓" else if (is_cur) "●" else "·";
        const style = if (done)
            theme.styleStageDone()
        else if (is_cur)
            theme.styleStageCurrent()
        else
            theme.styleStageTodo();
        const piece = std.fmt.allocPrint(frame, "{s}{s} ", .{ mark, st.label() }) catch break;
        printLine(win, 0, col, piece, style);
        col +|= @intCast(@min(piece.len, 32));
        if (col >= win.width) break;
    }
}

/// Compact CapTP counts for stacked/narrow mode.
pub fn drawTablesStrip(win: Window, ctx: *Ctx, flash: Flash, frame: std.mem.Allocator) void {
    if (ctx.session == null) {
        printLine(win, 0, 0, "CapTP  session=none  (dial …)", theme.styleMuted());
        return;
    }
    const st = &ctx.session.?.peer().session_state;
    const style = if (flash != .none) theme.styleFlash() else theme.styleChrome();
    if (win.height <= 1) {
        printFmt(win, 0, 0, style, frame, "CapTP  ex={d}  im={d}  an={d}/{d}", .{
            session_mod.inspect.exportCount(st),
            session_mod.inspect.importCount(st),
            session_mod.inspect.inboundAnswerCount(st),
            session_mod.inspect.outboundAnswerCount(st),
        });
        return;
    }
    printFmt(win, 0, 0, if (flash == .exports) theme.styleFlash() else theme.styleChrome(), frame, "Exports {d}", .{session_mod.inspect.exportCount(st)});
    if (win.height > 1)
        printFmt(win, 1, 0, if (flash == .imports) theme.styleFlash() else theme.styleChrome(), frame, "Imports {d}", .{session_mod.inspect.importCount(st)});
    if (win.height > 2)
        printFmt(win, 2, 0, if (flash == .answers) theme.styleFlash() else theme.styleChrome(), frame, "Answers in {d} / out {d}", .{
            session_mod.inspect.inboundAnswerCount(st),
            session_mod.inspect.outboundAnswerCount(st),
        });
}

/// Right-rail CapTP instrument: three stacked panes.
pub fn drawTablesRail(
    win: Window,
    ctx: *Ctx,
    flash: Flash,
    focus_pane: ?teach.Pane,
    frame: std.mem.Allocator,
) void {
    const rail_focused = focus_pane != null;
    const title_style = if (rail_focused) theme.styleFocus() else theme.styleMuted();
    drawBorderTitle(win, if (rail_focused) "CapTP" else copy.captp_title, title_style);
    const inner = belowTitle(win);
    if (inner.height == 0) return;
    if (ctx.session == null) {
        printLine(inner, 0, 0, "No session.", theme.styleMuted());
        if (inner.height > 1) printLine(inner, 1, 0, "dial an ocapn:// locator", theme.styleMuted());
        return;
    }
    const st = &ctx.session.?.peer().session_state;
    const h = @max(1, inner.height / 3);
    const h2 = @max(1, (inner.height - h) / 2);
    const h3 = inner.height -| (h + h2);
    drawExportPane(inner.child(.{ .x_off = 0, .y_off = 0, .width = inner.width, .height = h }), st, flash == .exports, focus_pane == .exports, frame);
    drawImportPane(inner.child(.{ .x_off = 0, .y_off = h, .width = inner.width, .height = h2 }), st, flash == .imports, focus_pane == .imports, frame);
    drawAnswerPane(inner.child(.{ .x_off = 0, .y_off = h + h2, .width = inner.width, .height = @max(1, h3) }), st, flash == .answers, focus_pane == .answers, frame);
}

fn headerStyle(flash: bool, focused: bool) vaxis.Style {
    if (flash) return theme.styleFlash();
    if (focused) return theme.styleFocus();
    return theme.styleChrome();
}

fn printCapRow(win: Window, row: *u16, frame: std.mem.Allocator, position: u64, kind: []const u8, refcount: u64) void {
    if (row.* >= win.height) return;
    printFmt(win, row.*, 0, theme.styleMono(), frame, "{d} {s} rc{d}", .{ position, kind, refcount });
    row.* += 1;
}

/// One slot-table pane (exports or imports): header, empty line, or the rows.
/// `View` and `forEachFn` are the only things the two panes differ on; the
/// visitor body is shared because `ExportView`/`ImportView` carry the same
/// `position`/`slot`/`refcount` shape.
fn drawSlotPane(
    comptime View: type,
    comptime forEachFn: anytype,
    win: Window,
    st: *session_mod.Session,
    flash: bool,
    focused: bool,
    frame: std.mem.Allocator,
    label: []const u8,
    empty_msg: []const u8,
    count: usize,
) void {
    printFmt(win, 0, 0, headerStyle(flash, focused), frame, "{s} ({d})", .{ label, count });
    if (win.height < 2) return;
    if (count == 0) {
        printLine(win, 1, 0, empty_msg, theme.styleMuted());
        return;
    }
    var row: u16 = 1;
    const CtxRow = struct {
        win: Window,
        row: *u16,
        frame: std.mem.Allocator,
        fn visit(c: *@This(), v: View) void {
            printCapRow(c.win, c.row, c.frame, v.position.int(), slotKindLabel(v.slot), v.refcount);
        }
    };
    var c = CtxRow{ .win = win, .row = &row, .frame = frame };
    forEachFn(st, &c, CtxRow.visit);
}

fn drawExportPane(win: Window, st: *session_mod.Session, flash: bool, focused: bool, frame: std.mem.Allocator) void {
    drawSlotPane(session_mod.ExportView, session_mod.inspect.forEachExport, win, st, flash, focused, frame, "Exports", copy.empty_exports, session_mod.inspect.exportCount(st));
}

fn drawImportPane(win: Window, st: *session_mod.Session, flash: bool, focused: bool, frame: std.mem.Allocator) void {
    drawSlotPane(session_mod.ImportView, session_mod.inspect.forEachImport, win, st, flash, focused, frame, "Imports", copy.empty_imports, session_mod.inspect.importCount(st));
}

fn drawAnswerPane(win: Window, st: *session_mod.Session, flash: bool, focused: bool, frame: std.mem.Allocator) void {
    printFmt(win, 0, 0, headerStyle(flash, focused), frame, "Answers {d}/{d}", .{
        session_mod.inspect.inboundAnswerCount(st),
        session_mod.inspect.outboundAnswerCount(st),
    });
    if (win.height < 2) return;
    if (session_mod.inspect.inboundAnswerCount(st) + session_mod.inspect.outboundAnswerCount(st) == 0) {
        printLine(win, 1, 0, copy.empty_answers, theme.styleMuted());
        return;
    }
    var row: u16 = 1;
    const CtxRow = struct {
        win: Window,
        row: *u16,
        frame: std.mem.Allocator,
        tag: []const u8,
        fn visit(c: *@This(), v: session_mod.AnswerRowView) void {
            if (c.row.* >= c.win.height) return;
            const position, const local = switch (v.position) {
                .wire => |wire| .{ wire.int(), false },
                .virtual => |virtual| .{ virtual.int(), true },
            };
            const status = switch (v.view.status) {
                .pending => "pending",
                .fulfilled => "fulfilled",
                .broken => "broken",
            };
            printFmt(c.win, c.row.*, 0, theme.styleMono(), c.frame, "{s}{s}{d} {s}", .{
                c.tag,
                if (local) "v" else "",
                position,
                status,
            });
            c.row.* += 1;
        }
    };
    var cin = CtxRow{ .win = win, .row = &row, .frame = frame, .tag = "i" };
    session_mod.inspect.forEachInboundAnswer(st, &cin, CtxRow.visit);
    var cout = CtxRow{ .win = win, .row = &row, .frame = frame, .tag = "o" };
    session_mod.inspect.forEachOutboundAnswer(st, &cout, CtxRow.visit);
}

fn styleForBlockKind(kind: blocks_mod.Kind) vaxis.Style {
    return switch (kind) {
        .user => theme.styleUser(),
        .error_line => theme.styleDanger(),
        .tip => theme.styleTip(),
        .gloss => theme.styleGloss(),
        .coach, .system => theme.styleMuted(),
        .result => theme.styleResult(),
        .pending => theme.styleTip(),
    };
}

const blocks_mod = @import("blocks.zig");
const links_mod = @import("links.zig");
const select_mod = @import("select.zig");
const width_mod = @import("width.zig");

/// Draw expandable block store (CapTP lab ECS path).
/// `range` is screen-cell anchors when a drag/linger highlight is visible.
pub fn drawTranscriptBlocks(
    win: Window,
    store: *const blocks_mod.Store,
    mode_badge: []const u8,
    focused: bool,
    range: ?select_mod.Anchors,
    origin_x: u16,
    origin_y: u16,
) void {
    const title_style = if (mode_badge.len > 0)
        theme.styleAccent()
    else if (focused)
        theme.styleFocus()
    else
        theme.styleMuted();
    const title = if (mode_badge.len > 0) mode_badge else copy.repl_title;
    drawBorderTitle(win, title, title_style);
    // `win` is already inside the vaxis border; only skip the title row.
    const inner = belowTitle(win);
    if (inner.height == 0) return;
    const view_h: usize = inner.height;
    const line_count = store.flatLineCount();
    const start = layout.transcriptStart(store.scroll_off, line_count, view_h);
    const sel_style = theme.styleSelected();
    // Selection geometry is measured in the cells this screen draws.
    const cells = width_mod.ofScreen(win.screen);

    var flat: usize = 0;
    var row: u16 = 0;
    for (store.items.items) |b| {
        const text = if (b.expanded) b.body else b.summary;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            if (flat >= start and row < inner.height) {
                const screen_row = origin_y + row;
                const span = if (range) |r|
                    select_mod.contentSpan(r.a, r.b, screen_row, origin_x, line, cells)
                else
                    null;
                var style = styleForBlockKind(b.kind);
                if (!b.expanded and b.hasMore()) style = theme.styleExpandable();
                printLine(inner, row, 0, line, style);
                if (span) |sp| {
                    const slice = select_mod.sliceLine(line, sp.start, sp.end_excl, cells);
                    var c: u16 = @intCast(sp.start);
                    const end_c: u16 = @intCast(sp.end_excl);
                    while (c < end_c and c < inner.width) : (c += 1) {
                        printLine(inner, row, c, " ", sel_style);
                    }
                    if (slice.len > 0 and sp.start < inner.width) {
                        printLine(inner, row, @intCast(sp.start), slice, sel_style);
                    }
                } else {
                    var spans: [4]links_mod.Span = undefined;
                    const n = links_mod.scan(line, &spans);
                    var si: usize = 0;
                    while (si < n) : (si += 1) {
                        if (spans[si].start < line.len) {
                            const sl = spans[si].slice(line);
                            // The scanner reports byte offsets; the screen
                            // counts cells, so a link after any accented or
                            // wide text would otherwise underline the wrong
                            // cells.
                            const col = select_mod.cellCount(line[0..spans[si].start], cells);
                            printLine(inner, row, @intCast(@min(col, inner.width)), sl, theme.styleLink());
                        }
                    }
                }
                row += 1;
            }
            flat += 1;
            if (row >= inner.height) break;
        }
        if (row >= inner.height) break;
    }
    drawScrollbar(inner, store.scroll_off, line_count, view_h);
}

fn drawScrollbar(win: Window, scroll_off: usize, line_count: usize, view_h: usize) void {
    if (win.width < 2 or win.height < 2) return;
    if (line_count <= view_h) return;
    const track_h = win.height;
    const max_off = line_count - view_h;
    // thumb size proportional to visible fraction
    var thumb_h: u16 = @intCast(@max(@as(usize, 1), (view_h * track_h) / line_count));
    if (thumb_h > track_h) thumb_h = track_h;
    const travel = track_h -| thumb_h;
    const thumb_y: u16 = if (max_off == 0)
        0
    else
        @intCast((scroll_off * travel) / max_off);
    const x = win.width -| 1;
    var r: u16 = 0;
    while (r < track_h) : (r += 1) {
        const on_thumb = r >= thumb_y and r < thumb_y +| thumb_h;
        printLine(win, r, x, if (on_thumb) "▐" else "┊", if (on_thumb) theme.styleScrollbar() else theme.styleScrollbarTrack());
    }
}

pub const JumpButton = struct {
    /// Absolute screen rect (same coordinate space as mouse events).
    x: u16,
    y: u16,
    w: u16,
    h: u16 = 1,
    label: []const u8,

    pub fn contains(self: JumpButton, col: i16, row: i16) bool {
        if (col < 0 or row < 0) return false;
        const c: u16 = @intCast(col);
        const r: u16 = @intCast(row);
        return c >= self.x and r >= self.y and c < self.x +| self.w and r < self.y +| self.h;
    }
};

/// Lay out the jump-to-live button in the transcript inner area. `label` is the
/// bare text (`↓ jump` / `↓ 3 new`); brackets are added for the button chrome.
pub fn layoutJumpButton(inner_x: u16, inner_y: u16, inner_w: u16, inner_h: u16, label: []const u8) ?JumpButton {
    if (inner_h == 0 or inner_w < 6 or label.len == 0) return null;
    // "[ label ]" → +4 for brackets and spaces
    const chrome: usize = 4;
    const w_usize = label.len + chrome;
    if (w_usize > inner_w) return null;
    const w: u16 = @intCast(w_usize);
    return .{
        .x = inner_x +| (inner_w -| w),
        .y = inner_y +| (inner_h -| 1),
        .w = w,
        .h = 1,
        .label = label,
    };
}

pub fn drawJumpButton(
    win: Window,
    btn: JumpButton,
    hovered: bool,
    pressed: bool,
    frame: std.mem.Allocator,
) void {
    const style = if (pressed)
        theme.styleButtonDown()
    else if (hovered)
        theme.styleButtonHover()
    else
        theme.styleButton();
    const text = std.fmt.allocPrint(frame, "[ {s} ]", .{btn.label}) catch return;
    if (btn.y >= win.height or btn.x >= win.width) return;
    const strip = win.child(.{
        .x_off = btn.x,
        .y_off = btn.y,
        .width = @min(btn.w, win.width -| btn.x),
        .height = 1,
    });
    var col: u16 = 0;
    while (col < strip.width) : (col += 1) {
        printLine(strip, 0, col, " ", style);
    }
    printLine(strip, 0, 0, text, style);
}

/// Paint the CapTP lab help card centered in the window.
pub fn drawHelpModal(win: Window, frame: std.mem.Allocator) void {
    _ = frame;
    const card_w = win.width -| (win.width / 4);
    const card_h = win.height -| (win.height / 3);
    if (card_w < 20 or card_h < 10) return;
    const card = win.child(.{
        .x_off = win.width / 8,
        .y_off = win.height / 6,
        .width = card_w,
        .height = card_h,
        .border = theme.borderFocus(),
    });
    drawBorderTitle(card, "CapTP lab keys", theme.styleFocus());
    const lines = [_]struct { []const u8, vaxis.Style }{
        .{ "Ctrl-O   transcript browse", theme.styleBody() },
        .{ "F1       this help", theme.styleBody() },
        .{ "?        tip at prompt; help in browse", theme.styleBody() },
        .{ "{ }      prev/next user turn (browse)", theme.styleBody() },
        .{ "Tab      complete", theme.styleBody() },
        .{ "wheel / Shift↑↓ / PgUp·PgDn  scroll", theme.styleBody() },
        .{ "click    expand · [↓ jump] · menu", theme.styleBody() },
        .{ "Ctrl-click  open / insert link", theme.styleBody() },
        .{ "drag     select → copy (Shift-drag = terminal)", theme.styleBody() },
        .{ "Ctrl-y   re-copy selection", theme.styleBody() },
        .{ "↑↓       command history", theme.styleBody() },
        .{ "Ctrl-p   cycle panel focus", theme.styleBody() },
        .{ "focus    quiet CapTP rail", theme.styleBody() },
        .{ "Esc      cancel CapTP wait / dismiss", theme.styleMuted() },
    };
    var row: u16 = 2;
    for (lines) |ln| {
        if (row >= card.height) break;
        printLine(card, row, 2, ln[0], ln[1]);
        row += 1;
    }
}

pub fn drawMenu(win: Window, items: []const complete.Candidate, selected: usize, frame: std.mem.Allocator) void {
    drawBorderTitle(win, "complete", theme.styleFocus());
    const inner = belowTitle(win);
    if (inner.height < 1) return;
    const visible: usize = inner.height;
    const start = complete.menuScrollStart(selected, items.len, visible);
    var row: u16 = 0;
    var i = start;
    while (i < items.len and row < inner.height) : (i += 1) {
        const c = items[i];
        const on = i == selected;
        const style = if (on) theme.styleListCursor() else theme.styleBody();
        if (on) fillRowBg(inner, row, style);
        const marker: []const u8 = if (on) "▸ " else "  ";
        printFmt(inner, row, 0, style, frame, "{s}{s:<10} {s}", .{ marker, c.token, c.detail });
        row += 1;
    }
}

pub fn drawPromptDock(
    win: Window,
    ctx: *Ctx,
    progress: *const teach.Progress,
    text_input: *vaxis.widgets.TextInput,
    frame: std.mem.Allocator,
    focused: bool,
) void {
    _ = frame;
    if (win.height == 0) return;
    if (focused and win.height >= 2) {
        drawBorderTitle(win, "prompt", theme.styleFocus());
    } else if (win.height >= 3) {
        drawBorderTitle(win, "prompt", theme.styleMuted());
    }
    const open = ctx.session != null;
    const prompt: []const u8 = if (open) "pancake› " else "pancake· ";
    const prompt_style = if (open) theme.styleAccent() else theme.styleMuted();
    const has_title = (focused and win.height >= 2) or (!focused and win.height >= 3);
    const input_row: u16 = if (has_title) 1 else 0;

    printLine(win, input_row, 1, prompt, prompt_style);
    const prompt_cols = @max(@as(u16, 1), win.gwidth(prompt)) +| 1;
    if (prompt_cols < win.width) {
        const editor = win.child(.{
            .x_off = prompt_cols,
            .y_off = input_row,
            .width = win.width -| prompt_cols -| 1,
            .height = 1,
        });
        text_input.draw(editor);
    }
    if (win.height > input_row + 1) {
        printLine(win, win.height -| 1, 1, progress.promptFooter(), theme.styleTip());
    }
}
