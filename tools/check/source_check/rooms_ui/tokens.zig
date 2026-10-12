//! Every custom property the rooms stylesheets read is one some file writes.
//!
//! A `var(--name)` naming nothing is not a CSS error and does not fall back to
//! the value it replaced. The whole declaration becomes invalid at computed
//! value time, so the property takes its initial value: a background goes
//! transparent, a colour goes black, a radius goes square. The page still
//! draws, the build still passes, and what a reader meets is a surface that
//! quietly lost its fill.
//!
//! A `var(--name, fallback)` is not this: it says what to do when the name is
//! missing, so it is read and skipped.
//!
//! What a green run here means, measured by breaking the code rather than
//! assumed. It was validated against a name written nowhere at all, a typo in
//! a `var()`, or a token deleted out from under its readers, and it catches
//! that.
//!
//! It does **not** reach the case it was first written for, and that was
//! measured too: a property defined on one plane and read by a well standing
//! on another. This reads the sheets as one text, so a definition anywhere
//! counts as a definition everywhere, and the half-applied edit that left
//! every modal well transparent while `.ops-panel` still named the property
//! passed here green. Whether a definition reaches a given element is the
//! cascade's answer, and only a browser computes it, so that case is measured
//! in the page proof instead (`apps/rooms/test/page/operations.ts` reads the
//! computed background of every well). Do not widen this file toward it. A
//! stylesheet read as text cannot answer it.

const std = @import("std");
const util = @import("../util.zig");
const shared = @import("shared.zig");

const appendViolation = util.appendViolation;
const ui_dir = shared.ui_dir;

fn keepAnySheet(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".css");
}

/// Whether a byte can appear inside a custom property's name.
fn nameByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
}

/// Collect every `--name` written immediately before a colon: a declaration in
/// a stylesheet, and the same shape in the inline styles a component sets.
fn collectDefined(gpa: std.mem.Allocator, source: []const u8, out: *std.StringHashMapUnmanaged(void)) !void {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, source, at, "--")) |start| {
        var end = start + 2;
        while (end < source.len and nameByte(source[end])) end += 1;
        at = end;
        if (end == start + 2) continue;
        // A component writes `"--rail-w": value` or `--rail-w: value`; both
        // reach the colon past optional quoting and space.
        var scan = end;
        if (scan < source.len and (source[scan] == '"' or source[scan] == '\'')) scan += 1;
        while (scan < source.len and (source[scan] == ' ' or source[scan] == '\t')) scan += 1;
        if (scan >= source.len or source[scan] != ':') continue;
        try out.put(gpa, source[start..end], {});
    }
}

/// Every custom property a stylesheet reads with no fallback beside it.
fn collectUsed(gpa: std.mem.Allocator, css: []const u8, out: *std.StringHashMapUnmanaged(void)) !void {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, css, at, "var(")) |open| {
        var scan = open + 4;
        while (scan < css.len and (css[scan] == ' ' or css[scan] == '\t' or css[scan] == '\n')) scan += 1;
        at = scan;
        if (scan + 2 >= css.len or css[scan] != '-' or css[scan + 1] != '-') continue;
        var end = scan + 2;
        while (end < css.len and nameByte(css[end])) end += 1;
        var after = end;
        while (after < css.len and (after < css.len and (css[after] == ' ' or css[after] == '\t'))) after += 1;
        at = end;
        // A fallback answers for itself.
        if (after < css.len and css[after] == ',') continue;
        try out.put(gpa, css[scan..end], {});
    }
}

