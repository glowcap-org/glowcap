//! CapTP lab REPL: completion, copy inventory, optional locator (line path).
const std = @import("std");
const cli = @import("cli");
const glowcap = @import("glowcap");

test "await_queue classifies CapTP session verbs" {
    try std.testing.expect(cli.repl_await_queue.isSessionVerb("call"));
    try std.testing.expect(cli.repl_await_queue.isSessionVerb("fetch"));
    try std.testing.expect(cli.repl_await_queue.isSessionVerb("tell"));
    try std.testing.expect(cli.repl_await_queue.isSessionVerb("publish"));
    try std.testing.expect(!cli.repl_await_queue.isSessionVerb("tour"));
    try std.testing.expect(!cli.repl_await_queue.isSessionVerb("help"));
}

test "every repl meta command has an exec arm" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();

    for (cli.repl_meta.entries) |entry| {
        var ctx = cli.ctx.Ctx{ .io = threaded.io(), .gpa = gpa, .environ = &environ, .front = .repl };
        defer ctx.deinit();
        var store = cli.repl_blocks.Store.init(gpa);
        defer store.deinit();
        var progress = cli.repl_teach.Progress{};
        var complete_state = cli.repl_complete.State.init(gpa);
        defer complete_state.deinit();
        _ = try cli.repl_exec.handleLine(&ctx, entry.name, &store, &progress, &complete_state, null);
        // A meta token without its own exec arm falls through to registry
        // dispatch and lands an error block; the single `repl_meta` owner
        // means Tab, the help footer, and dispatch must agree.
        for (store.items.items) |item| {
            try std.testing.expect(item.kind != .error_line);
        }
    }
}

test "blocks setLine rewrites pending" {
    var store = cli.repl_blocks.Store.init(std.testing.allocator);
    defer store.deinit();
    try store.appendLine(.pending, "⠋ call #0 greet world");
    try store.setLine(0, .error_line, "! cancelled");
    try std.testing.expect(store.items.items[0].kind == .error_line);
    try std.testing.expectEqualStrings("! cancelled", store.items.items[0].body);
}

test "complete suggests verbs for empty line" {
    var state = cli.repl_complete.State.init(std.testing.allocator);
    defer state.deinit();
    var out: [32]cli.repl_complete.Candidate = undefined;
    const n = cli.repl_complete.candidates(&state, "", &out);
    try std.testing.expect(n >= 4);
    var saw_call = false;
    for (out[0..n]) |c| {
        if (std.mem.eql(u8, c.token, "call")) saw_call = true;
    }
    try std.testing.expect(saw_call);
    // Every REPL-only meta command Tab-completes, and the derived help footer
    // names each one — the single `meta.entries` owner cannot drift from either.
    for (cli.repl_meta.entries) |entry| {
        var saw = false;
        for (out[0..n]) |c| {
            if (std.mem.eql(u8, c.token, entry.name)) saw = true;
        }
        try std.testing.expect(saw);
        try std.testing.expect(std.mem.indexOf(u8, cli.repl_meta.footer, entry.name) != null);
    }
}

test "complete filters by prefix" {
    var state = cli.repl_complete.State.init(std.testing.allocator);
    defer state.deinit();
    var out: [32]cli.repl_complete.Candidate = undefined;
    const n = cli.repl_complete.candidates(&state, "fe", &out);
    try std.testing.expect(n >= 1);
    try std.testing.expectEqualStrings("fetch", out[0].token);
}

test "complete suggests greeter after call" {
    var state = cli.repl_complete.State.init(std.testing.allocator);
    defer state.deinit();
    var out: [32]cli.repl_complete.Candidate = undefined;
    const n = cli.repl_complete.candidates(&state, "call ", &out);
    var saw = false;
    for (out[0..n]) |c| {
        if (std.mem.eql(u8, c.token, "greeter")) saw = true;
    }
    try std.testing.expect(saw);
}

