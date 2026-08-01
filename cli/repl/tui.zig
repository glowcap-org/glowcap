//! CapTP lab TUI: ECS-lite scene, transcript + prompt dock, CapTP rail.
const std = @import("std");
const vaxis = @import("vaxis");
const Ctx = @import("../ctx.zig").Ctx;
const exit_codes = @import("../exit_codes.zig");
const log = @import("../operability/log.zig");
const copy = @import("copy.zig");
const teach = @import("teach.zig");
const theme = @import("theme.zig");
const complete = @import("complete.zig");
const layout = @import("layout.zig");
const panes = @import("panes.zig");
const blocks = @import("blocks.zig");
const links = @import("links.zig");
const exec = @import("exec.zig");
const history_mod = @import("history.zig");
const await_queue = @import("await_queue.zig");
const select_mod = @import("select.zig");
const width_mod = @import("width.zig");
const ecs = @import("ecs/mod.zig");

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    mouse: vaxis.Mouse,
};

const LabDivert = struct {
    store: *blocks.Store,
    fn write(ptr: *anyopaque, msg: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        var it = std.mem.splitScalar(u8, msg, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            exec.appendDivertLine(self.store, line) catch {};
        }
    }
};

fn envTruthy(environ: *const std.process.Environ.Map, key: []const u8) bool {
    const v = environ.get(key) orelse return false;
    return std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "yes");
}