/// Two things stand apart by one of the named spacing steps.
///
/// Nineteen values were doing this across the cards and the operations panes
/// alone, nine of them inside ten pixels of each other: three distances for
/// "one group from the next", which is three authors' eyes rather than a
/// decision. The steps in `page.css` are the decision, and a rule names the
/// relationship it is spacing rather than a number that looked right.
///
/// A length that is not layout spacing is not this. The wordmark's letterfit
/// is the one, and it says so where it is written. It is also the only
/// fractional one, and this reads that to tell them apart.
///
/// Measured by breaking the code: a rule given its own `gap` is caught and
/// named, so is one given its own `column-gap`, and the letterfit stays quiet
/// through both. The exemption is a fraction rather than a file or a selector,
/// so a second type-fitting length gets it by being one, and a layout gap
/// cannot buy it by moving.
pub fn checkRoomsGapSteps(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const css = (util.concatDirFiles(io, gpa, root, ui_dir, keepAnySheet) catch null) orelse {
        try appendViolation(gpa, violations, "{s}: could not read the rooms stylesheets", .{ui_dir});
        return;
    };
    defer gpa.free(css);
    const code = try shared.codeOnly(gpa, css);
    defer gpa.free(code);

    var named: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, code, at, "gap:")) |found| {
        at = found + 4;
        // `row-gap:` and `column-gap:` are this too; `--gap-row:` is the step
        // being declared, not a use of one.
        if (found > 0 and (code[found - 1] == '-' or std.ascii.isAlphabetic(code[found - 1]))) {
            const before = code[0..found];
            const dash = std.mem.lastIndexOfScalar(u8, before, '-') orelse continue;
            if (dash + 1 != found) continue;
            const word_from = if (std.mem.lastIndexOfAny(u8, before[0..dash], " \t\n;{")) |w| w + 1 else 0;
            const word = before[word_from..dash];
            if (!std.mem.eql(u8, word, "row") and !std.mem.eql(u8, word, "column")) continue;
        }
        const rest = code[at..];
        const end = std.mem.indexOfScalar(u8, rest, ';') orelse continue;
        const value = std.mem.trim(u8, rest[0..end], " \t\r\n");
        // A gap set through a step is the state this check exists to reach, so
        // it counts as watched: with only pixel gaps counted, the day the last
        // pixel gap became a step or an em the guard below fired on success.
        if (std.mem.indexOf(u8, value, "var(--gap-") != null) {
            named += 1;
            continue;
        }
        if (std.mem.indexOf(u8, value, "px") == null) continue;
        named += 1;
        // A fraction is type fitting rather than layout, and says so at its site.
        if (std.mem.indexOfScalar(u8, value, '.') != null) continue;
        try appendViolation(
            gpa,
            violations,
            "{s}: a gap of `{s}` names its own number; two things stand apart by one of the `--gap-*` steps in page.css, because a number chosen at each site is how nineteen of them came to do four jobs",
            .{ ui_dir, value },
        );
    }
    if (named == 0) {
        try appendViolation(
            gpa,
            violations,
            "{s}: no gap is set in pixels or through a `--gap-*` step; whatever spacing is written as now, this check is watching nothing",
            .{ui_dir},
        );
    }
}