test "complete cycleSel wraps" {
    try std.testing.expectEqual(@as(usize, 1), cli.repl_complete.cycleSel(0, 3, 1));
    try std.testing.expectEqual(@as(usize, 2), cli.repl_complete.cycleSel(1, 3, 1));
    try std.testing.expectEqual(@as(usize, 0), cli.repl_complete.cycleSel(2, 3, 1));
    try std.testing.expectEqual(@as(usize, 2), cli.repl_complete.cycleSel(0, 3, -1));
    try std.testing.expectEqual(@as(usize, 0), cli.repl_complete.cycleSel(1, 3, -1));
    try std.testing.expectEqual(@as(usize, 0), cli.repl_complete.cycleSel(0, 0, 1));
}

test "complete menuScrollStart keeps selection visible" {
    try std.testing.expectEqual(@as(usize, 0), cli.repl_complete.menuScrollStart(0, 10, 5));
    try std.testing.expectEqual(@as(usize, 0), cli.repl_complete.menuScrollStart(4, 10, 5));
    try std.testing.expectEqual(@as(usize, 1), cli.repl_complete.menuScrollStart(5, 10, 5));
    try std.testing.expectEqual(@as(usize, 5), cli.repl_complete.menuScrollStart(9, 10, 5));
    try std.testing.expectEqual(@as(usize, 0), cli.repl_complete.menuScrollStart(2, 3, 5));
}

test "layout compute split stacked compact" {
    const L = cli.repl_layout;
    const wide = L.compute(120, 40, false, 0, false);
    try std.testing.expect(wide.mode == .split);
    try std.testing.expect(wide.rail_w >= L.rail_min_w);
    try std.testing.expect(wide.repl_w > wide.rail_w);
    try std.testing.expectEqual(@as(u16, 0), wide.stage_h); // workbench: no stage strip
    // REPL column stacks to main_h; chrome + main fills the terminal.
    try std.testing.expectEqual(wide.main_h, wide.transcript_h + wide.menu_h + wide.prompt_h);
    try std.testing.expectEqual(@as(u16, 40), wide.status_h + wide.stage_h + wide.strip_h + wide.main_h);

    const guided = L.compute(120, 40, false, 0, true);
    try std.testing.expectEqual(@as(u16, 1), guided.stage_h);
    try std.testing.expectEqual(@as(u16, 40), guided.status_h + guided.stage_h + guided.strip_h + guided.main_h);

    const mid = L.compute(60, 30, false, 0, false);
    try std.testing.expect(mid.mode == .stacked);
    try std.testing.expectEqual(@as(u16, 0), mid.rail_w);
    try std.testing.expect(mid.strip_h >= 1);
    try std.testing.expectEqual(mid.main_h, mid.transcript_h + mid.menu_h + mid.prompt_h);

    const tiny = L.compute(20, 5, false, 0, false);
    try std.testing.expect(tiny.mode == .compact);
    try std.testing.expect(tiny.transcript_h >= 1);
    try std.testing.expect(tiny.prompt_h >= 1);

    const menu = L.compute(100, 24, true, 12, false);
    try std.testing.expect(menu.menu_h >= 3);
    try std.testing.expectEqual(menu.main_h, menu.transcript_h + menu.menu_h + menu.prompt_h);
    try std.testing.expectEqual(@as(u16, 24), menu.status_h + menu.stage_h + menu.strip_h + menu.main_h);
    // Prompt stays in the REPL column — never wider than repl_w.
    try std.testing.expect(menu.repl_w < menu.cols);
}

test "layout scroll clamp and start" {
    const L = cli.repl_layout;
    try std.testing.expectEqual(@as(usize, 0), L.clampScroll(99, 5, 10));
    try std.testing.expectEqual(@as(usize, 5), L.clampScroll(99, 15, 10));
    // 15 lines, view 10, live → start at 5; max scroll_off=5 → start 0
    try std.testing.expectEqual(@as(usize, 5), L.transcriptStart(0, 15, 10));
    try std.testing.expectEqual(@as(usize, 0), L.transcriptStart(5, 15, 10));
    // line_count=20 view=10 scroll=0 → start = 10 (live end)
    try std.testing.expectEqual(@as(usize, 10), L.transcriptStart(0, 20, 10));
    try std.testing.expectEqual(@as(usize, 5), L.transcriptStart(5, 20, 10));
    try std.testing.expectEqual(@as(usize, 3), L.scrollBy(0, 20, 10, 3));
    try std.testing.expectEqual(@as(usize, 0), L.scrollBy(2, 20, 10, -5));
}

