//! Shared primitives for the source-check modules.
//!
//! The source gate is one build step (`tools/check/source_check.zig` orchestrates)
//! whose check families live in sibling modules under this directory, each
//! owning one named surface. What they all share — today the one violation
//! sink — lives here, so a module never reaches back into the driver.

const std = @import("std");

/// Record one violation. The driver prints the collected list and fails the
/// step when it is non-empty; a check never fails the step directly, so one
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

/// Read one source file, or concatenate every regular file beneath a package
/// directory when `path` ends in `/`. Directory subjects keep ownership bans
/// honest after a module becomes a package: a new leaf cannot evade a rule
/// that used to scan the single monolith.
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

/// One arm of `model.CaptpVersion.wireString`: the Zig enum tag, and the word
/// that version puts on the wire. Both are slices into the source.
pub const CaptpWireArm = struct { tag: []const u8, wire: []const u8 };

/// Reads the arms of `CaptpVersion.wireString` out of the text of
/// `src/ocapn/model/negotiated.zig`.
///
/// Text rather than reflection because the build runner compiles the source gate
/// from `tools/check/`, which no `src/` path is importable from. It lives here
/// because two checks read the same switch and a second parser would be the
/// duplication they exist to refuse: `c_abi.checkTraceVocabulary` holds the
/// four producers to these words, and `binding_spine/viewer.zig`
/// holds the viewer that reads them.
///
/// An empty result means the switch's shape moved. Every caller reports that as
/// a violation rather than passing quietly, because a parser that silently
/// matches nothing turns its check into a green light.
pub fn collectCaptpWireArms(
    gpa: std.mem.Allocator,
    source: []const u8,
    out: *std.ArrayList(CaptpWireArm),
) !void {
    const fn_at = std.mem.indexOf(u8, source, "pub fn wireString(") orelse return;
    // `name` returns diagnostic labels rather than wire tokens, so the scan
    // must stop at this function's own closing brace.
    const body_end = std.mem.indexOfPos(u8, source, fn_at, "\n    }") orelse source.len;

    var cursor = fn_at;
    while (std.mem.indexOfPos(u8, source, cursor, "            .")) |at| {
        if (at >= body_end) break;
        const line_end = std.mem.indexOfScalarPos(u8, source, at, '\n') orelse body_end;
        cursor = line_end;
        const line = source[at..line_end];
        const arrow = std.mem.indexOf(u8, line, " => \"") orelse continue;
        const tag = std.mem.trim(u8, line[1..arrow], " .");
        const rest = line[arrow + 5 ..];
        const close = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
        if (tag.len == 0 or close == 0) continue;
        try out.append(gpa, .{ .tag = tag, .wire = rest[0..close] });
    }
}

test "collectCaptpWireArms reads wireString and stops before name" {
    const gpa = std.testing.allocator;
    const source =
        \\pub const CaptpVersion = enum {
        \\    v1_0,
        \\    next,
        \\
        \\    pub fn wireString(self: CaptpVersion) []const u8 {
        \\        return switch (self) {
        \\            .v1_0 => "1.0",
        \\            .next => "pancake-next",
        \\        };
        \\    }
        \\
        \\    pub fn name(self: CaptpVersion) []const u8 {
        \\        return switch (self) {
        \\            .v1_0 => "ocapn-v1.0",
        \\            .next => "pancake-next",
        \\        };
        \\    }
        \\};
    ;
    var arms: std.ArrayList(CaptpWireArm) = .empty;
    defer arms.deinit(gpa);
    try collectCaptpWireArms(gpa, source, &arms);
    // `ocapn-v1.0` is a log label. A producer that said it would be stating a
    // spelling no peer ever sends, so it must not be read as a wire word.
    try std.testing.expectEqual(@as(usize, 2), arms.items.len);
    try std.testing.expectEqualStrings("v1_0", arms.items[0].tag);
    try std.testing.expectEqualStrings("1.0", arms.items[0].wire);
    try std.testing.expectEqualStrings("next", arms.items[1].tag);
    try std.testing.expectEqualStrings("pancake-next", arms.items[1].wire);
}

test "collectCaptpWireArms gives up nothing when wireString is gone" {
    const gpa = std.testing.allocator;
    var arms: std.ArrayList(CaptpWireArm) = .empty;
    defer arms.deinit(gpa);
    try collectCaptpWireArms(gpa, "pub fn spelling(self: X) []const u8 { return \"1.0\"; }", &arms);
    try std.testing.expectEqual(@as(usize, 0), arms.items.len);
}

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
/// composed step-registration module under `tools/build/`, concatenated into
/// one owned buffer so a textual step scan sees the whole graph the root
/// composes. Callers free the result.
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
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
        const src = try dir.readFileAlloc(io, entry.name, gpa, .limited(1 << 21));
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
/// `pancake_host_session_published_ref` as a use of
/// `pancake_host_session_publish` and refuses a sibling verb that never broke the
/// rule. A required needle has the same defect facing the other way: a longer
/// sibling would satisfy it. Boundaries are only required at an end whose own
/// character is part of an identifier, so a needle spelled with trailing
/// punctuation (`"return sendLocal("`) still matches.
///
/// A needle that begins with an identifier character no longer matches mid-
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
