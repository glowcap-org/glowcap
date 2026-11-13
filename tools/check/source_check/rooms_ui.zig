//! The rooms browser interface's structural contract.
//!
//! A few rules hold that interface together, and none is something a compiler
//! notices. The page draws from one store, so nothing may keep a second copy of
//! the truth in the DOM, and the data layer owns a CapTP session that outlives
//! every render, so it must not reach into the tree. Shared controls keep one
//! visual grammar, the opening screen's states have a writer, the stylesheet
//! imports are complete, and the layout breakpoint is one number the store and
//! the stylesheet agree on.
//!
//! Written down, each is a rule someone has to remember. Here they are the
//! build's answer instead. Wired by the source-check driver
//! (`tools/check/source_check.zig`).

const std = @import("std");
const violation_log = @import("violation_log.zig");
const ui_sources = @import("rooms_ui/ui_sources.zig");

const appendViolation = violation_log.appendViolation;
pub const ui_dir = ui_sources.ui_dir;
const keepRoomsSheet = ui_sources.keepRoomsSheet;
pub const loadRoomsCss = ui_sources.loadRoomsCss;
const codeOnly = ui_sources.codeOnly;

pub const checkRoomsTextCatalog = @import("rooms_ui/text_catalog.zig").checkRoomsTextCatalog;
pub const checkRoomsTextVoice = @import("rooms_ui/text_voice.zig").checkRoomsTextVoice;
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

