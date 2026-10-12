//! Essential rooms UI selectors: every id/class a browser proof presses,
//! still emitted by a component, still named in that proof.

const std = @import("std");
const util = @import("../util.zig");
const shared = @import("shared.zig");

const appendViolation = util.appendViolation;
const ui_dir = shared.ui_dir;

/// A selector the interface promises to emit and a proof depends on.
///
/// Both directions matter. A literal no component emits is a proof about to fail
/// for a reason that has nothing to do with what it tests. A literal no proof
/// uses is rent, and should be retired rather than carried.
const Selector = struct {
    /// The exact text a component writes, as it appears in the JSX.
    literal: []const u8,
    /// The proof that would break, and what it would look like when it did.
    proven_by: []const u8,
};

const selectors = [_]Selector{
    .{ .literal = "id=\"log\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    .{ .literal = "id=\"line\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    .{ .literal = "id=\"nick\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    .{ .literal = "id=\"room\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    .{ .literal = "id=\"joinBtn\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    // Stopping a join that is still waiting. A rename here reads as "joining did
    // not offer a way to stop waiting", a claim about the card, made by the mark
    // that moved. The DOM id is `joinStop`; the component writes it as `stopId`
    // because `id` on WorkingAction is the busy button.
    .{ .literal = "stopId=\"joinStop\"", .proven_by = "apps/rooms/test/page/foreign.ts" },
    .{ .literal = "id=\"joinPrivate\"", .proven_by = "apps/rooms/test/proofs/private_room_proof.ts" },
    // The directory mark on the join card opens the locators this tab already
    // holds. A rename here reads as "the join card offered no addresses", a
    // claim about holding more than one directory, made by a control that moved.
    .{ .literal = "id=\"joinLocator\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    .{ .literal = "\"locator-picks\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    .{ .literal = "id=\"status\"", .proven_by = "apps/rooms/test/proofs/relay_peer_proof.ts" },
    .{ .literal = "id=\"backBtn\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    .{ .literal = "id=\"railToggle\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    .{ .literal = "id=\"membersToggle\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    // Settings travels with the list: the rail title while it is up, the
    // conversation bar when it is away. A rename here reads as "the page offered
    // no Settings", a claim about the chrome, made by a control that moved.
    .{ .literal = "id=\"settingsBtn\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    .{ .literal = "id=\"members\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    .{ .literal = "listId=\"dmList\"", .proven_by = "apps/rooms/test/proofs/dm_retarget_proof.ts" },
    .{ .literal = "\"bubble\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    // Posting a file: the picker the proof feeds a file to, and the two shapes
    // a posted file takes in a bubble. A rename here reads as "the second peer
    // never drew the posted image", which is a claim about the room relaying a
    // capability, made by a class that moved.
    .{ .literal = "id=\"filePick\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    .{ .literal = "attach-image", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    .{ .literal = "attach-file", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    .{ .literal = "\"viewer\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    .{ .literal = "is-actual", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    .{ .literal = "id=\"viewerZoom\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    .{ .literal = "\"sidebar-body\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    .{ .literal = "\"dm-open\"", .proven_by = "apps/rooms/test/proofs/dm_retarget_proof.ts" },
    .{ .literal = "\"dm-btn\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    // The mark in the title ends whatever is on screen: it leaves a room, and it
    // closes a direct line. The two-tab proof closes a conversation with it and
    // then checks the member is still reachable, so a rename here would report
    // as "the members list stopped offering a direct line", a claim about the
    // roster, made by a button that moved.
    .{ .literal = "id=\"leaveBtn\"", .proven_by = "apps/rooms/test/proofs/dm_tabs_proof.ts" },
    .{ .literal = "show-list", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    .{ .literal = "members-open", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    // Copying a locator: the field that is itself the control, the chip that
    // says the copy happened, and the toast a refused write answers with above
    // Settings. The proof watches the reply arrive and then go, so a rename
    // here reads as "the copy control never answered", which is a claim about
    // the clipboard made by a class that moved.
    .{ .literal = "\"copy-field\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    .{ .literal = "\"copy-said\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    .{ .literal = "id=\"toasts\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    .{ .literal = "\"toast\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    .{ .literal = "\"toast-dismiss\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    .{ .literal = "id=\"directoryLocator\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    // Double-clicking Help's title opens the parts catalog in that same dialog.
    // A rename here reads as "Help did not open the catalog", a claim about the
    // glossary made by a name that moved.
    .{ .literal = "id=\"kitchenSink\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    // A room's row says which directory it is on, and that line opens the card
    // that describes it: this page's own included. Settings keeps the page
    // locator and a button that opens that same card. The proof presses both
    // and reads the three answers the card gives. A rename here reports as
    // "holding two servers did not say which server each room is on" or "the
    // caption did not open a card about it", claims about holding more than
    // one directory, made by a name that moved.
    .{ .literal = "\"rwhere\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    // A card's title is drawn by `ModalHead`, so the id a proof presses is
    // written as `titleId`, the way `stopId` is above.
    .{ .literal = "titleId=\"dircardTitle\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    // The conversation's name opens what this tab knows about it, and a long
    // refusal's Show opens the rest of the words. A rename here reads as "the
    // title did nothing" or "Show did not open the rest", claims about those
    // cards, made by a name that moved.
    .{ .literal = "id=\"roomAbout\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    .{ .literal = "titleId=\"convcardTitle\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    // The long refusal in the parts catalog. The proof presses `#kitchenLongSaid`,
    // but no component writes that: the sample is a `Field`, and `Field` names its
    // refusal after the control it belongs to. So the id the catalog owns is the
    // one below, and the refusal's follows from it.
    .{ .literal = "id=\"kitchenLong\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    .{ .literal = "titleId=\"errorTitle\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    .{ .literal = "id=\"errorBody\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    .{ .literal = "id=\"convcardLocator\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    .{ .literal = "id=\"convcardUriKind\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    .{ .literal = "id=\"convcardReach\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    .{ .literal = "id=\"convcardDir\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    .{ .literal = "id=\"convcardStanding\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    .{ .literal = "id=\"convcardLeaveAsk\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    .{ .literal = "id=\"convcardLeaveSaid\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    .{ .literal = "\"dirfacts\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    .{ .literal = "id=\"settingsAboutDir\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    .{ .literal = "id=\"dircardLeaveAsk\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    // The commitment inside the leave confirm. Its id is written as `commitId`
    // because `Confirm` owns the button and `id` names the confirm itself.
    .{ .literal = "commitId=\"dircardLeave\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    // The opening screen is written in the document rather than by a component,
    // so it can paint before the bundle exists. The proof watches
    // both of its faces from the first frame, so the names are essential in
    // the same way every name above is.
    .{ .literal = "id=\"boot\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    .{ .literal = "class=\"boot-wait\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
    .{ .literal = "class=\"boot-explain\"", .proven_by = "apps/rooms/test/proofs/page_proof.ts" },
};

/// Every essential selector is still emitted, and still proven.
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
        const proof = readProof(io, gpa, root, selector.proven_by) catch {
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
                "{s} no longer selects on `{s}`; retire the row in tools/check/source_check/rooms_ui/selectors.zig rather than carrying a selector nothing proves",
                .{ selector.proven_by, bare },
            );
        }
    }
}

/// A proof's own text, and the text of every module it reaches from beside it.
///
/// A browser proof that outgrew one file is still one proof. The page scenario
/// is a driver that hands each phase of the conversation to a module under
/// `test/page/`, and a selector a phase presses is proven exactly as much as one
/// the driver presses. Following the imports lets the table above name the
/// scenario rather than the file layout it happens to have, so splitting a proof
/// up cannot quietly retire the selectors it still checks.
///
/// The walk stops at the interface. A proof may import a type from `web/ui` for
/// its own reasons, but the component's text is not evidence that anything
/// presses what it emits: pulling it into the closure would let every selector
/// prove itself, and the check would pass by construction while watching
/// nothing. That is a failure this check has already had once, in the walk that
/// reads the interface, so here it is a rule the code holds rather than one a
/// reader has to keep.
fn readProof(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    entry_path: []const u8,
) ![]u8 {
    // Enough for a proof split by phase, and a stop if an import cycle or a
    // resolver mistake ever turns the walk loose.
    const max_modules = 64;

    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);
    var reached: std.ArrayList([]const u8) = .empty;
    defer {
        for (reached.items) |path| gpa.free(path);
        reached.deinit(gpa);
    }
    try reached.append(gpa, try gpa.dupe(u8, entry_path));

    var at: usize = 0;
    while (at < reached.items.len) : (at += 1) {
        // The slice header array may move as the walk grows, so take the path by
        // value; the bytes it points at belong to `reached` and stay put.
        const path = reached.items[at];
        const source = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            // tolerant: only the named entry has to be there. A module it
            // imports that cannot be read is `deno check`'s to report, and
            // reporting it here as a missing proof would name the wrong fault.
            if (at == 0) return err;
            continue;
        };
        defer gpa.free(source);
        try text.appendSlice(gpa, source);
        if (reached.items.len >= max_modules) continue;

        var scan: usize = 0;
        while (std.mem.indexOfPos(u8, source, scan, "from \"")) |found| {
            const spec_at = found + "from \"".len;
            const close = std.mem.indexOfScalarPos(u8, source, spec_at, '"') orelse break;
            scan = close + 1;
            const spec = source[spec_at..close];
            if (!std.mem.startsWith(u8, spec, "./") and !std.mem.startsWith(u8, spec, "../")) continue;
            if (!std.mem.endsWith(u8, spec, ".ts") and !std.mem.endsWith(u8, spec, ".tsx")) continue;
            const resolved = try resolveBeside(gpa, path, spec);
            errdefer gpa.free(resolved);
            if (std.mem.startsWith(u8, resolved, ui_dir ++ "/")) {
                gpa.free(resolved);
                continue;
            }
            for (reached.items) |seen| {
                if (std.mem.eql(u8, seen, resolved)) {
                    gpa.free(resolved);
                    break;
                }
            } else try reached.append(gpa, resolved);
        }
    }
    return try text.toOwnedSlice(gpa);
}

/// A relative import specifier as a path from the repository root.
fn resolveBeside(gpa: std.mem.Allocator, from_file: []const u8, spec: []const u8) ![]u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(gpa);
    var here = std.mem.splitScalar(u8, std.fs.path.dirname(from_file) orelse "", '/');
    while (here.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        try parts.append(gpa, segment);
    }
    var walk = std.mem.splitScalar(u8, spec, '/');
    while (walk.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) {
            if (parts.items.len > 0) _ = parts.pop();
            continue;
        }
        try parts.append(gpa, segment);
    }
    return try std.mem.join(gpa, "/", parts.items);
}

/// `id="log"`, `listId="dmList"`, and `"bubble"` name `log`, `dmList`, and
/// `bubble`. The literal is matched as the component actually writes it, so a
/// rename fails here. The proof spells the name alone.
fn bareName(literal: []const u8) []const u8 {
    var name = literal;
    if (std.mem.indexOfScalar(u8, name, '=')) |at| name = name[at + 1 ..];
    if (std.mem.startsWith(u8, name, "\"")) name = name[1..];
    if (std.mem.endsWith(u8, name, "\"")) name = name[0 .. name.len - 1];
    return name;
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
    // Every depth, because the interface's modules live in subdirectories.
    // Reading only the top level would still find every component and so still
    // pass, while quietly not covering the layer a selector's data comes
    // from: a check narrowed by someone else's file move, saying nothing.
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const tsx = std.mem.endsWith(u8, entry.path, ".tsx");
        const document = std.mem.eql(u8, entry.path, "page.html");
        if (!tsx and !document and !std.mem.endsWith(u8, entry.path, ".ts")) continue;
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ ui_dir, entry.path });
        defer gpa.free(path);
        const source = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: cannot be read for the selector check ({s})", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(source);
        try all.appendSlice(gpa, source);
    }
    return try all.toOwnedSlice(gpa);
}
