//! The rooms browser interface's structural contract.
//!
//! Three rules hold that interface together, and none of them is something a
//! compiler notices. The page draws from one store, so nothing may keep a second
//! copy of the truth in the DOM. The data layer owns a CapTP session that
//! outlives every render, so it must not reach into the tree. And the page's ids
//! and classes are not decoration: the browser proofs select on them, and a
//! renamed class turns those proofs into timeouts that name the wrong thing.
//!
//! Written down, each is a rule someone has to remember. Here they are the
//! build's answer instead. Wired by the source-check driver
//! (`tools/check/source_check.zig`). Selector proofs live in `rooms_ui/selectors.zig`.

const std = @import("std");
const util = @import("util.zig");
const shared = @import("rooms_ui/shared.zig");

const appendViolation = util.appendViolation;
pub const ui_dir = shared.ui_dir;
const keepRoomsSheet = shared.keepRoomsSheet;
pub const loadRoomsCss = shared.loadRoomsCss;
const codeOnly = shared.codeOnly;

pub const checkRoomsSelectors = @import("rooms_ui/selectors.zig").checkRoomsSelectors;
pub const checkRoomsCustomProperties = @import("rooms_ui/tokens.zig").checkRoomsCustomProperties;
pub const checkRoomsCardWidths = @import("rooms_ui/tokens.zig").checkRoomsCardWidths;
pub const checkRoomsTypeRamp = @import("rooms_ui/tokens.zig").checkRoomsTypeRamp;
pub const checkRoomsGapSteps = @import("rooms_ui/tokens.zig").checkRoomsGapSteps;
pub const checkRoomsComposedTokens = @import("rooms_ui/tokens.zig").checkRoomsComposedTokens;
pub const checkRoomsRequestDeadlines = @import("rooms_ui/tokens.zig").checkRoomsRequestDeadlines;

/// Who writes the opening screen's state, for `checkRoomsBootStates`.
const boot_writers = [_][]const u8{ ui_dir ++ "/page.html", ui_dir ++ "/boot.ts" };

/// What a module may not mention, and why it may not.
const Ban = struct {
    file: []const u8,
    needles: []const []const u8,
    because: []const u8,
};

const dom_needles = [_][]const u8{
    "document.",
    "getElementById",
    "querySelector",
    "innerHTML",
    "createElement",
    "classList",
};

const raw_palette_text = [_][]const u8{
    "color: var(--accent-deep)",
    "color: var(--teal-deep)",
};

const retired_icon_button_css = [_][]const u8{
    ".emoji-btn",
    ".send-btn",
    ".topbar .icon",
    ".settings-toggles .icon",
    ".ghost-link",
    ".settings-cancel",
};

const bans = [_]Ban{
    .{
        .file = ui_dir ++ "/net.ts",
        .needles = &dom_needles,
        .because = "the data layer owns a CapTP session that outlives every render, and it stays that way by never reaching into the tree",
    },
    .{
        .file = ui_dir ++ "/store.ts",
        .needles = &dom_needles,
        .because = "the store is the one authority for what the page shows, so reading the page back would make it the second",
    },
    .{
        .file = ui_dir ++ "/types.ts",
        .needles = &dom_needles,
        .because = "the model describes the application, not the document",
    },
    .{
        .file = ui_dir ++ "/text.ts",
        .needles = &dom_needles,
        .because = "these are string functions; anything that builds an element belongs beside the components",
    },
    .{
        .file = ui_dir ++ "/member_identity.ts",
        .needles = &dom_needles,
        .because = "member identity is a pure projection shared by the roster, messages, mentions, and avatars; it must not read the rendered page back",
    },
    .{
        .file = ui_dir ++ "/notify.ts",
        .needles = &dom_needles,
        .because = "whether the tab is being looked at is a store field with one writer",
    },
};

const tree_bans = [_]Ban{
    .{
        .file = ui_dir ++ "/net",
        .needles = &dom_needles,
        .because = "the data layer owns a CapTP session that outlives every render, and it stays that way by never reaching into the tree",
    },
    .{
        .file = ui_dir ++ "/store",
        .needles = &dom_needles,
        .because = "the store is the one authority for what the page shows, so reading the page back would make it the second",
    },
};

