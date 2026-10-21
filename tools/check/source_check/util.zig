//! Shared primitives for the source-check modules.
//!
//! The source gate is one build step (`tools/check/source_check.zig` orchestrates)
//! whose check families live in sibling modules under this directory, each
//! owning one named surface. The shared violation sink lives here, so a module never reaches back into the driver.

const std = @import("std");
const model = @import("model");

/// Record one violation. The driver prints the collected list and fails the
/// step when it is non-empty. A check never fails the step directly, so one
/// run reports every violation at once.
pub fn appendViolation(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    comptime fmt: []const u8,
    args: anytype,
) !void {
    try violations.append(gpa, try std.fmt.allocPrint(gpa, fmt, args));
}

pub fn expectFileContains(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    needles: []const []const u8,
) !void {
    const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);

    for (needles) |needle| {
        if (std.mem.indexOf(u8, contents, needle) == null) {
            try appendViolation(gpa, violations, "{s}: missing required text `{s}`", .{ path, needle });
        }
    }
}

/// Concatenate every file in `dir_path` whose name `keep` accepts, sorted.
pub fn concatDirFiles(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    dir_path: []const u8,
    keep: *const fn (name: []const u8) bool,
) !?[]u8 {
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var dir = root.openDir(io, dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var it = dir.iterate();
    while (true) {
        const entry = (it.next(io) catch return null) orelse break;
        if (entry.kind == .directory) continue;
        if (!keep(entry.name)) continue;
        const owned_name = try gpa.dupe(u8, entry.name);
        errdefer gpa.free(owned_name);
        try names.append(gpa, owned_name);
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    for (names.items) |name| {
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, name });
        defer gpa.free(path);
        const body = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch {
            buf.deinit(gpa);
            return null;
        };
        defer gpa.free(body);
        try buf.appendSlice(gpa, body);
        try buf.append(gpa, '\n');
    }
    return try buf.toOwnedSlice(gpa);
}

pub fn fileContains(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    path: []const u8,
    needle: []const u8,
) !bool {
    const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch return false;
    defer gpa.free(contents);
    return std.mem.indexOf(u8, contents, needle) != null;
}

/// Match a source fragment while ignoring formatter-controlled ASCII
/// whitespace. Use this for declaration/call shapes whose tokens are the
/// contract and whose line wrapping is not.
pub fn containsIgnoringWhitespace(contents: []const u8, fragment: []const u8) bool {
    var start: usize = 0;
    while (start < contents.len) : (start += 1) {
        var source = start;
        var expected: usize = 0;
        while (expected < fragment.len) {
            while (expected < fragment.len and std.ascii.isWhitespace(fragment[expected])) expected += 1;
            while (source < contents.len and std.ascii.isWhitespace(contents[source])) source += 1;
            if (expected == fragment.len) return true;
            if (source == contents.len or contents[source] != fragment[expected]) break;
            source += 1;
            expected += 1;
        }
        while (expected < fragment.len and std.ascii.isWhitespace(fragment[expected])) expected += 1;
        if (expected == fragment.len) return true;
    }
    return fragment.len == 0;
}

test "containsIgnoringWhitespace follows tokens across formatter wrapping" {
    try std.testing.expect(containsIgnoringWhitespace(
        "call(\n    first,\n    second,\n);",
        "call(first, second,);",
    ));
    try std.testing.expect(!containsIgnoringWhitespace(
        "call(first, replacement);",
        "call(first, second);",
    ));
}

/// Generated and vendored directories no source contract may enter.
///
/// This is a traversal policy, not a result filter. Rejecting one of these
/// paths after `walk()` has already enumerated it still makes every static
/// check pay for a Cargo target or JavaScript dependency tree. Keep the
/// directory decision here so broad `apps` and `bindings` checks cannot drift
/// into generated state independently.
pub fn sourceTreeDirectory(path: []const u8) bool {
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "node_modules") or
            std.mem.eql(u8, part, "target") or
            std.mem.eql(u8, part, "zig-out") or
            std.mem.eql(u8, part, "zig-pkg") or
            std.mem.eql(u8, part, ".zig-cache") or
            std.mem.eql(u8, part, ".venv") or
            std.mem.eql(u8, part, "__pycache__") or
            std.mem.eql(u8, part, "compiled") or
            std.mem.eql(u8, part, ".vite") or
            std.mem.eql(u8, part, ".deno") or
            std.mem.eql(u8, part, ".git") or
            std.mem.eql(u8, part, ".local")) return false;
    }
    // The visualizer bundle is generated by its build and is not source.
    if (std.mem.eql(u8, path, "apps/ocapnviz/dist") or
        std.mem.startsWith(u8, path, "apps/ocapnviz/dist/")) return false;
    return true;
}