const bans = [_]Ban{
    .{
        .file = ui_dir ++ "/session/managed/projection.ts",
        .needles = &dom_needles,
        .because = "Rust observations update the presentation store without reading the DOM",
    },
    .{
        .file = ui_dir ++ "/store.ts",
        .needles = &dom_needles,
        .because = "the store is the one authority for what the page shows, so reading the page back would make it the second",
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
        if (std.mem.find(u8, code, needle) != null) {
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
            const path = try gpa.print("{s}/{s}", .{ ban.file, entry.path });
            defer gpa.free(path);
            const source = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch {
                try appendViolation(gpa, violations, "{s}: could not read for the DOM ban", .{path});
                continue;
            };
            defer gpa.free(source);
            try checkBanSource(gpa, violations, path, source, ban);
        }
    }

    // The store's own field is exempt from nothing above, but the one writer of
    // it lives in hooks.ts, which is allowed the document. What the projection may not
    // do is import a component.
    const net = root.readFileAlloc(io, ui_dir ++ "/session/managed/projection.ts", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}/session/managed/projection.ts: cannot be read for the rooms UI check ({s})", .{ ui_dir, @errorName(err) });
        return;
    };
    defer gpa.free(net);
    const net_code = try codeOnly(gpa, net);
    defer gpa.free(net_code);
    if (std.mem.find(u8, net_code, ".tsx\"") != null) {
        try appendViolation(
            gpa,
            violations,
            "{s}/session/managed/projection.ts imports a component; the interface reads the store, and the data layer must not know the interface exists",
            .{ui_dir},
        );
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
        const path = try gpa.print("{s}/{s}", .{ ui_dir, entry.path });
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
            if (std.mem.find(u8, literal, "modal-card") != null and
                std.mem.find(u8, literal, "card-plane") == null)
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
        if (std.mem.find(u8, code, "<button") != null) {
            try appendViolation(
                gpa,
                violations,
                "{s} draws a raw `<button`; Operations actions use Button or IconButton so size, semantics, focus, and pending feedback stay shared",
                .{path},
            );
        }
        for ([_][]const u8{ "<input", "<select" }) |tag| {
            var found_at: usize = 0;
            while (std.mem.findPos(u8, code, found_at, tag)) |found| {
                const end = std.mem.findPos(u8, code, found, ">") orelse code.len;
                const element = code[found..end];
                if (std.mem.find(u8, element, "className=\"field\"") == null) {
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

/// The opening screen is drawn for states something writes, on an
/// attribute something stamps.
///
/// That screen's state machine spans three files with no compiler between them.
/// page.html stamps `data-boot` as the document is parsed and again if the
/// bundle never arrives, ui/boot.ts writes it when the page is running and when
/// it hands the page over, and page.css decides what each of those looks like.
/// Rename a state on either side and the sheet keeps a rule that matches
/// nothing: a screen that never explains itself, or one that never goes away.
/// Rename the attribute and the damage is the other way round, because the
/// sheet asks about its absence too, `:root:not([data-boot])` is how a browser
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
    if (std.mem.find(u8, sheet, "[data-boot") != null and
        std.mem.find(u8, written.items, "dataset.boot") == null)
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
    while (std.mem.findPos(u8, sheet, at, drawn)) |found| {
        const start = found + drawn.len;
        const end = std.mem.findScalarPos(u8, sheet, start, '"') orelse break;
        at = end;
        const quoted = try gpa.print("\"{s}\"", .{sheet[start..end]});
        defer gpa.free(quoted);
        if (std.mem.find(u8, written.items, quoted) == null) {
            try appendViolation(
                gpa,
                violations,
                "{s} stylesheets draw the opening screen's {s} state, but neither {s} nor {s} writes it; the rule matches nothing and the screen goes on showing whatever it was showing",
                .{ ui_dir, quoted, boot_writers[0], boot_writers[1] },
            );
        }
    }
}

/// The stylesheet import list, and one number for the layout breakpoint.
///
/// `page.css` is the only sheet the browser loads, so a sheet it does not
/// import is dead. The store's `mobileQuery` and the layout `@media` block in
/// `stream.css` are two spellings of the same breakpoint, and they have to
/// agree.
pub fn checkRoomsConfig(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
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
            const needle = try gpa.print("@import url(\"{s}\")", .{entry.name});
            defer gpa.free(needle);
            if (std.mem.find(u8, page, needle) == null) {
                try appendViolation(
                    gpa,
                    violations,
                    "{s}/page.css does not import {s}; the browser would never load that sheet",
                    .{ ui_dir, entry.name },
                );
            }
        }
    }

    const store_path = ui_dir ++ "/store/projection.ts";
    const sheet_path = ui_dir ++ "/stream.css";
    const store = root.readFileAlloc(io, store_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: cannot be read for the layout breakpoint ({s})", .{ store_path, @errorName(err) });
        return;
    };
    defer gpa.free(store);
    const sheet = root.readFileAlloc(io, sheet_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: cannot be read for the layout breakpoint ({s})", .{ sheet_path, @errorName(err) });
        return;
    };
    defer gpa.free(sheet);
    const store_code = try codeOnly(gpa, store);
    defer gpa.free(store_code);
    const sheet_code = try codeOnly(gpa, sheet);
    defer gpa.free(sheet_code);
    const in_store = breakpointPx(store_code, store_media_marker);
    const in_sheet = breakpointPx(sheet_code, sheet_media_marker);
    if (in_store == null or in_sheet == null or in_store.? != in_sheet.?) {
        try appendViolation(
            gpa,
            violations,
            "the layout breakpoint must be one number: {s} `mobileQuery` says {?d}px and the {s} layout `@media` block says {?d}px; they are two places that have to agree",
            .{ store_path, in_store, sheet_path, in_sheet },
        );
    }
}

/// What opens the store's breakpoint, up to the number.
const store_media_marker = "mobileQuery = matchMedia(\"(max-width:";

/// What opens the stylesheet's layout block, up to the number.
const sheet_media_marker = "@media (max-width:";

/// The pixel count written right after the first `marker`, or null when the
/// marker is absent or no whole `<digits>px` follows it.
fn breakpointPx(code: []const u8, marker: []const u8) ?u32 {
    const at = std.mem.find(u8, code, marker) orelse return null;
    const rest = std.mem.trimStart(u8, code[at + marker.len ..], " ");
    var end: usize = 0;
    while (end < rest.len and std.ascii.isDigit(rest[end])) end += 1;
    if (end == 0 or !std.mem.startsWith(u8, rest[end..], "px")) return null;
    return std.fmt.parseInt(u32, rest[0..end], 10) catch null;
}

test "breakpointPx reads the number after a media marker" {
    try std.testing.expectEqual(@as(?u32, 820), breakpointPx("@media (max-width: 820px) {", sheet_media_marker));
    try std.testing.expectEqual(@as(?u32, 820), breakpointPx("const mobileQuery = matchMedia(\"(max-width: 820px)\");", store_media_marker));
    try std.testing.expectEqual(@as(?u32, null), breakpointPx("@media (max-width: 34rem) {", sheet_media_marker));
    try std.testing.expectEqual(@as(?u32, null), breakpointPx("@media (hover: none) {", sheet_media_marker));
}