fn checkBanSource(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    source: []const u8,
    ban: Ban,
) !void {
    const code = try codeOnly(gpa, source);
    defer gpa.free(code);
    for (ban.needles) |needle| {
        if (std.mem.indexOf(u8, code, needle) != null) {
            try appendViolation(
                gpa,
                violations,
                "{s} mentions `{s}`: {s}",
                .{ path, needle, ban.because },
            );
        }
    }
}

/// The layers that must not touch the document, and the one that must not touch
/// a component.
pub fn checkRoomsLayerBans(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    for (bans) |ban| {
        const source = root.readFileAlloc(io, ban.file, gpa, .limited(1 << 20)) catch {
            try appendViolation(gpa, violations, "{s}: could not read for the DOM ban", .{ban.file});
            continue;
        };
        defer gpa.free(source);
        try checkBanSource(gpa, violations, ban.file, source, ban);
    }

    for (tree_bans) |ban| {
        var dir = root.openDir(io, ban.file, .{ .iterate = true }) catch {
            try appendViolation(gpa, violations, "{s}: could not open for the DOM ban", .{ban.file});
            continue;
        };
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".ts")) continue;
            const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ ban.file, entry.path });
            defer gpa.free(path);
            const source = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch {
                try appendViolation(gpa, violations, "{s}: could not read for the DOM ban", .{path});
                continue;
            };
            defer gpa.free(source);
            try checkBanSource(gpa, violations, path, source, ban);
        }
    }

    const sheets = util.concatDirFiles(io, gpa, root, ui_dir, keepRoomsSheet) catch null;
    if (sheets) |css| {
        defer gpa.free(css);
        const code = try codeOnly(gpa, css);
        defer gpa.free(code);
        for (raw_palette_text) |needle| {
            if (std.mem.indexOf(u8, code, needle) != null) {
                try appendViolation(
                    gpa,
                    violations,
                    "{s} stylesheets mention `{s}`: raw palette arms are decoration, not theme-safe text; readable amber and teal use --accent-ink and --teal-ink",
                    .{ ui_dir, needle },
                );
            }
        }
        for (retired_icon_button_css) |needle| {
            if (std.mem.indexOf(u8, code, needle) != null) {
                try appendViolation(
                    gpa,
                    violations,
                    "{s} stylesheets mention `{s}`: Button and IconButton own control reset, geometry, and state; retired caller-specific baselines must not return",
                    .{ ui_dir, needle },
                );
            }
        }
    }

    // The store's own field is exempt from nothing above, but the one writer of
    // it lives in hooks.ts, which is allowed the document. What net.ts may not
    // do is import a component.
    const net = root.readFileAlloc(io, ui_dir ++ "/net.ts", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}/net.ts: cannot be read for the rooms UI check ({s})", .{ ui_dir, @errorName(err) });
        return;
    };
    defer gpa.free(net);
    const net_code = try codeOnly(gpa, net);
    defer gpa.free(net_code);
    if (std.mem.indexOf(u8, net_code, ".tsx\"") != null) {
        try appendViolation(
            gpa,
            violations,
            "{s}/net.ts imports a component; the interface reads the store, and the data layer must not know the interface exists",
            .{ui_dir},
        );
    }

    try checkRoomsVizStartupOrder(io, gpa, root, violations);
    try checkRoomsJoinDoesNotAskPrivate(io, gpa, root, violations);
}

