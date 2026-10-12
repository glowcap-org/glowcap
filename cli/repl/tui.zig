//! CapTP lab TUI: ECS-lite scene, transcript + prompt dock, CapTP rail.
const std = @import("std");
const vaxis = @import("vaxis");
const Ctx = @import("../ctx.zig").Ctx;
const exit_codes = @import("../exit_codes.zig");
const log = @import("../operability/log.zig");
const teach = @import("teach.zig");
const theme = @import("theme.zig");
const complete = @import("complete.zig");
const layout = @import("layout.zig");
const panes = @import("panes.zig");
const blocks = @import("blocks.zig");
const exec = @import("exec.zig");
const history_mod = @import("history.zig");
const await_queue = @import("await_queue.zig");
const select_mod = @import("select.zig");
const width_mod = @import("width.zig");
const ecs = @import("ecs/mod.zig");
const mouse = @import("mouse.zig");
const prompt_edit = @import("prompt_edit.zig");

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
            // best-effort: a diverted log line the store cannot take is dropped.
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
    // leaves selection to the terminal. GLOWCAP_REPL_NO_MOUSE=1 disables all of it.
    const no_mouse = envTruthy(ctx.environ, "GLOWCAP_REPL_NO_MOUSE");
    if (!no_mouse) {
        try vx.setMouseMode(tty.writer(), true);
    }
    // best-effort: terminal-mode restore at teardown; the terminal may be gone.
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
    lab.res.reduced_motion = envTruthy(ctx.environ, "GLOWCAP_REPL_REDUCED_MOTION");
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
    var closed = false;
    defer {
        // The active flag is a live vow listener. Close the session while the
        // queue still owns that flag, then reclaim the queue on every exit.
        if (!closed) {
            if (ctx.closeOwned(.cancel)) |failure| ctx.logCloseFailure("repl close", failure);
        }
        captp_q.deinit();
    }

    while (true) {
        // Idle: non-blocking step so rail counts stay live between key events.
        if (!captp_q.busy()) {
            if (ctx.activeSession()) |s| try captp_q.advanceSession(s, &store, 0);
        }

        // CapTP busy: socket wake (`stepReadable(frame_ms)`). Flash-only: no sleep,
        // paint the rail tip then clear (animation only when waiting is real).
        var burst_n: usize = 0;
        if (captp_q.busy()) {
            if (try loop.tryEvent()) |ev| {
                burst[0] = ev;
                burst_n = 1;
            } else if (ctx.activeSession()) |s| {
                try captp_q.advanceSession(s, &store, await_queue.frame_ms);
            } else {
                // tolerant: an interrupted frame sleep only redraws sooner.
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
                    try mouse.handleMouse(
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

    const close_failure = ctx.closeOwned(.cancel);
    closed = true;
    if (close_failure) |failure| {
        ctx.logCloseFailure("repl close", failure);
        return ctx.mapCloseErr(failure.cause);
    }
    return exit_codes.ok;
}

/// Screen rect shared with layout helpers (same space as mouse col/row).
const RectCompat = layout.ScreenRect;

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
            menu_n.* = complete.candidates(complete_state, prompt_edit.currentLine(text_input, line_scratch), menu_buf);
            if (menu_n.* == 0) {
                menu_open.* = false;
            } else if (menu_n.* == 1) {
                try prompt_edit.acceptCandidate(text_input, line_scratch, menu_buf[0].token);
                menu_open.* = false;
                lab.res.mode = .prompt;
            } else {
                menu_sel.* = if (dir == .backward) menu_n.* - 1 else 0;
                menu_open.* = true;
                lab.res.mode = .complete;
                try prompt_edit.previewCandidate(text_input, line_scratch, menu_buf[menu_sel.*].token);
            }
        },
        .complete_cycle => |d| {
            if (menu_open.* and menu_n.* > 0) {
                menu_sel.* = complete.cycleSel(menu_sel.*, menu_n.*, d);
                try prompt_edit.previewCandidate(text_input, line_scratch, menu_buf[menu_sel.*].token);
            }
        },
        .complete_accept => {
            if (menu_open.* and menu_n.* > 0) try prompt_edit.acceptCandidate(text_input, line_scratch, menu_buf[menu_sel.*].token);
            menu_open.* = false;
            lab.res.mode = .prompt;
        },
        .submit_line => {
            const line = prompt_edit.currentLine(text_input, line_scratch);
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
            const cur = prompt_edit.currentLine(text_input, line_scratch);
            if (hist.prev(cur)) |entry| try prompt_edit.replaceEditorLine(text_input, entry);
        },
        .history_next => {
            if (hist.next()) |entry| try prompt_edit.replaceEditorLine(text_input, entry);
        },
        .copy_selection => {
            if (selection_text.items.len > 0) {
                try mouse.osc52Copy(ctx, selection_text.items);
            } else {
                try mouse.fillAndCopySelection(ctx, selection_text, store, lab, transcript_view_h, transcript_inner, width_mod.ofScreen(&vx.screen));
            }
        },
    }
    return false;
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
                // Full outer frame (incl. border): click chrome still focuses the dock.
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
