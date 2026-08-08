//! The rooms browser interface's structural contract.
//!
//! Three rules hold that interface together, and none of them is something a
//! compiler notices. The page draws from one store, so nothing may keep a second
//! copy of the truth in the DOM. The data layer owns a CapTP session that
//! outlives every render, so it must not reach into the tree. And the page's ids
//! and classes are not decoration: six browser proofs select on them, and a
//! renamed class turns those proofs into timeouts that name the wrong thing.
//!
//! Written down, each is a rule someone has to remember. Here they are the
//! build's answer instead. Wired by the meta-check driver
//! (`tools/check/meta_check.zig`).

const std = @import("std");
const util = @import("util.zig");

const appendViolation = util.appendViolation;

/// A selector the interface promises to emit and a proof depends on.
///
/// Both directions matter. A literal no component emits is a proof about to fail
/// for a reason that has nothing to do with what it tests; a literal no proof
/// uses is rent, and should be retired rather than carried.
const Selector = struct {
    /// The exact text a component writes, as it appears in the JSX.
    literal: []const u8,
    /// The proof that would break, and what it would look like when it did.
    proven_by: []const u8,
};

const selectors = [_]Selector{
    .{ .literal = "id=\"log\"", .proven_by = "apps/rooms/test/web_page_test.ts" },
    .{ .literal = "id=\"line\"", .proven_by = "apps/rooms/test/web_page_test.ts" },
    .{ .literal = "id=\"nick\"", .proven_by = "apps/rooms/test/web_page_test.ts" },
    .{ .literal = "id=\"room\"", .proven_by = "apps/rooms/test/web_page_test.ts" },
    .{ .literal = "id=\"joinBtn\"", .proven_by = "apps/rooms/test/web_page_test.ts" },
    .{ .literal = "id=\"status\"", .proven_by = "apps/rooms/test/web_relay_peer_test.ts" },
    .{ .literal = "id=\"backBtn\"", .proven_by = "apps/rooms/test/web_page_test.ts" },
    .{ .literal = "id=\"railToggle\"", .proven_by = "apps/rooms/test/web_page_test.ts" },
    .{ .literal = "id=\"membersToggle\"", .proven_by = "apps/rooms/test/web_page_test.ts" },
    .{ .literal = "id=\"members\"", .proven_by = "apps/rooms/test/web_page_test.ts" },
    .{ .literal = "listId=\"dmList\"", .proven_by = "apps/rooms/test/web_dm_retarget_test.ts" },
    .{ .literal = "\"bubble\"", .proven_by = "apps/rooms/test/web_page_test.ts" },
    .{ .literal = "\"dm-open\"", .proven_by = "apps/rooms/test/web_dm_retarget_test.ts" },
    .{ .literal = "\"dm-btn\"", .proven_by = "apps/rooms/test/web_page_test.ts" },
    // The mark in the title ends whatever is on screen: it leaves a room, and it
    // closes a direct line. The two-tab proof closes a conversation with it and
    // then checks the member is still reachable, so a rename here would report
    // as "the members list stopped offering a direct line" — a claim about the
    // roster, made by a button that moved.
    .{ .literal = "id=\"leaveBtn\"", .proven_by = "apps/rooms/test/web_dm_tabs_test.ts" },
    .{ .literal = "show-list", .proven_by = "apps/rooms/test/web_page_test.ts" },
    .{ .literal = "members-open", .proven_by = "apps/rooms/test/web_page_test.ts" },
    // The opening screen is written in the document rather than by a component,
    // which is what lets it paint before the bundle exists. The proof watches
    // both of its faces from the first frame, so the names are load-bearing in
    // the same way every name above is.
    .{ .literal = "id=\"boot\"", .proven_by = "apps/rooms/test/web_page_test.ts" },
    .{ .literal = "class=\"boot-wait\"", .proven_by = "apps/rooms/test/web_page_test.ts" },
    .{ .literal = "class=\"boot-explain\"", .proven_by = "apps/rooms/test/web_page_test.ts" },
};

/// Who writes the opening screen's state, for `checkRoomsBootStates`.
const boot_writers = [_][]const u8{ ui_dir ++ "/page.html", ui_dir ++ "/boot.ts" };

const ui_dir = "apps/rooms/web/ui";

/// Every load-bearing selector is still emitted, and still proven.
pub fn checkRoomsSelectors(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const drawn = try readUiSources(io, gpa, root, violations) orelse return;
    defer gpa.free(drawn);

    for (selectors) |selector| {
        if (std.mem.indexOf(u8, drawn, selector.literal) == null) {
            try appendViolation(
                gpa,
                violations,
                "{s}: no component emits `{s}`, but {s} selects on it; that proof would fail as a timeout naming the wrong thing",
                .{ ui_dir, selector.literal, selector.proven_by },
            );
        }
        const proof = root.readFileAlloc(io, selector.proven_by, gpa, .limited(1 << 20)) catch {
            try appendViolation(gpa, violations, "{s} is named as the proof for `{s}` but could not be read", .{ selector.proven_by, selector.literal });
            continue;
        };
        defer gpa.free(proof);
        // The proof spells a selector without the JSX attribute syntax around it,
        // so compare on the name itself.
        const bare = bareName(selector.literal);
        if (std.mem.indexOf(u8, proof, bare) == null) {
            try appendViolation(
                gpa,
                violations,
                "{s} no longer selects on `{s}`; retire the row in tools/check/meta_check/rooms_ui.zig rather than carrying a selector nothing proves",
                .{ selector.proven_by, bare },
            );
        }
    }
}