/// Enter a selective walk directory only when it belongs to source state.
/// `root_path` is the repository-relative directory the walker was opened on.
pub fn enterSourceDirectory(
    io: std.Io,
    gpa: std.mem.Allocator,
    walker: *std.Io.Dir.SelectiveWalker,
    root_path: []const u8,
    entry: std.Io.Dir.Walker.Entry,
) !void {
    const repo_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root_path, entry.path });
    defer gpa.free(repo_path);
    if (sourceTreeDirectory(repo_path)) try walker.enter(io, entry);
}

/// One immutable repository-relative file inventory per source tree.
/// Callers retain their own suffix and exclusion policy over the returned
/// paths. The map and every path use `arena` and live for that allocator's
/// lifetime.
pub fn cachedSourceTreeFiles(
    io: std.Io,
    arena: std.mem.Allocator,
    root: std.Io.Dir,
    root_path: []const u8,
    inventories: *std.StringHashMapUnmanaged([]const []const u8),
) ![]const []const u8 {
    if (inventories.get(root_path)) |files| return files;

    var files: std.ArrayList([]const u8) = .empty;
    var dir = try root.openDir(io, root_path, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walkSelectively(arena);
    defer walker.deinit();
    while (try walker.next(io)) |walk_entry| {
        if (walk_entry.kind == .directory) {
            try enterSourceDirectory(io, arena, &walker, root_path, walk_entry);
            continue;
        }
        if (walk_entry.kind != .file) continue;
        try files.append(arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ root_path, walk_entry.path }));
    }
    const owned = try files.toOwnedSlice(arena);
    try inventories.put(arena, root_path, owned);
    return owned;
}

/// Every file beneath `root_path` that `keep` accepts, as repository-relative
/// paths in sorted order, or null when the directory cannot be opened.
///
/// One authority for what counts as a file a check reads. The walk itself is
/// the part three checks were each spelling out, and they had already come to
/// disagree about vendored trees, which is the ordinary way duplicated
/// traversal rots. Sorted because violation output a reader compares between
/// runs should not depend on what order a filesystem hands its entries back.
///
/// The caller owns the list and every path in it, and reads each file itself:
/// the read limit and the sentence a failure gets belong to the check, not
/// here.
pub fn collectSourceFiles(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    root_path: []const u8,
    keep: *const fn (path: []const u8) bool,
) !?[][]u8 {
    var dir = root.openDir(io, root_path, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var walker = dir.walkSelectively(gpa) catch return null;
    defer walker.deinit();
    var found: std.ArrayList([]u8) = .empty;
    errdefer {
        for (found.items) |path| gpa.free(path);
        found.deinit(gpa);
    }
    while (walker.next(io) catch return null) |entry| {
        if (entry.kind == .directory) {
            enterSourceDirectory(io, gpa, &walker, root_path, entry) catch return null;
            continue;
        }
        if (entry.kind != .file or !keep(entry.path)) continue;
        try found.append(gpa, try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root_path, entry.path }));
    }
    std.mem.sort([]u8, found.items, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    return try found.toOwnedSlice(gpa);
}