/// Every request the rooms client makes carries a deadline.
///
/// A partner that stays connected and never answers is not a failure anything
/// reports: the send is in flight, the session is open, and the promise is
/// pending, so a wait without a bound is a wait for the life of the tab. That
/// reasoning is written at `apps/rooms/lib/deadline.ts`, and `ask()` is the one
/// helper that carries it, but a `send` in a lifecycle method is not a verb
/// and does not pass through `ask`, which is how the room goodbye came to have
/// no bound. Its cleanup sat in the `finally` behind that send, so a room that
/// never answered held the membership's references and its stream.
///
/// So the rule is about the send rather than the verb: one that is not raced
/// against something says so where it stands. `void`-ed sends are excluded,
/// nothing is waiting on those, and the deadline module itself is where the
/// racing is written.
///
/// Measured by making it: taking the bound off the goodbye turns this red, and
/// the fire-and-forget reply stays green.
pub fn checkRoomsRequestDeadlines(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const dir_path = "apps/rooms/lib";
    var dir = root.openDir(io, dir_path, .{ .iterate = true }) catch {
        try appendViolation(gpa, violations, "{s}: could not be opened", .{dir_path});
        return;
    };
    defer dir.close(io);

    var seen: usize = 0;
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".ts")) continue;
        // Where the racing itself is written, and the helper every verb uses.
        if (std.mem.eql(u8, entry.basename, "deadline.ts")) continue;
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, entry.path });
        defer gpa.free(path);
        const body = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch {
            try appendViolation(gpa, violations, "{s}: could not read {s}", .{ dir_path, entry.path });
            return;
        };
        defer gpa.free(body);

        var at: usize = 0;
        while (std.mem.indexOfPos(u8, body, at, "session.send(")) |found| {
            at = found + 13;
            seen += 1;
            // Wide enough to reach the top of the method the send is in: a
            // deadline armed before the request is still that request's
            // deadline, which is how the registration acknowledgement is
            // written and how it was first misread here.
            const from = if (found > 1600) found - 1600 else 0;
            const before = body[from..found];
            if (std.mem.indexOf(u8, before, "Within(") != null) continue;
            if (std.mem.indexOf(u8, before, "setTimeout(") != null) continue;
            // Nothing is waiting on a send that was handed to no one.
            const line_from = std.mem.lastIndexOfScalar(u8, before, '\n') orelse 0;
            if (std.mem.indexOf(u8, before[line_from..], "void ") != null) continue;
            const after_from = found;
            const after_to = @min(body.len, found + 700);
            const after = body[after_from..after_to];
            if (std.mem.indexOf(u8, after, "Promise.race(") != null) continue;
            if (std.mem.indexOf(u8, after, "setTimeout(") != null) continue;
            const line = std.mem.count(u8, body[0..found], "\n") + 1;
            try appendViolation(
                gpa,
                violations,
                "{s}/{s}:{d}: a request is sent with nothing to end the wait; every one carries a deadline, because a partner that stays connected and never answers reports no failure at all",
                .{ dir_path, entry.path, line },
            );
        }
    }
    if (seen == 0) {
        try appendViolation(
            gpa,
            violations,
            "{s}: no requests found; whatever the client sends with now, this check is watching nothing",
            .{dir_path},
        );
    }
}

/// A token composed from another is used where it was composed.
///
/// `--ring` is built at the root out of `--ring-hue`, and a rule that set its
/// own `--ring-hue` beside `box-shadow: var(--ring)` looked exactly like it
/// worked: the property was set, it read back correctly on the element, and
/// the shadow drew the root's colour anyway. A custom property is substituted
/// where it is composed, so a hue supplied further down arrives after the
/// colour has been chosen. Three bands asked for a refusal's red or a
/// directory's mark and drew the accent, and nothing anywhere said so.
///
/// So the hues are named at the root, and setting one at a use site is the
/// mistake this refuses. Measured by making it: reintroducing the pair turns
/// this red, and a rule naming one of the composed bands stays green.
pub fn checkRoomsComposedTokens(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const css = (util.concatDirFiles(io, gpa, root, ui_dir, keepAnySheet) catch null) orelse {
        try appendViolation(gpa, violations, "{s}: could not read the rooms stylesheets", .{ui_dir});
        return;
    };
    defer gpa.free(css);
    const code = try shared.codeOnly(gpa, css);
    defer gpa.free(code);

    var bands: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, code, at, "var(--ring")) |found| {
        at = found + 4;
        bands += 1;
    }
    if (bands == 0) {
        try appendViolation(
            gpa,
            violations,
            "{s}: nothing reads a `--ring*` band; whatever the focus band is called now, this check is watching nothing",
            .{ui_dir},
        );
    }
    at = 0;
    while (std.mem.indexOfPos(u8, code, at, "--ring-hue")) |found| {
        at = found + 10;
        // A declaration of it, not a mention: the colon is what makes it one.
        var scan = at;
        while (scan < code.len and (code[scan] == ' ' or code[scan] == '\t')) scan += 1;
        if (scan >= code.len or code[scan] != ':') continue;
        try appendViolation(
            gpa,
            violations,
            "{s}: a rule sets `--ring-hue`, which the band it feeds was already composed without; name one of the `--ring*` bands in page.css instead, or write the shadow out where a hue is only known on the element",
            .{ui_dir},
        );
    }
}