test "teach nextStep follows stage" {
    var p = cli.repl_teach.Progress{};
    try std.testing.expectEqualStrings(cli.repl_copy.next_identity, p.nextStep());
    p.has_identity = true;
    try std.testing.expectEqualStrings(cli.repl_copy.next_connect, p.nextStep());
    p.has_connect = true;
    p.has_session = true;
    try std.testing.expectEqualStrings(cli.repl_copy.next_fetch, p.nextStep());
}

test "teach tour completes tables stage" {
    var p = cli.repl_teach.Progress{
        .has_identity = true,
        .has_connect = true,
        .has_session = true,
        .has_fetch = true,
        .has_deliver = true,
    };
    try std.testing.expect(p.current() == .tables);
    try std.testing.expect(!p.completed(.tables));
    try std.testing.expectEqualStrings(cli.repl_copy.next_tables, p.nextStep());
    p.noteTour();
    try std.testing.expect(p.completed(.tables));
    try std.testing.expectEqualStrings(cli.repl_copy.next_done, p.nextStep());
}

test "log divert captures Ctx.logErr off stderr" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    const Capture = struct {
        list: *std.ArrayList(u8),
        gpa: std.mem.Allocator,
        fn write(ptr: *anyopaque, msg: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.list.appendSlice(self.gpa, msg) catch {};
        }
    };
    var cap = Capture{ .list = &list, .gpa = gpa };
    const log = cli.log;
    log.setDivert(.{ .ptr = @ptrCast(&cap), .writeFn = Capture.write });
    defer log.setDivert(null);

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var ctx = cli.ctx.Ctx{
        .io = threaded.io(),
        .gpa = gpa,
        .environ = &environ,
    };
    ctx.logErr("dial needs an ocapn:// locator", .{});
    try std.testing.expect(std.mem.indexOf(u8, list.items, "dial needs an ocapn:// locator") != null);
    try std.testing.expect(std.mem.indexOf(u8, list.items, "glowcap: error:") != null);
    try std.testing.expect(log.hasDivert());
}

test "layout transcriptInnerH and emergency row sum" {
    const L = cli.repl_layout;
    // Outer 7 = border(2) + title(1) + content(4).
    try std.testing.expectEqual(@as(u16, 4), L.transcriptInnerH(7));
    try std.testing.expectEqual(@as(u16, 0), L.transcriptInnerH(2));
    const tiny = L.compute(40, 3, false, 0, false);
    try std.testing.expect(tiny.status_h + tiny.stage_h + tiny.strip_h + tiny.main_h <= 3);
}

test "layout contentBelowTitle matches border+title inset" {
    const L = cli.repl_layout;
    const c = L.contentBelowTitle(0, 10, 40, 12);
    // frame y=10 → inside border y=11 → below title y=12; h=12-3=9
    try std.testing.expectEqual(@as(u16, 1), c.x);
    try std.testing.expectEqual(@as(u16, 12), c.y);
    try std.testing.expectEqual(@as(u16, 38), c.w);
    try std.testing.expectEqual(@as(u16, 9), c.h);
    try std.testing.expect(c.contains(1, 12));
    try std.testing.expect(c.contains(38, 20));
    try std.testing.expect(!c.contains(0, 12)); // left border
    try std.testing.expect(!c.contains(1, 11)); // title row
    try std.testing.expect(!c.contains(1, 21)); // past content
}

test "complete advertises listen (backgrounded) but not argv-only leaves" {
    var state = cli.repl_complete.State.init(std.testing.allocator);
    defer state.deinit();
    var out: [32]cli.repl_complete.Candidate = undefined;
    const n = cli.repl_complete.candidates(&state, "", &out);
    var saw_listen = false;
    for (out[0..n]) |c| {
        if (std.mem.eql(u8, c.token, "listen")) saw_listen = true;
        try std.testing.expect(!std.mem.eql(u8, c.token, "locator"));
    }
    try std.testing.expect(saw_listen);
}