pub fn run(ctx: *Ctx) !u8 {
    ctx.front = .repl;

    var tty_buf: [1024]u8 = undefined;
    var tty = try vaxis.Tty.init(ctx.io, &tty_buf);
    defer tty.deinit();

    var vx = try vaxis.init(ctx.io, ctx.gpa, @constCast(ctx.environ), .{});
    defer vx.deinit(ctx.gpa, tty.writer());

    var loop: vaxis.Loop(Event) = .init(ctx.io, &tty, &vx);
    try loop.installResizeHandler();
    defer loop.uninstallResizeHandler();
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.writer());
    // Mouse on: wheel/click + in-app drag-select (copy on release). Shift+drag
    // leaves selection to the terminal. PANCAKE_REPL_NO_MOUSE=1 disables all of it.
    const no_mouse = envTruthy(ctx.environ, "PANCAKE_REPL_NO_MOUSE");
    if (!no_mouse) {
        try vx.setMouseMode(tty.writer(), true);
    }
    defer if (!no_mouse) vx.setMouseMode(tty.writer(), false) catch {};
    try vx.queryTerminal(tty.writer(), .fromSeconds(1));
    {
        const ws = try tty.getWinsize();
        try vx.resize(ctx.gpa, tty.writer(), ws);
    }

    var text_input = vaxis.widgets.TextInput.init(ctx.gpa);
    defer text_input.deinit();

    var progress = teach.Progress.fromEnv(ctx.environ);
    progress.syncFromCtx(ctx);

    var store = blocks.Store.init(ctx.gpa);
    defer store.deinit();

    var lab = ecs.LabWorld.init(ctx.gpa);
    defer lab.deinit();
    lab.res.no_mouse = no_mouse;
    lab.res.reduced_motion = envTruthy(ctx.environ, "PANCAKE_REPL_REDUCED_MOTION");
    lab.transcript_e = try lab.entities.spawn();
    lab.prompt_e = try lab.entities.spawn();
    lab.jump_chip_e = try lab.entities.spawn();
    lab.menu_e = try lab.entities.spawn();

    var lab_divert = LabDivert{ .store = &store };
    log.setDivert(.{ .ptr = @ptrCast(&lab_divert), .writeFn = LabDivert.write });
    defer log.setDivert(null);

    var complete_state = complete.State.init(ctx.gpa);
    defer complete_state.deinit();
    var hist = history_mod.History.init(ctx.gpa);
    defer hist.deinit();

    if (!progress.quiet) {
        try exec.appendWorkbenchReady(&store);
    }

    var menu_open = false;
    var menu_sel: usize = 0;
    var menu_buf: [32]complete.Candidate = undefined;
    var menu_n: usize = 0;
    var flash: panes.Flash = .none;
    var flash_frames: u8 = 0;
    var transcript_view_h: usize = 8;
    var transcript_inner: RectCompat = .{};
    var jump_btn: ?panes.JumpButton = null;
    var selection_text: std.ArrayList(u8) = .empty;
    defer selection_text.deinit(ctx.gpa);

    var line_scratch: [4096]u8 = undefined;
    // Bounded drain buffer: one paint per burst keeps hover/scroll/select fluid.
    var burst: [64]Event = undefined;

    var captp_q = await_queue.Queue.init(ctx.gpa);
    defer captp_q.deinit();

    while (true) {
        // Idle CapTP pump: refresh session sample without a submit.
        // When a lab turn is awaiting settlement, `captp_q.tick` owns the step.
        if (!captp_q.busy()) pumpSession(ctx, &lab);

        // CapTP busy: socket wake (`stepReadable(frame_ms)`). Flash-only: no sleep —
        // paint the rail tip then clear (animation only when waiting is real).
        var burst_n: usize = 0;
        if (captp_q.busy()) {
            if (try loop.tryEvent()) |ev| {
                burst[0] = ev;
                burst_n = 1;
            } else if (ctx.session) |s| {
                _ = s.stepReadable(await_queue.frame_ms) catch {};
            } else {
                std.Io.sleep(ctx.io, std.Io.Duration.fromMilliseconds(await_queue.frame_ms), .real) catch {};
            }
        } else if (flash_frames > 0) {
            if (try loop.tryEvent()) |ev| {
                burst[0] = ev;
                burst_n = 1;
            }
            // else fall through immediately to paint/decrement
        } else {
            burst[0] = try loop.nextEvent();
            burst_n = 1;
        }
        while (burst_n > 0 and burst_n < burst.len) {
            const next = try loop.tryEvent() orelse break;
            // Coalesce consecutive mouse motions/drags to the latest sample.
            if (next == .mouse and burst[burst_n - 1] == .mouse) {
                const prev = burst[burst_n - 1].mouse;
                const cur = next.mouse;
                const prev_move = prev.type == .motion or prev.type == .drag;
                const cur_move = cur.type == .motion or cur.type == .drag;
                if (prev_move and cur_move and prev.button == cur.button) {
                    burst[burst_n - 1] = next;
                    continue;
                }
            }
            burst[burst_n] = next;
            burst_n += 1;
        }

        lab.intents.clear();
        var bi: usize = 0;
        while (bi < burst_n) : (bi += 1) {
            switch (burst[bi]) {
                .key_press => |key| {
                    const mapped = ecs.intent.fromKey(key, lab.res.mode, menu_open);
                    if (mapped) |intent| {
                        lab.intents.push(intent);
                    } else if (lab.res.mode == .prompt or lab.res.mode == .quiet or lab.res.mode == .complete) {
                        try text_input.update(.{ .key_press = key });
                        if (!key.mods.ctrl and !key.mods.alt and key.codepoint >= 32) {
                            lab.res.panel = .prompt;
                        }
                    }
                },
                .winsize => |ws| {
                    try vx.resize(ctx.gpa, tty.writer(), ws);
                    vx.queueRefresh();
                },
                .mouse => |m| {
                    if (lab.res.no_mouse) continue;
                    try handleMouse(
                        &vx,
                        &lab,
                        &store,
                        &text_input,
                        &line_scratch,
                        m,
                        transcript_view_h,
                        transcript_inner,
                        jump_btn,
                        &menu_open,
                        menu_buf[0..menu_n],
                        &menu_sel,
                        &selection_text,
                        ctx,
                    );
                },
            }
        }

        var quit = false;
        for (lab.intents.slice()) |intent| {
            if (try applyIntent(
                ctx,
                intent,
                &lab,
                &store,
                &text_input,
                &line_scratch,
                &progress,
                &complete_state,
                &hist,
                &menu_open,
                &menu_sel,
                &menu_buf,
                &menu_n,
                &flash,
                &flash_frames,
                transcript_view_h,
                transcript_inner,
                &selection_text,
                &vx,
                &tty,
                &captp_q,
            )) quit = true;
        }
        if (quit) break;

        if (captp_q.busy()) {
            const cf = try captp_q.tick(ctx, &store, &progress, &complete_state);
            if (cf != .none) {
                flash = cf;
                flash_frames = 2; // one visible paint, then clear (no invented delay)
            }
        }

        if (flash_frames > 0) {
            flash_frames -= 1;
            if (flash_frames == 0) flash = .none;
        }
        lab.res.auto_follow.paused = store.scroll_off > 0;
        lab.res.auto_follow.new_while_paused = store.new_while_paused;

        progress.syncFromCtx(ctx);
        transcript_inner = try render(
            &vx,
            &tty,
            ctx,
            &text_input,
            &store,
            &lab,
            &progress,
            menu_open,
            menu_buf[0..menu_n],
            menu_sel,
            flash,
            &transcript_view_h,
            &jump_btn,
        );
    }

    ctx.closeSession();
    return exit_codes.ok;
}