/// A card standing on a backdrop takes one of the named width steps.
///
/// Card widths written where each card is drawn drift: pairs twenty and sixty
/// pixels apart are a difference no reader takes for a decision, and some give
/// no reason at all. The steps in `page.css` are the decision, and a card names
/// the one its contents ask for.
///
/// It reads the selector, so it holds the cards and lets the pages and the
/// bars past: a page is not a card on a backdrop and answers to nothing here.
///
/// Measured by breaking the code. A card given its own pixel width is caught
/// and named. A width set on something standing inside a card is not, which is
/// right: `.modal-card .launch` dresses a row, not the card it sits in.
///
/// The sentinel is weaker than it reads, and that was measured too: renaming
/// one card family leaves the others setting widths, so the count stays above
/// zero and this stays green. It fires only when nothing at all is left that
/// it recognises. Naming `.modal-card` outright would close that and is worse
/// ,  a banned old spelling is a tombstone, and the general shape is what earns
/// its rent here.
pub fn checkRoomsCardWidths(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const css = (util.concatDirFiles(io, gpa, root, ui_dir, keepAnySheet) catch null) orelse {
        try appendViolation(gpa, violations, "{s}: could not read the rooms stylesheets", .{ui_dir});
        return;
    };
    defer gpa.free(css);
    const code = try shared.codeOnly(gpa, css);
    defer gpa.free(code);

    var held: usize = 0;
    var selector_from: usize = 0;
    for (code, 0..) |c, i| switch (c) {
        '}', ';' => selector_from = i + 1,
        '{' => {
            const selector = std.mem.trim(u8, code[selector_from..i], " \t\r\n");
            selector_from = i + 1;
            if (!namesACard(selector)) continue;
            const close = std.mem.indexOfPos(u8, code, i, "}") orelse code.len;
            const value = ownWidthValue(code[i..close]) orelse continue;
            held += 1;
            if (std.mem.indexOf(u8, value, "var(--card-") != null) continue;
            try appendViolation(
                gpa,
                violations,
                "{s}: `{s}` sets its own width; a card on a backdrop names one of the `--card-*` steps in page.css, because a width written at each card is how seven of them accumulated with four giving no reason",
                .{ ui_dir, selector },
            );
        },
        else => {},
    };
    if (held == 0) {
        try appendViolation(
            gpa,
            violations,
            "{s}: no card sets a width; whatever the cards are called now, this check is watching nothing",
            .{ui_dir},
        );
    }
}

/// Whether a rule dresses a card itself rather than something standing in one.
///
/// The last compound is what the rule lands on, so `.modal-card .launch` is a
/// row inside a card and `.modal-card.conversation-card` is the card. `.modal`
/// alone is the backdrop, which is the window and not the card in it.
fn namesACard(selector: []const u8) bool {
    var last = selector;
    for ([_]u8{ ' ', '>', '+', '~', ',', '\n', '\t' }) |sep| {
        if (std.mem.lastIndexOfScalar(u8, last, sep)) |at| last = last[at + 1 ..];
    }
    last = std.mem.trim(u8, last, " \t\r\n");
    if (std.mem.eql(u8, last, ".join")) return true;
    if (std.mem.indexOf(u8, last, "modal-card") != null) return true;
    return std.mem.endsWith(u8, last, "-modal");
}

/// The `width` a rule sets on itself, if it sets one. `max-width` and
/// `min-width` are bounds a card may hold in its own right. This is the
/// measure the card stands at, which is the thing the scale names.
fn ownWidthValue(body: []const u8) ?[]const u8 {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, body, at, "width:")) |found| {
        at = found + 6;
        if (found > 0 and (body[found - 1] == '-' or std.ascii.isAlphabetic(body[found - 1]))) continue;
        const rest = body[found..];
        const end = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
        return rest[0..end];
    }
    return null;
}