/// Remembered capability state must exist before the visualizer publisher is
/// armed, and the publisher must be armed before the first local session.
fn checkRoomsVizStartupOrder(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const main_path = ui_dir ++ "/main.tsx";
    const main = root.readFileAlloc(io, main_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: cannot read visualizer startup order ({s})", .{ main_path, @errorName(err) });
        return;
    };
    defer gpa.free(main);
    const restore = std.mem.indexOf(u8, main, "restoreWorkspaceState(");
    const arm = std.mem.indexOf(u8, main, "await net.ensureVizPublisher(");
    const connect = std.mem.indexOf(u8, main, "net.connect(");
    if (restore == null or arm == null or connect == null or !(restore.? < arm.? and arm.? < connect.?)) {
        try appendViolation(gpa, violations, "{s}: local visualizer startup must restore workspace state, arm the remembered capability, then connect", .{main_path});
    }

    const boot_path = ui_dir ++ "/net/runtime_boot.ts";
    const boot = root.readFileAlloc(io, boot_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: cannot read visualizer runtime boot ({s})", .{ boot_path, @errorName(err) });
        return;
    };
    defer gpa.free(boot);
    if (std.mem.indexOf(u8, boot, "ensureVizPublisher") != null) {
        try appendViolation(gpa, violations, "{s}: visualizer capability state is not restored during runtime boot; arm it from main.tsx after workspace restoration", .{boot_path});
    }

    const setup_at = std.mem.indexOf(u8, main, "function showSessionSetup") orelse {
        try appendViolation(gpa, violations, "{s}: session setup is gone", .{main_path});
        return;
    };
    const handoff_at = std.mem.indexOfPos(u8, main, setup_at, "handOffNow();") orelse {
        try appendViolation(gpa, violations, "{s}: session setup has no handoff", .{main_path});
        return;
    };
    const setup = main[setup_at..handoff_at];
    const by_surface = std.mem.indexOf(u8, setup, "PageSurface") != null;
    if (std.mem.indexOf(u8, setup, "RoomsProjectionProvider") == null and !by_surface) {
        try appendViolation(gpa, violations, "{s}: session setup must wrap the page projection; omitting it crashes first paint and detach", .{main_path});
    }
    if (by_surface) {
        const surface_at = std.mem.indexOf(u8, main, "function PageSurface") orelse {
            try appendViolation(gpa, violations, "{s}: PageSurface is used but not defined", .{main_path});
            return;
        };
        // Read the definition itself rather than the text between it and the
        // render that uses it. A function declaration hoists, so moving this
        // one below `showSessionSetup` is legal TypeScript, and a span taken
        // from the later position to the earlier one ends the check in a
        // panic instead of a verdict.
        const surface_end = std.mem.indexOfPos(u8, main, surface_at, "\n}") orelse main.len;
        if (std.mem.indexOf(u8, main[surface_at..surface_end], "RoomsProjectionProvider") == null) {
            try appendViolation(gpa, violations, "{s}: PageSurface must wrap the page projection", .{main_path});
        }
    }
}

/// Modal and Operations controls share one visual grammar.
///
/// A modal's `card-plane` supplies field and button geometry as well as its
/// surface. Operations uses the same components and `.field` class. Letting a
/// caller recreate either locally is how two controls with the same meaning
/// acquire different heights, focus rings, and pending states.
pub fn checkRoomsControlSurfaces(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var dir = root.openDir(io, ui_dir, .{ .iterate = true }) catch {
        try appendViolation(gpa, violations, "{s}: could not open for the shared-control check", .{ui_dir});
        return;
    };
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".tsx")) continue;
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ ui_dir, entry.path });
        defer gpa.free(path);
        const source = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch {
            try appendViolation(gpa, violations, "{s}: could not read for the shared-control check", .{path});
            continue;
        };
        defer gpa.free(source);
        const code = try codeOnly(gpa, source);
        defer gpa.free(code);

        // Inspect string literals individually. A ternary may put two class
        // strings on one line, so a line-wide search would let the good arm
        // conceal the bad one.
        var at: usize = 0;
        while (at < code.len) {
            const quote = code[at];
            if (quote != '"' and quote != '\'' and quote != '`') {
                at += 1;
                continue;
            }
            const start = at + 1;
            at = start;
            while (at < code.len and code[at] != quote) {
                if (code[at] == '\\' and at + 1 < code.len) at += 2 else at += 1;
            }
            const literal = code[start..@min(at, code.len)];
            if (std.mem.indexOf(u8, literal, "modal-card") != null and
                std.mem.indexOf(u8, literal, "card-plane") == null)
            {
                try appendViolation(
                    gpa,
                    violations,
                    "{s} gives a modal `modal-card` without `card-plane`; every modal inherits its surface and control geometry from the shared card plane",
                    .{path},
                );
            }
            at = @min(at + 1, code.len);
        }

        if (!std.mem.startsWith(u8, entry.path, "ops/")) continue;
        if (std.mem.indexOf(u8, code, "<button") != null) {
            try appendViolation(
                gpa,
                violations,
                "{s} draws a raw `<button`; Operations actions use Button or IconButton so size, semantics, focus, and pending feedback stay shared",
                .{path},
            );
        }
        for ([_][]const u8{ "<input", "<select" }) |tag| {
            var found_at: usize = 0;
            while (std.mem.indexOfPos(u8, code, found_at, tag)) |found| {
                const end = std.mem.indexOfPos(u8, code, found, ">") orelse code.len;
                const element = code[found..end];
                if (std.mem.indexOf(u8, element, "className=\"field\"") == null) {
                    try appendViolation(
                        gpa,
                        violations,
                        "{s} draws `{s}` without the shared `field` class; Operations inputs and selects keep one height, focus treatment, and disabled state",
                        .{ path, tag },
                    );
                }
                found_at = @min(end + 1, code.len);
            }
        }
    }
}