test "copy gloss covers registry verbs" {
    for (cli.registry.commands) |cmd| {
        const g = cli.repl_copy.gloss(cmd.name);
        try std.testing.expect(g.len > 0);
    }
    try std.testing.expect(cli.repl_copy.gloss("tour").len > 0);
    try std.testing.expect(cli.repl_copy.gloss("guide").len > 0);
    try std.testing.expect(cli.repl_copy.workbench_ready.len > 0);
    try std.testing.expect(cli.repl_copy.coach_guide.len > 0);
    try std.testing.expect(cli.repl_copy.help_captp_map.len > 0);
}

test "teach guide toggles walkthrough chrome" {
    var p = cli.repl_teach.Progress{};
    try std.testing.expect(!p.guide_active);
    try std.testing.expectEqualStrings(cli.repl_copy.workbench_footer, p.promptFooter());
    p.enterGuide();
    try std.testing.expect(p.guide_active);
    try std.testing.expectEqualStrings(cli.repl_copy.next_identity, p.promptFooter());
    p.exitGuide();
    try std.testing.expect(!p.guide_active);
    try std.testing.expectEqualStrings(cli.repl_copy.workbench_footer, p.promptFooter());
}

test "teach parseTourPane" {
    try std.testing.expect(cli.repl_teach.parseTourPane("exports") == .exports);
    try std.testing.expect(cli.repl_teach.parseTourPane("imports") == .imports);
    try std.testing.expect(cli.repl_teach.parseTourPane("answers") == .answers);
    try std.testing.expect(cli.repl_teach.parseTourPane("nope") == null);
}

test "blocks collapse and blockAtViewRow" {
    var s = cli.repl_blocks.Store.init(std.testing.allocator);
    defer s.deinit();
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(std.testing.allocator);
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try big.appendSlice(std.testing.allocator, "line\n");
    }
    try s.appendMultiline(.result, big.items);
    try std.testing.expect(!s.items.items[0].expanded);
    try s.appendLine(.user, "› hello");
    try std.testing.expect(s.blockAtViewRow(20, 0) != null);
    s.scroll_off = 1;
    try s.appendLine(.result, "paused");
    try std.testing.expect(s.new_while_paused >= 1);
    s.pinLive();
    try std.testing.expectEqual(@as(usize, 0), s.new_while_paused);
}

test "links scan ocapn and https" {
    var spans: [4]cli.repl_links.Span = undefined;
    const n = cli.repl_links.scan("see ocapn://tcp.localhost/x and https://ex.com", &spans);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expect(spans[0].kind == .ocapn);
    try std.testing.expect(spans[1].kind == .https);
}

test "ecs world spawns an entity and stores its screen rectangle" {
    var lab = cli.repl_ecs.LabWorld.init(std.testing.allocator);
    defer lab.deinit();
    const e = try lab.entities.spawn();
    lab.rect.set(e, .{ .x = 2, .y = 3, .w = 10, .h = 4 });
    try std.testing.expect(lab.rect.get(e).?.contains(5, 4));
}

test "session forEach export import answer views" {
    const allocator = std.testing.allocator;
    const session = glowcap.ocapn.session;
    const inspect = session.inspect;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerExport(.from(7));
    try s.registerImport(.from(3));

    try std.testing.expectEqual(@as(usize, 1), inspect.exportCount(&s));
    try std.testing.expectEqual(@as(usize, 1), inspect.importCount(&s));

    var export_seen: usize = 0;
    const E = struct {
        n: *usize,
        fn visit(c: *@This(), v: session.ExportView) void {
            c.n.* += 1;
            std.debug.assert(v.position.int() == 7);
        }
    };
    var ec = E{ .n = &export_seen };
    inspect.forEachExport(&s, &ec, E.visit);
    try std.testing.expectEqual(@as(usize, 1), export_seen);

    var import_seen: usize = 0;
    const I = struct {
        n: *usize,
        fn visit(c: *@This(), v: session.ImportView) void {
            c.n.* += 1;
            std.debug.assert(v.position.int() == 3);
        }
    };
    var ic = I{ .n = &import_seen };
    inspect.forEachImport(&s, &ic, I.visit);
    try std.testing.expectEqual(@as(usize, 1), import_seen);

    try s.recordRecv(.{
        .deliver = .{
            .target = .{ .near = .{ .export_position = .from(7) } },
            .args = &.{.{ .bytes = "hello" }},
            .answer = .from(11),
        },
    });
    try std.testing.expectEqual(@as(usize, 1), inspect.inboundAnswerCount(&s));
    var answer_seen: usize = 0;
    const A = struct {
        n: *usize,
        fn visit(c: *@This(), v: session.AnswerRowView) void {
            c.n.* += 1;
            std.debug.assert(v.position == .wire and v.position.wire.int() == 11);
        }
    };
    var ac = A{ .n = &answer_seen };
    inspect.forEachInboundAnswer(&s, &ac, A.visit);
    try std.testing.expectEqual(@as(usize, 1), answer_seen);
}