/// Screen rect shared with layout helpers (same space as mouse col/row).
const RectCompat = layout.ScreenRect;

fn pumpSession(ctx: *Ctx, lab: *ecs.LabWorld) void {
    _ = lab;
    if (ctx.session) |s| {
        // Non-blocking idle step so rail counts stay live between key events.
        _ = s.stepReadable(0) catch {};
    }
}

const drag_threshold_cells: u16 = 1;

fn handleMouse(
    vx: *vaxis.Vaxis,
    lab: *ecs.LabWorld,
    store: *blocks.Store,
    text_input: *vaxis.widgets.TextInput,
    line_scratch: []u8,
    m: vaxis.Mouse,
    view_h: usize,
    transcript_inner: RectCompat,
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
                            try acceptCandidate(text_input, line_scratch, menu_items[idx].token);
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
    transcript_inner: RectCompat,
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
    transcript_inner: RectCompat,
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
            // painted from. Compared raw, a wide glyph earlier in the line
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
            _ = child.wait(ctx.io) catch {};
        },
    }
}

fn fillAndCopySelection(
    ctx: *Ctx,
    buf: *std.ArrayList(u8),
    store: *const blocks.Store,
    lab: *const ecs.LabWorld,
    view_h: usize,
    transcript_inner: RectCompat,
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

fn replaceEditorLine(text_input: *vaxis.widgets.TextInput, line: []const u8) !void {
    text_input.clearRetainingCapacity();
    if (line.len > 0) try text_input.insertSliceAtCursor(line);
}

fn osc52Copy(ctx: *Ctx, text: []const u8) !void {
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
    std.Io.File.stdout().writeStreamingAll(ctx.io, msg.items) catch {};
}

fn applyIntent(
    ctx: *Ctx,
    intent: ecs.Intent,
    lab: *ecs.LabWorld,
    store: *blocks.Store,
    text_input: *vaxis.widgets.TextInput,
    line_scratch: []u8,
    progress: *teach.Progress,
    complete_state: *complete.State,
    hist: *history_mod.History,
    menu_open: *bool,
    menu_sel: *usize,
    menu_buf: *[32]complete.Candidate,
    menu_n: *usize,
    flash: *panes.Flash,
    flash_frames: *u8,
    transcript_view_h: usize,
    transcript_inner: RectCompat,
    selection_text: *std.ArrayList(u8),
    vx: *vaxis.Vaxis,
    tty: *vaxis.Tty,
    captp_q: *await_queue.Queue,
) !bool {
    _ = tty;
    switch (intent) {
        .quit => return true,
        .redraw => vx.queueRefresh(),
        .cancel_pending => {
            if (captp_q.active != null) {
                const cf = try captp_q.cancelActive(ctx, store, progress, complete_state);
                if (cf != .none) {
                    flash.* = cf;
                    flash_frames.* = 2;
                }
            } else if (lab.res.mode == .quiet) {
                lab.res.mode = .prompt;
            }
        },
        .scroll => |d| store.scroll(transcript_view_h, d),
        .scroll_page => |d| {
            const page: i32 = @intCast(@max(transcript_view_h, @as(usize, 1)));
            store.scroll(transcript_view_h, d * page);
        },
        .jump_top => {
            store.scroll_off = layout.clampScroll(std.math.maxInt(usize), store.flatLineCount(), transcript_view_h);
        },
        .jump_live => store.pinLive(),
        .jump_user_turn => |d| store.jumpUserTurn(transcript_view_h, d),
        .toggle_mode => |m| {
            if (lab.res.mode == m) {
                lab.res.mode = .prompt;
            } else {
                lab.res.mode = m;
            }
            if (lab.res.mode != .complete) menu_open.* = false;
        },
        .exit_overlay => {
            lab.res.mode = .prompt;
            menu_open.* = false;
        },
        .focus_next_panel => {
            lab.res.panel = switch (lab.res.panel) {
                .prompt => .transcript,
                .transcript => .rail_exports,
                .rail_exports => .rail_imports,
                .rail_imports => .rail_answers,
                .rail_answers => .prompt,
            };
        },
        .complete_tab => |dir| {
            menu_n.* = complete.candidates(complete_state, currentLine(text_input, line_scratch), menu_buf);
            if (menu_n.* == 0) {
                menu_open.* = false;
            } else if (menu_n.* == 1) {
                try acceptCandidate(text_input, line_scratch, menu_buf[0].token);
                menu_open.* = false;
                lab.res.mode = .prompt;
            } else {
                menu_sel.* = if (dir == .backward) menu_n.* - 1 else 0;
                menu_open.* = true;
                lab.res.mode = .complete;
                try previewCandidate(text_input, line_scratch, menu_buf[menu_sel.*].token);
            }
        },
        .complete_cycle => |d| {
            if (menu_open.* and menu_n.* > 0) {
                menu_sel.* = complete.cycleSel(menu_sel.*, menu_n.*, d);
                try previewCandidate(text_input, line_scratch, menu_buf[menu_sel.*].token);
            }
        },
        .complete_accept => {
            if (menu_open.* and menu_n.* > 0) try acceptCandidate(text_input, line_scratch, menu_buf[menu_sel.*].token);
            menu_open.* = false;
            lab.res.mode = .prompt;
        },
        .submit_line => {
            const line = currentLine(text_input, line_scratch);
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len > 0) {
                try hist.push(trimmed);
                store.pinLive();
                const turn = try exec.handleLine(ctx, trimmed, store, progress, complete_state, captp_q);
                if (turn.quit) return true;
                if (turn.enqueue_captp) |cap_line| {
                    try captp_q.enqueue(ctx, cap_line, store, progress);
                }
                if (turn.toggle_quiet) {
                    lab.res.mode = if (lab.res.mode == .quiet) .prompt else .quiet;
                }
                if (turn.focus_pane) |p| lab.res.panel = panelFromTour(p);
                flash.* = turn.flash;
                if (flash.* != .none) flash_frames.* = 2;
            }
            text_input.clearRetainingCapacity();
            hist.resetBrowse();
        },
        .history_prev => {
            const cur = currentLine(text_input, line_scratch);
            if (hist.prev(cur)) |entry| try replaceEditorLine(text_input, entry);
        },
        .history_next => {
            if (hist.next()) |entry| try replaceEditorLine(text_input, entry);
        },
        .copy_selection => {
            if (selection_text.items.len > 0) {
                try osc52Copy(ctx, selection_text.items);
            } else {
                try fillAndCopySelection(ctx, selection_text, store, lab, transcript_view_h, transcript_inner, width_mod.ofScreen(&vx.screen));
            }
        },
    }
    return false;
}