/// `/join` of a locator seats from subscribe's listed-ness. Asking `private()`
/// first aborted on an occupancy that has no such method (pancake error -12).
fn checkRoomsJoinDoesNotAskPrivate(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var dir = root.openDir(io, ui_dir, .{ .iterate = true }) catch {
        try appendViolation(gpa, violations, "{s}: could not open to check join does not ask private()", .{ui_dir});
        return;
    };
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".ts") and !std.mem.endsWith(u8, entry.path, ".tsx")) continue;
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ ui_dir, entry.path });
        defer gpa.free(path);
        const source = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch {
            try appendViolation(gpa, violations, "{s}: could not read to check join does not ask private()", .{path});
            continue;
        };
        defer gpa.free(source);
        const code = try codeOnly(gpa, source);
        defer gpa.free(code);
        if (std.mem.indexOf(u8, code, "roomIsPrivate") != null) {
            try appendViolation(
                gpa,
                violations,
                "{s} asks `roomIsPrivate`: /join of a locator seats from subscribe's listed-ness; asking private() first aborts on a room that has no such method",
                .{path},
            );
        }
    }
}

/// The opening screen is drawn for states something actually writes, on an
/// attribute something actually stamps.
///
/// That screen's state machine spans three files with no compiler between them.
/// page.html stamps `data-boot` as the document is parsed and again if the
/// bundle never arrives, ui/boot.ts writes it when the page is running and when
/// it hands the page over, and page.css decides what each of those looks like.
/// Rename a state on either side and the sheet keeps a rule that matches
/// nothing: a screen that never explains itself, or one that never goes away.
/// Rename the attribute and the damage is the other way round, because the
/// sheet asks about its absence too — `:root:not([data-boot])` is how a browser
/// with scripting off is recognised, and against an attribute nobody writes it
/// matches every page, so every reader is told this page needs JavaScript. Both
/// still load, so nothing else notices.
///
/// Only this direction is worth checking. A state the sheet does not draw is no
/// defect: `running` exists to tell the watcher the bundle arrived, and nobody
/// is meant to see it.
pub fn checkRoomsBootStates(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const sheet = (try loadRoomsCss(io, gpa, root, violations)) orelse return;
    defer gpa.free(sheet);

    var written: std.ArrayList(u8) = .empty;
    defer written.deinit(gpa);
    for (boot_writers) |writer| {
        const source = root.readFileAlloc(io, writer, gpa, .limited(1 << 20)) catch {
            try appendViolation(gpa, violations, "{s}: could not be read", .{writer});
            continue;
        };
        defer gpa.free(source);
        try written.appendSlice(gpa, source);
    }

    // The sheet spells it `data-boot`; a script writing it spells the same
    // attribute `dataset.boot`. One name, two syntaxes, so the check has to
    // carry the translation between them.
    if (std.mem.indexOf(u8, sheet, "[data-boot") != null and
        std.mem.indexOf(u8, written.items, "dataset.boot") == null)
    {
        try appendViolation(
            gpa,
            violations,
            "{s} stylesheets key the opening screen on `data-boot`, but neither {s} nor {s} stamps `dataset.boot`; the sheet's absence rule would then match every page and tell every reader this one needs JavaScript",
            .{ ui_dir, boot_writers[0], boot_writers[1] },
        );
    }

    const drawn = "[data-boot=\"";
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, sheet, at, drawn)) |found| {
        const start = found + drawn.len;
        const end = std.mem.indexOfScalarPos(u8, sheet, start, '"') orelse break;
        at = end;
        const quoted = try std.fmt.allocPrint(gpa, "\"{s}\"", .{sheet[start..end]});
        defer gpa.free(quoted);
        if (std.mem.indexOf(u8, written.items, quoted) == null) {
            try appendViolation(
                gpa,
                violations,
                "{s} stylesheets draw the opening screen's {s} state, but neither {s} nor {s} writes it; the rule matches nothing and the screen goes on showing whatever it was showing",
                .{ ui_dir, quoted, boot_writers[0], boot_writers[1] },
            );
        }
    }
}