/// Selection geometry is measured in cells, so a test says how wide the
/// terminal it stands in for draws things. Here every character is one cell.
fn oneCellWide(_: ?*const anyopaque, _: []const u8) u16 {
    return 1;
}

test "select appendSelected joins cell ranges" {
    const S = cli.repl_select;
    const lines = [_][]const u8{ "abcdefghij", "12345678", "ABCDEFGHIJ" };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try S.appendSelected(
        .{ .col = 5, .row = 10 },
        .{ .col = 4, .row = 12 },
        2,
        10,
        &lines,
        &buf,
        std.testing.allocator,
        .{ .measure = oneCellWide },
    );
    try std.testing.expectEqualStrings("defghij\n12345678\nABC", buf.items);
}

/// The one grapheme these cases draw two cells wide, standing in for the
/// terminal's width tables.
fn hanTwoCells(_: ?*const anyopaque, character: []const u8) u16 {
    return if (std.mem.eql(u8, "漢", character)) 2 else 1;
}

test "hover finds the link the underline was painted on" {
    // The pointer names a cell; a scanned link is a byte range. A wide glyph
    // ahead of the link moves the two apart, and comparing them raw pointed
    // hover at whatever byte happened to share the number.
    const S = cli.repl_select;
    const L = cli.repl_links;
    const cells = S.CellWidth{ .measure = hanTwoCells };
    const line = "漢 ocapn://tcp.localhost/x";

    // 漢 is three bytes drawn in two cells, so the link starts at cell 3 and
    // byte 4.
    try std.testing.expectEqual(@as(usize, 4), S.byteAtCell(line, 3, cells).?);
    var spans: [4]L.Span = undefined;
    const hit = L.atByte(line, S.byteAtCell(line, 3, cells).?, &spans) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(hit.kind == .ocapn);
    try std.testing.expectEqualStrings("ocapn://tcp.localhost/x", hit.slice(line));

    // The same cell read as a byte lands on the space and finds nothing, which
    // is what the reader saw underlined but could not click.
    try std.testing.expect(L.atByte(line, 3, &spans) == null);

    // The glyph itself is not a link, and a cell past the end is nowhere.
    try std.testing.expect(L.atByte(line, S.byteAtCell(line, 0, cells).?, &spans) == null);
    try std.testing.expect(S.byteAtCell(line, 99, cells) == null);
}

test "select Selection phase is a sum" {
    const S = cli.repl_select;
    var sel = S.Selection{};
    try std.testing.expect(sel.phase == .idle);
    try std.testing.expect(!sel.highlights());
    sel.phase = .dragging;
    sel.anchors = .{ .a = .{ .col = 1, .row = 2 }, .b = .{ .col = 3, .row = 4 } };
    try std.testing.expect(sel.highlights());
    try std.testing.expectEqual(@as(u16, 2), sel.cellDist(1, 4));
    sel.clear();
    try std.testing.expect(sel.phase == .idle);
}

test "flashForVerb maps CapTP verbs" {
    try std.testing.expect(cli.repl_flash.flashForVerb("publish") == .exports);
    try std.testing.expect(cli.repl_flash.flashForVerb("fetch") == .imports);
    try std.testing.expect(cli.repl_flash.flashForVerb("call") == .answers);
    try std.testing.expect(cli.repl_flash.flashForVerb("tell") == .answers);
    try std.testing.expect(cli.repl_flash.flashForVerb("help") == .none);
}

test "lab Mode help is a real mode not a flag" {
    try std.testing.expect(cli.repl_ecs.Mode.help != .prompt);
}