fn currentLine(text_input: *vaxis.widgets.TextInput, scratch: []u8) []const u8 {
    const first = text_input.buf.firstHalf();
    const second = text_input.buf.secondHalf();
    const total = first.len + second.len;
    if (total > scratch.len) {
        const n = scratch.len;
        if (first.len >= n) {
            @memcpy(scratch[0..n], first[0..n]);
            return scratch[0..n];
        }
        @memcpy(scratch[0..first.len], first);
        const rest = n - first.len;
        @memcpy(scratch[first.len..][0..rest], second[0..rest]);
        return scratch[0..n];
    }
    @memcpy(scratch[0..first.len], first);
    @memcpy(scratch[first.len .. first.len + second.len], second);
    return scratch[0..total];
}

fn replaceLastToken(text_input: *vaxis.widgets.TextInput, scratch: []u8, token: []const u8, trailing_space: bool) !void {
    const line = currentLine(text_input, scratch);
    var cut: usize = line.len;
    while (cut > 0 and line[cut - 1] != ' ' and line[cut - 1] != '\t') cut -= 1;
    text_input.clearRetainingCapacity();
    if (cut > 0) try text_input.insertSliceAtCursor(line[0..cut]);
    try text_input.insertSliceAtCursor(token);
    if (trailing_space) try text_input.insertSliceAtCursor(" ");
}