/// The two buttons the rail's row is built from, which one rule has to style.
const rail_row = [_][]const u8{ ".room-open", ".dm-open" };

/// The rail draws one row, so one rule gives it its shape.
///
/// A room and a direct line are the same object in the same list: a mark, a
/// name, the marks that end the row, and a caption under the name saying which
/// directory it is on. The button that opens each is therefore styled by one
/// rule naming both, and each list adds only its own colour, mark, and badge.
///
/// A second copy is not merely repetition here, it is silently wrong. A row
/// button resets itself with `all: unset`, and that clears grid placement along
/// with everything else, so a copy anywhere later in the sheet un-places the
/// button the earlier rule placed. That is what happened: the direct list kept
/// its own copy some nineteen hundred lines further down, its `all: unset` wiped
/// the placement written up beside the rooms list, and the mark that closes a
/// direct line came to rest a whole line above the row it ends. Both rules
/// parse, both apply, and only their order decides — so nothing but a browser
/// could see it.
///
/// `apps/rooms/test/web/dm_tabs_test.ts` measures that geometry and would catch
/// it again. This catches it at the edit.
pub fn checkRoomsRailRow(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const sheet = (try loadRoomsCss(io, gpa, root, violations)) orelse return;
    defer gpa.free(sheet);
    // Comments name these classes while explaining them, and a comment is not a
    // rule.
    const code = try codeOnly(gpa, sheet);
    defer gpa.free(code);

    var selector_from: usize = 0;
    var styled: usize = 0;
    for (code, 0..) |c, i| switch (c) {
        '}', ';' => selector_from = i + 1,
        '{' => {
            const selector = std.mem.trim(u8, code[selector_from..i], " \t\r\n");
            selector_from = i + 1;
            const room = std.mem.indexOf(u8, selector, rail_row[0]) != null;
            const direct = std.mem.indexOf(u8, selector, rail_row[1]) != null;
            if (!room and !direct) continue;
            styled += 1;
            if (room and direct) continue;
            try appendViolation(
                gpa,
                violations,
                "{s} stylesheets style `{s}` alone in `{s}`; the rail draws one row, so both are named in one rule — a second rule's `all: unset` un-places the button the first one placed",
                .{ ui_dir, if (room) rail_row[0] else rail_row[1], selector },
            );
        },
        else => {},
    };
    if (styled == 0) {
        try appendViolation(
            gpa,
            violations,
            "{s} stylesheets style neither `{s}` nor `{s}`; whatever the rail's row buttons are called now, this check is watching nothing",
            .{ ui_dir, rail_row[0], rail_row[1] },
        );
    }
}