/// Every size in the rooms chrome is a step on the type ramp, or argues in its
/// own block why it is not one.
///
/// The ramp in `tokens.css` says of itself that a new size is a claim the ramp
/// is wrong. Four sizes can make that claim without saying so: the base the
/// document inherits, written as a number in the body rule so the ramp
/// describes every size except the one under all the others. A boot note at
/// half a pixel between two steps. A boot heading between the last two, and a
/// setup screen's heading. The first is a step (`--type-read`), the next two
/// snap to steps, and the last says why the page it fills is not measured by a
/// ramp built for chrome.
///
/// What stays off the ramp is what is not chrome type at all: a logotype's
/// drawing, a sigil sized against the word beside it, monospace corrected
/// against the sans around it, and the sixteen pixels iOS refuses to leave
/// alone. Each says so where it is written, which is the whole of what this
/// asks: the argument lives in the block that sets the size, so a reader who
/// finds the number finds the reason without leaving the rule.
///
/// A value reaches the ramp directly or through one alias, because the filter's
/// answers are set through a `--filter-answer` composed from a ramp step and
/// that is a fair way to name a size once and use it four times.
///
/// Measured by breaking the code: a rule given a bare `font-size: 15px` is
/// caught and named, an alias pointed at a literal instead of a step is caught,
/// stripping the argument from an arguing rule turns it red, and so does moving
/// that argument above the selector instead of into the block.
///
/// The first version of this asked only that the block hold a comment
/// somewhere, and that version was measured too: it let the `code` rule keep
/// its literal after the argument was deleted, because a second comment about
/// wrapping still sat further down the same block. What it was watching was
/// whether anyone had written anything nearby. `argumentPrecedes` is the
/// repair.
pub fn checkRoomsTypeRamp(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    // Read as written, comments included: the comment is the evidence.
    const css = (util.concatDirFiles(io, gpa, root, ui_dir, keepAnySheet) catch null) orelse {
        try appendViolation(gpa, violations, "{s}: could not read the rooms stylesheets", .{ui_dir});
        return;
    };
    defer gpa.free(css);

    var ramped: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, css, at, "font-size:")) |found| {
        at = found + "font-size:".len;
        // `--x-font-size:` declares one rather than setting this.
        if (found > 0 and (css[found - 1] == '-' or std.ascii.isAlphabetic(css[found - 1]))) continue;
        if (insideComment(css, found)) continue;
        const rest = css[at..];
        const value = std.mem.trim(u8, rest[0..(std.mem.indexOfScalar(u8, rest, ';') orelse continue)], " \t\r\n");
        if (namesARampStep(css, value)) {
            ramped += 1;
            continue;
        }
        if (argumentPrecedes(css, found)) continue;
        try appendViolation(
            gpa,
            violations,
            "{s}: `font-size: {s}` is neither a `--type-*` step nor argued in the block that sets it; the ramp in tokens.css says a new size is a claim the ramp is wrong, so name a step or say in the rule why this is not chrome type",
            .{ ui_dir, value },
        );
    }
    if (ramped == 0) {
        try appendViolation(
            gpa,
            violations,
            "{s}: no rule names a `--type-*` step; whatever the ramp is called now, this check is watching nothing",
            .{ui_dir},
        );
    }
}

/// Whether an offset falls inside a CSS comment, judged by which of `/*` and
/// `*/` came last before it.
fn insideComment(css: []const u8, at: usize) bool {
    const opened = std.mem.lastIndexOf(u8, css[0..at], "/*") orelse return false;
    const closed = std.mem.lastIndexOf(u8, css[0..at], "*/") orelse return true;
    return opened > closed;
}