/// `id="log"`, `listId="dmList"`, and `"bubble"` name `log`, `dmList`, and
/// `bubble`. The literal is matched as the component actually writes it, so a
/// rename fails here; the proof spells the name alone.
fn bareName(literal: []const u8) []const u8 {
    var name = literal;
    if (std.mem.indexOfScalar(u8, name, '=')) |at| name = name[at + 1 ..];
    if (std.mem.startsWith(u8, name, "\"")) name = name[1..];
    if (std.mem.endsWith(u8, name, "\"")) name = name[0 .. name.len - 1];
    return name;
}

/// The source with its comments removed.
///
/// A ban that fires on prose is a ban people learn to write around, and these
/// modules explain themselves at length — the store's own header names
/// `document.hidden` to say which module reads it. Strings are stepped over so a
/// quoted `//` does not start a comment. It errs toward keeping too little
/// rather than too much: an over-strip makes a ban miss, which is a check that
/// under-reports, and a false alarm is the failure that costs a gate its
/// authority.
fn codeOnly(gpa: std.mem.Allocator, source: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    var quote: u8 = 0;
    while (i < source.len) {
        const c = source[i];
        if (quote != 0) {
            try out.append(gpa, c);
            if (c == '\\' and i + 1 < source.len) {
                try out.append(gpa, source[i + 1]);
                i += 2;
                continue;
            }
            if (c == quote) quote = 0;
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'' or c == '`') {
            quote = c;
            try out.append(gpa, c);
            i += 1;
            continue;
        }
        if (c == '/' and i + 1 < source.len and source[i + 1] == '/') {
            while (i < source.len and source[i] != '\n') i += 1;
            continue;
        }
        if (c == '/' and i + 1 < source.len and source[i + 1] == '*') {
            i += 2;
            while (i + 1 < source.len and !(source[i] == '*' and source[i + 1] == '/')) i += 1;
            i = @min(i + 2, source.len);
            continue;
        }
        try out.append(gpa, c);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

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
        .file = ui_dir ++ "/notify.ts",
        .needles = &dom_needles,
        .because = "whether the tab is being looked at is a store field with one writer",
    },
};

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
        const code = try codeOnly(gpa, source);
        defer gpa.free(code);
        for (ban.needles) |needle| {
            if (std.mem.indexOf(u8, code, needle) != null) {
                try appendViolation(
                    gpa,
                    violations,
                    "{s} mentions `{s}`: {s}",
                    .{ ban.file, needle, ban.because },
                );
            }
        }
    }

    // The store's own field is exempt from nothing above, but the one writer of
    // it lives in hooks.ts, which is allowed the document. What net.ts may not
    // do is import a component.
    const net = root.readFileAlloc(io, ui_dir ++ "/net.ts", gpa, .limited(1 << 20)) catch return;
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
    const sheet = root.readFileAlloc(io, ui_dir ++ "/page.css", gpa, .limited(1 << 20)) catch {
        try appendViolation(gpa, violations, "{s}/page.css: could not be read", .{ui_dir});
        return;
    };
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
            "{s}/page.css keys the opening screen on `data-boot`, but neither {s} nor {s} stamps `dataset.boot`; the sheet's absence rule would then match every page and tell every reader this one needs JavaScript",
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
                "{s}/page.css draws the opening screen's {s} state, but neither {s} nor {s} writes it; the rule matches nothing and the screen goes on showing whatever it was showing",
                .{ ui_dir, quoted, boot_writers[0], boot_writers[1] },
            );
        }
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

    // The breakpoint is one number two files have to agree on. A third spelling
    // is how they stop agreeing.
    const homes = [_][]const u8{ ui_dir ++ "/page.css", ui_dir ++ "/store.ts" };
    var found: usize = 0;
    for (homes) |home| {
        if (util.fileContains(io, gpa, root, home, "820px") catch false) found += 1;
    }
    if (found != homes.len) {
        try appendViolation(
            gpa,
            violations,
            "the layout breakpoint must be spelled in both {s} and {s}; they are two files that have to agree",
            .{ homes[0], homes[1] },
        );
    }
    // Comments may cross-reference the number freely; what must not exist is a
    // third place that *decides* with it.
    for ([_][]const u8{ ui_dir ++ "/hooks.ts", ui_dir ++ "/Composer.tsx", ui_dir ++ "/App.tsx" }) |elsewhere| {
        const source = root.readFileAlloc(io, elsewhere, gpa, .limited(1 << 20)) catch continue;
        defer gpa.free(source);
        const code = try codeOnly(gpa, source);
        defer gpa.free(code);
        if (std.mem.indexOf(u8, code, "820px") != null) {
            try appendViolation(
                gpa,
                violations,
                "{s} spells the layout breakpoint; it belongs in store.ts beside the field it decides, and in page.css",
                .{elsewhere},
            );
        }
    }
}

/// Every `.tsx` and `.ts` under the interface, and the document they mount into,
/// concatenated, so a selector can be looked for once rather than per file. The
/// document is in here because the opening screen is drawn there rather than by
/// a component, and a proof selects on it just the same.
fn readUiSources(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !?[]u8 {
    var dir = root.openDir(io, ui_dir, .{ .iterate = true }) catch {
        try appendViolation(gpa, violations, "{s}: could not be opened", .{ui_dir});
        return null;
    };
    defer dir.close(io);

    var all: std.ArrayList(u8) = .empty;
    errdefer all.deinit(gpa);
    var walker = dir.iterate();
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const tsx = std.mem.endsWith(u8, entry.name, ".tsx");
        const document = std.mem.eql(u8, entry.name, "page.html");
        if (!tsx and !document and !std.mem.endsWith(u8, entry.name, ".ts")) continue;
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ ui_dir, entry.name });
        defer gpa.free(path);
        const source = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch continue;
        defer gpa.free(source);
        try all.appendSlice(gpa, source);
    }
    return try all.toOwnedSlice(gpa);
}