fn previewCandidate(text_input: *vaxis.widgets.TextInput, scratch: []u8, token: []const u8) !void {
    try replaceLastToken(text_input, scratch, token, false);
}

fn acceptCandidate(text_input: *vaxis.widgets.TextInput, scratch: []u8, token: []const u8) !void {
    try replaceLastToken(text_input, scratch, token, true);
}

fn modeBadge(mode: ecs.Mode) []const u8 {
    return switch (mode) {
        .prompt => "",
        .complete => "COMPLETE",
        .transcript => "TRANSCRIPT",
        .quiet => "QUIET",
        .help => "HELP",
    };
}

fn panelBadge(panel: ecs.PanelFocus) []const u8 {
    return switch (panel) {
        .prompt => "prompt",
        .transcript => "transcript",
        .rail_exports => "exports",
        .rail_imports => "imports",
        .rail_answers => "answers",
    };
}

fn panelFromTour(pane: teach.Pane) ecs.PanelFocus {
    return switch (pane) {
        .exports => .rail_exports,
        .imports => .rail_imports,
        .answers => .rail_answers,
    };
}

fn tourFromPanel(panel: ecs.PanelFocus) ?teach.Pane {
    return switch (panel) {
        .rail_exports => .exports,
        .rail_imports => .imports,
        .rail_answers => .answers,
        else => null,
    };
}

fn focusBorder(focused: bool) vaxis.Window.BorderOptions {
    return if (focused) theme.borderFocus() else theme.borderIdle();
}