test "collectSourceFiles never enters generated trees" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "apps/pkg/src");
    try tmp.dir.createDirPath(io, "apps/pkg/target/deep");
    try tmp.dir.createDirPath(io, "apps/pkg/node_modules/deep");
    try tmp.dir.createDirPath(io, "apps/pkg/__pycache__/deep");
    try tmp.dir.createDirPath(io, "apps/pkg/compiled/deep");
    try tmp.dir.writeFile(io, .{ .sub_path = "apps/pkg/src/kept.ts", .data = "kept" });
    try tmp.dir.writeFile(io, .{ .sub_path = "apps/pkg/target/deep/generated.ts", .data = "generated" });
    try tmp.dir.writeFile(io, .{ .sub_path = "apps/pkg/node_modules/deep/vendor.ts", .data = "vendor" });
    try tmp.dir.writeFile(io, .{ .sub_path = "apps/pkg/__pycache__/deep/bytecode.ts", .data = "generated" });
    try tmp.dir.writeFile(io, .{ .sub_path = "apps/pkg/compiled/deep/bytecode.ts", .data = "generated" });

    const keepTs = struct {
        fn keep(path: []const u8) bool {
            return std.mem.endsWith(u8, path, ".ts");
        }
    }.keep;
    const files = (try collectSourceFiles(io, gpa, tmp.dir, "apps", keepTs)) orelse
        return error.TestUnexpectedResult;
    defer {
        for (files) |path| gpa.free(path);
        gpa.free(files);
    }
    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqualStrings("apps/pkg/src/kept.ts", files[0]);
}

/// Read one source file, or concatenate every regular file beneath a package
/// directory when `path` ends in `/`. Directory subjects keep ownership bans
/// valid after a module becomes a package: a new leaf cannot evade a rule
/// written for the single file.
pub fn readSourceSubject(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    path: []const u8,
) !?[]u8 {
    if (!std.mem.endsWith(u8, path, "/")) {
        return root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch null;
    }
    const dir_path = path[0 .. path.len - 1];
    var dir = root.openDir(io, dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const body = dir.readFileAlloc(io, entry.path, gpa, .limited(4 << 20)) catch {
            out.deinit(gpa);
            return null;
        };
        defer gpa.free(body);
        try out.appendSlice(gpa, body);
        try out.append(gpa, '\n');
    }
    return try out.toOwnedSlice(gpa);
}

test "readSourceSubject includes every nested package leaf" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "pkg/nested");
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/root.py", .data = "root-marker" });
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/nested/leaf.py", .data = "leaf-marker" });
    const subject = (try readSourceSubject(io, gpa, tmp.dir, "pkg/")) orelse
        return error.TestUnexpectedResult;
    defer gpa.free(subject);
    try std.testing.expect(std.mem.indexOf(u8, subject, "root-marker") != null);
    try std.testing.expect(std.mem.indexOf(u8, subject, "leaf-marker") != null);
}

fn parseLeadingInt(s: []const u8) ?i64 {
    var i: usize = 0;
    var neg = false;
    if (i < s.len and s[i] == '-') {
        neg = true;
        i += 1;
    }
    const start = i;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
    if (i == start) return null;
    const mag = std.fmt.parseInt(i64, s[start..i], 10) catch return null;
    return if (neg) -mag else mag;
}

pub fn firstIntIn(s: []const u8) ?i64 {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '-' or (s[i] >= '0' and s[i] <= '9')) return parseLeadingInt(s[i..]);
    }
    return null;
}

pub fn parseJsonFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
) !?std.json.Parsed(std.json.Value) {
    const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read JSON with {s}", .{ path, @errorName(err) });
        return null;
    };
    defer gpa.free(contents);

    return std.json.parseFromSlice(std.json.Value, gpa, contents, .{}) catch |err| {
        try appendViolation(gpa, violations, "{s}: invalid JSON ({s})", .{ path, @errorName(err) });
        return null;
    };
}

pub fn getField(value: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (value) {
        .object => |object| object.get(key),
        else => null,
    };
}

pub fn jsonStringEquals(value: std.json.Value, expected: []const u8) bool {
    return switch (value) {
        .string => |actual| std.mem.eql(u8, actual, expected),
        else => false,
    };
}

/// Returns the body of the `## <heading>` section of a Markdown document,
/// ending at the next `## ` heading or end of file. The slice points into
/// `contents`, so it shares its lifetime.
pub fn sectionBody(contents: []const u8, heading: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, contents, heading) orelse return null;
    const after = contents[start + heading.len ..];
    const end = std.mem.indexOf(u8, after, "\n## ") orelse after.len;
    return after[0..end];
}