/// Whether a font size resolves to the ramp: a `--type-*` step, an alias one
/// hop from one, or `inherit`, which takes whatever the ancestor resolved to.
fn namesARampStep(css: []const u8, value: []const u8) bool {
    if (std.mem.eql(u8, value, "inherit")) return true;
    if (std.mem.indexOf(u8, value, "var(--type-") != null) return true;
    // One hop. `var(--filter-answer)` is a size named once and read four times,
    // and the declaration it stands for is in these same sheets.
    const opens = std.mem.indexOf(u8, value, "var(--") orelse return false;
    const name_from = opens + "var(".len;
    var name_to = name_from;
    while (name_to < value.len and nameByte(value[name_to])) name_to += 1;
    var needle_buf: [128]u8 = undefined;
    const name = value[name_from..name_to];
    if (name.len + 1 > needle_buf.len) return false;
    @memcpy(needle_buf[0..name.len], name);
    needle_buf[name.len] = ':';
    const decl = std.mem.indexOf(u8, css, needle_buf[0 .. name.len + 1]) orelse return false;
    const tail = css[decl..];
    const stop = std.mem.indexOfScalar(u8, tail, ';') orelse return false;
    return std.mem.indexOf(u8, tail[0..stop], "var(--type-") != null;
}

/// Whether a comment sits immediately above a declaration, inside the same
/// rule block.
///
/// Immediately, not anywhere in the block: measured, the looser reading handed
/// out a free pass. The `code` rule carries a second comment about wrapping
/// further down, so deleting the argument for its relative size left the block
/// still commented and the check still green. An argument the reader has to go
/// looking for is not beside the number it explains.
fn argumentPrecedes(css: []const u8, at: usize) bool {
    var back = at;
    while (back > 0 and std.ascii.isWhitespace(css[back - 1])) back -= 1;
    if (back < 2 or !std.mem.eql(u8, css[back - 2 .. back], "*/")) return false;
    const opened = std.mem.lastIndexOf(u8, css[0..back], "/*") orelse return false;
    // Inside this rule rather than above the selector: an argument for a size
    // belongs in the block that sets it.
    const brace = std.mem.lastIndexOfScalar(u8, css[0..at], '{') orelse return false;
    return opened > brace;
}

pub fn checkRoomsCustomProperties(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    // Every sheet, tokens.css included: it is where most of these are written,
    // and the sheet list the other rooms checks use leaves it out.
    const css = (util.concatDirFiles(io, gpa, root, ui_dir, keepAnySheet) catch null) orelse {
        try appendViolation(gpa, violations, "{s}: could not read the rooms stylesheets", .{ui_dir});
        return;
    };
    defer gpa.free(css);

    var defined: std.StringHashMapUnmanaged(void) = .empty;
    defer defined.deinit(gpa);
    try collectDefined(gpa, css, &defined);

    // A component may write one as an inline style instead, at any depth.
    var sources: std.ArrayList([]u8) = .empty;
    defer {
        for (sources.items) |s| gpa.free(s);
        sources.deinit(gpa);
    }
    if (root.openDir(io, ui_dir, .{ .iterate = true }) catch null) |opened| {
        var dir = opened;
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (walker.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            const ok = std.mem.endsWith(u8, entry.basename, ".ts") or
                std.mem.endsWith(u8, entry.basename, ".tsx") or
                std.mem.endsWith(u8, entry.basename, ".html");
            if (!ok) continue;
            const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ ui_dir, entry.path });
            defer gpa.free(path);
            const body = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch {
                // Not tolerable: a component this check could not read is one
                // whose inline properties it did not collect, and the answer
                // that follows would be a name reported as written by nobody.
                // Say so instead of reporting that.
                try appendViolation(gpa, violations, "{s}: could not read {s}", .{ ui_dir, entry.path });
                return;
            };
            try sources.append(gpa, body);
            try collectDefined(gpa, body, &defined);
        }
    }

    if (defined.count() == 0) {
        try appendViolation(
            gpa,
            violations,
            "{s}: no custom property definitions found; whatever the interface's tokens are written as now, this check is watching nothing",
            .{ui_dir},
        );
        return;
    }

    var used: std.StringHashMapUnmanaged(void) = .empty;
    defer used.deinit(gpa);
    try collectUsed(gpa, css, &used);

    var it = used.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (defined.contains(name)) continue;
        try appendViolation(
            gpa,
            violations,
            "{s} stylesheets read `var({s})` and nothing writes `{s}`; an unnamed property makes its whole declaration invalid, so the property silently takes its initial value rather than the one it replaced",
            .{ ui_dir, name, name },
        );
    }
}