fn render(
    vx: *vaxis.Vaxis,
    tty: *vaxis.Tty,
    ctx: *Ctx,
    text_input: *vaxis.widgets.TextInput,
    store: *blocks.Store,
    lab: *ecs.LabWorld,
    progress: *const teach.Progress,
    menu_open: bool,
    menu_items: []const complete.Candidate,
    menu_sel: usize,
    flash: panes.Flash,
    transcript_view_h: *usize,
    jump_btn_out: *?panes.JumpButton,
) !RectCompat {
    var arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena.deinit();
    const frame = arena.allocator();

    const win = vx.window();
    win.clear();

    const quiet = lab.res.mode == .quiet;
    const g = layout.compute(win.width, win.height, menu_open and menu_items.len > 0, menu_items.len, progress.guide_active);
    lab.res.geom = g;

    var y: u16 = 0;
    if (g.status_h > 0) {
        const status_win = win.child(.{ .x_off = 0, .y_off = y, .width = win.width, .height = g.status_h });
        // Mode badge wins over panel chip when an overlay mode is active.
        const badge = modeBadge(lab.res.mode);
        const chip = if (badge.len > 0) badge else panelBadge(lab.res.panel);
        panes.drawStatus(status_win, ctx, frame, chip);
        y += g.status_h;
    }

    if (g.stage_h > 0) {
        panes.drawStage(win.child(.{ .x_off = 0, .y_off = y, .width = win.width, .height = g.stage_h }), progress, frame);
        y += g.stage_h;
    }
    if (g.strip_h > 0 or (quiet and g.mode == .split)) {
        const sh = if (g.strip_h > 0) g.strip_h else @as(u16, 1);
        if (quiet or g.strip_h > 0) {
            panes.drawTablesStrip(win.child(.{ .x_off = 0, .y_off = y, .width = win.width, .height = sh }), ctx, flash, frame);
            if (g.strip_h > 0) y += g.strip_h;
        }
    }

    var transcript_inner: RectCompat = .{};
    if (g.main_h > 0) {
        const rail_tour = tourFromPanel(lab.res.panel);
        const panel_on_rail = rail_tour != null;
        const show_rail = g.mode == .split and g.rail_w > 0 and !quiet;
        if (show_rail) {
            const rail_win = win.child(.{
                .x_off = g.repl_w,
                .y_off = y,
                .width = g.rail_w,
                .height = g.main_h,
                .border = focusBorder(panel_on_rail),
            });
            panes.drawTablesRail(rail_win, ctx, flash, rail_tour, frame);
        }

        const repl_w = if (show_rail) g.repl_w else win.width;
        var ry: u16 = 0;
        if (g.transcript_h > 0) {
            const transcript_focused = lab.res.panel == .transcript or lab.res.mode == .transcript;
            const tw = win.child(.{
                .x_off = 0,
                .y_off = y + ry,
                .width = repl_w,
                .height = g.transcript_h,
                .border = focusBorder(transcript_focused),
            });
            var jump_buf: [32]u8 = undefined;
            const jump_label: ?[]const u8 = if (store.scroll_off > 0 and lab.res.auto_follow.new_while_paused > 0)
                std.fmt.bufPrint(&jump_buf, "↓ {d} new", .{lab.res.auto_follow.new_while_paused}) catch "↓ jump"
            else if (store.scroll_off > 0)
                "↓ jump"
            else
                null;
            // One source of truth: vaxis all-border + 1-row title → content rect.
            const content = layout.contentBelowTitle(0, y + ry, repl_w, g.transcript_h);
            jump_btn_out.* = null;
            if (jump_label) |jl| {
                jump_btn_out.* = panes.layoutJumpButton(content.x, content.y, content.w, content.h, jl);
            }
            const over_jump = if (jump_btn_out.*) |jb| jb.contains(lab.res.mouse_col, lab.res.mouse_row) else false;
            const range: ?select_mod.Anchors = if (lab.res.selection.highlights())
                lab.res.selection.anchors
            else
                null;
            panes.drawTranscriptBlocks(
                tw,
                store,
                modeBadge(lab.res.mode),
                transcript_focused,
                range,
                content.x,
                content.y,
            );
            transcript_inner = .{ .x = content.x, .y = content.y, .w = content.w, .h = content.h };
            transcript_view_h.* = if (content.h > 0) content.h else 1;
            store.clampView(transcript_view_h.*);
            if (lab.transcript_e) |te| {
                lab.rect.set(te, .{ .x = content.x, .y = content.y, .w = content.w, .h = content.h });
            }
            if (jump_btn_out.*) |jb| {
                panes.drawJumpButton(win, jb, over_jump, lab.res.jump_pressed, frame);
                if (lab.jump_chip_e) |je| {
                    lab.rect.set(je, .{ .x = jb.x, .y = jb.y, .w = jb.w, .h = jb.h });
                }
            }
            ry += g.transcript_h;
        } else {
            jump_btn_out.* = null;
        }
        if (g.menu_h > 0 and menu_open) {
            const menu_frame_y = y + ry;
            const mw = win.child(.{
                .x_off = 0,
                .y_off = menu_frame_y,
                .width = repl_w,
                .height = g.menu_h,
                .border = theme.borderIdle(),
            });
            panes.drawMenu(mw, menu_items, menu_sel, frame);
            const menu_content = layout.contentBelowTitle(0, menu_frame_y, repl_w, g.menu_h);
            if (lab.menu_e) |me| {
                lab.rect.set(me, .{ .x = menu_content.x, .y = menu_content.y, .w = menu_content.w, .h = menu_content.h });
            }
            ry += g.menu_h;
        }
        if (g.prompt_h > 0 and lab.res.mode != .transcript) {
            const prompt_focused = lab.res.panel == .prompt;
            const prompt_frame_y = y + ry;
            const pw = win.child(.{
                .x_off = 0,
                .y_off = prompt_frame_y,
                .width = repl_w,
                .height = g.prompt_h,
                .border = focusBorder(prompt_focused),
            });
            panes.drawPromptDock(pw, ctx, progress, text_input, frame, prompt_focused);
            if (lab.prompt_e) |pe| {
                // Full outer frame (incl. border) — click chrome still focuses the dock.
                lab.rect.set(pe, .{ .x = 0, .y = prompt_frame_y, .w = repl_w, .h = g.prompt_h });
            }
        }
    }

    if (lab.res.mode == .help) {
        panes.drawHelpModal(win, frame);
    }

    try vx.render(tty.writer());
    return transcript_inner;
}