/// A CapTP version's Zig enum tag and the word it puts on the wire.
pub const CaptpWireWord = struct { tag: []const u8, wire: []const u8 };

/// Every `model.CaptpVersion` with its `wireString`. Two checks hold their
/// files to these words: `c_abi.checkTraceVocabulary` the four producers, and
/// `binding_spine/viewer.zig` the viewer that reads them.
pub const captp_wire_words = blk: {
    const versions = std.enums.values(model.CaptpVersion);
    var words: [versions.len]CaptpWireWord = undefined;
    for (versions, &words) |version, *word| word.* = .{ .tag = @tagName(version), .wire = version.wireString() };
    break :blk words;
};

/// Collects the first backtick span of every `- \`...\`` bullet line in
/// `section`. Spans are slices into `section`, so they share its lifetime.
pub fn collectBulletSpans(gpa: std.mem.Allocator, section: []const u8, out: *std.ArrayList([]const u8)) !void {
    var lines = std.mem.splitScalar(u8, section, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "- `")) continue;
        const after_tick = trimmed["- `".len..];
        const close = std.mem.indexOfScalar(u8, after_tick, '`') orelse continue;
        try out.append(gpa, after_tick[0..close]);
    }
}

/// The sources that register build steps: the root `build.zig` plus every
/// composed step-registration module beneath `tools/build/`, concatenated into
/// one owned buffer so a textual step scan sees the whole graph the root
/// composes. The recursive walk matters because a subject that outgrows one
/// file becomes a package, nesting must not make its steps invisible to the
/// documentation and check-membership ratchets. Callers free the result.
pub fn readBuildStepSources(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    const root_src = try root.readFileAlloc(io, "build.zig", gpa, .limited(1 << 21));
    defer gpa.free(root_src);
    try buf.appendSlice(gpa, root_src);
    var dir = try root.openDir(io, "tools/build", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const src = try dir.readFileAlloc(io, entry.path, gpa, .limited(1 << 21));
        defer gpa.free(src);
        try buf.append(gpa, '\n');
        try buf.appendSlice(gpa, src);
    }
    return buf.toOwnedSlice(gpa);
}

/// Find the `{ ... }` block opened by the `{`-terminated `marker`, matching
/// braces so a nested struct literal inside the block cannot close it early.
/// Returns the interior (excluding the outer braces), or `null` when the
/// marker is absent or its brace never closes.
pub fn extractBraceBlock(text: []const u8, marker: []const u8) ?[]const u8 {
    std.debug.assert(std.mem.endsWith(u8, marker, "{"));
    const start = std.mem.indexOf(u8, text, marker) orelse return null;
    const open = start + marker.len - 1;
    var depth: usize = 1;
    var i = open + 1;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return text[open + 1 .. i];
            },
            else => {},
        }
    }
    return null;
}

/// Whether `haystack` contains `needle` as a whole symbol rather than as the
/// prefix of a longer one. The bans and presence checks above name FFI symbols
/// and call spellings, so a plain substring match reads
/// `glowcap_host_session_published_ref` as a use of
/// `glowcap_host_session_publish` and refuses a sibling verb that never broke the
/// rule. A required needle has the same defect facing the other way: a longer
/// sibling would satisfy it. Boundaries are only required at an end whose own
/// character is part of an identifier, so a needle spelled with trailing
/// punctuation (`"return sendLocal("`) still matches.
///
/// A needle that begins with an identifier character no longer matches mid- status-allow: lifecycle transition
/// identifier, so `"tell_local("` is not found inside `"run_tell_local("`. Spell
/// such a needle with whatever precedes it when that is what you meant.
pub fn containsAsSymbol(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return false;
    const identLike = struct {
        fn f(ch: u8) bool {
            return std.ascii.isAlphanumeric(ch) or ch == '_';
        }
    }.f;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, from, needle)) |at| {
        from = at + 1;
        if (identLike(needle[0]) and at > 0 and identLike(haystack[at - 1])) continue;
        const end = at + needle.len;
        if (identLike(needle[needle.len - 1]) and end < haystack.len and identLike(haystack[end])) continue;
        return true;
    }
    return false;
}