/// One spelling of the layout breakpoint, and a formatter that can see the
/// components.
pub fn checkRoomsConfig(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    // `deno fmt` matches by glob, and `**/*.ts` does not match a `.tsx` file. A
    // gate that passes without checking is worse than no gate: the components
    // went unformatted and the step stayed green.
    if (!(util.fileContains(io, gpa, root, "deno.json", "**/*.tsx") catch false)) {
        try appendViolation(
            gpa,
            violations,
            "deno.json: the formatter's include glob does not name `**/*.tsx`, so every component in the tree sits outside `deno fmt --check` while the step still reports success",
            .{},
        );
    }

    // Motion is a preference, and the rooms sheets say so once, globally. The
    // rule is easy to lose in a stylesheet split, and losing it fails silently:
    // every slide simply plays again for readers who asked it not to.
    if (!(util.fileContains(io, gpa, root, ui_dir ++ "/page.css", "prefers-reduced-motion") catch false)) {
        try appendViolation(
            gpa,
            violations,
            "{s}/page.css: no `prefers-reduced-motion` rule; the rooms sheets animate, so the preference has to be answered somewhere global",
            .{ui_dir},
        );
    }

    // The breakpoint is one number two places have to agree on. A third spelling
    // is how they stop agreeing.
    {
        const page = root.readFileAlloc(io, ui_dir ++ "/page.css", gpa, .limited(1 << 20)) catch {
            try appendViolation(gpa, violations, "{s}/page.css: could not be read", .{ui_dir});
            return;
        };
        defer gpa.free(page);
        var dir = root.openDir(io, ui_dir, .{ .iterate = true }) catch {
            try appendViolation(gpa, violations, "{s}: could not be opened", .{ui_dir});
            return;
        };
        defer dir.close(io);
        var it = dir.iterate();
        while (true) {
            const entry = (it.next(io) catch |err| {
                try appendViolation(
                    gpa,
                    violations,
                    "{s}: failed while listing stylesheets with {s}",
                    .{ ui_dir, @errorName(err) },
                );
                break;
            }) orelse break;
            if (entry.kind == .directory) continue;
            if (!keepRoomsSheet(entry.name)) continue;
            if (std.mem.eql(u8, entry.name, "page.css")) continue;
            const needle = try std.fmt.allocPrint(gpa, "@import url(\"{s}\")", .{entry.name});
            defer gpa.free(needle);
            if (std.mem.indexOf(u8, page, needle) == null) {
                try appendViolation(
                    gpa,
                    violations,
                    "{s}/page.css does not import {s}; the browser would never load that sheet",
                    .{ ui_dir, entry.name },
                );
            }
        }
    }
    const homes = [_][]const u8{ui_dir ++ "/store/core.ts"};
    var found: usize = 0;
    if (util.fileContains(io, gpa, root, homes[0], "820px") catch false) found += 1;
    const sheets = util.concatDirFiles(io, gpa, root, ui_dir, keepRoomsSheet) catch null;
    const css_has = if (sheets) |css| blk: {
        defer gpa.free(css);
        break :blk std.mem.indexOf(u8, css, "820px") != null;
    } else false;
    if (found != 1 or !css_has) {
        try appendViolation(
            gpa,
            violations,
            "the layout breakpoint must be spelled in both {s} and the rooms stylesheets; they are two places that have to agree",
            .{homes[0]},
        );
    }
    // Comments may cross-reference the number freely; what must not exist is a
    // third place that *decides* with it.
    for ([_][]const u8{ ui_dir ++ "/hooks.ts", ui_dir ++ "/Composer.tsx", ui_dir ++ "/App.tsx" }) |elsewhere| {
        const source = root.readFileAlloc(io, elsewhere, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: cannot be read for the rooms UI check ({s})", .{ elsewhere, @errorName(err) });
            continue;
        };
        defer gpa.free(source);
        const code = try codeOnly(gpa, source);
        defer gpa.free(code);
        if (std.mem.indexOf(u8, code, "820px") != null) {
            try appendViolation(
                gpa,
                violations,
                "{s} spells the layout breakpoint; it belongs in the store beside the field it decides, and in the rooms stylesheets",
                .{elsewhere},
            );
        }
    }
}
