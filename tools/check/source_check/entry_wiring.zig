//! Check entry points. `runListed` calls every entry point of the root's listed
//! modules by reflection and refuses at compile time a public `check…` function
//! with another signature. `checkUnlistedEntryPoints` covers the nested modules
//! the root does not list.

const std = @import("std");
const appendViolation = @import("violation_log.zig").appendViolation;
const text_match = @import("text_match.zig");

const checker_dir = "tools/check";
const modules_name = "source_check";
const root_file = modules_name ++ ".zig";
const modules_prefix = modules_name ++ "/";
pub const checker_root = checker_dir ++ "/" ++ root_file;
pub const checker_modules = checker_dir ++ "/" ++ modules_name;

const Violations = *std.ArrayList([]const u8);

/// Call every entry point of `modules`, in list order and declaration order.
/// An entry point is a public function whose name starts with `check`. Its
/// type is `fn (std.Io, std.mem.Allocator, std.Io.Dir, *std.ArrayList([]const
/// u8)) !void`, and one with another type does not compile.
pub fn runListed(
    comptime modules: anytype,
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: Violations,
) !void {
    // The walk visits every declaration of every listed module.
    @setEvalBranchQuota(1 << 22);
    inline for (modules) |M| {
        inline for (@typeInfo(M).@"struct".decl_names) |name| {
            if (comptime !std.mem.startsWith(u8, name, "check")) continue;
            const T = @TypeOf(@field(M, name));
            if (@typeInfo(T) != .@"fn") continue;
            if (comptime !isEntrySignature(T)) {
                @compileError("`" ++ name ++ "` in " ++ @typeName(M) ++ " is public and starts with `check`, " ++
                    "so it must have the entry signature `fn (std.Io, std.mem.Allocator, std.Io.Dir, " ++
                    "*std.ArrayList([]const u8)) !void`. " ++
                    "Give it that signature, or give the helper a name that does not start with `check`.");
            }
            try @field(M, name)(io, gpa, root, violations);
        }
    }
}

fn isEntrySignature(comptime T: type) bool {
    const f = @typeInfo(T).@"fn";
    if (f.is_generic or f.param_types.len != 4) return false;
    const want = [_]type{ std.Io, std.mem.Allocator, std.Io.Dir, Violations };
    inline for (want, 0..) |W, i| if ((f.param_types[i] orelse return false) != W) return false;
    const ret = f.return_type orelse return false;
    return @typeInfo(ret) == .error_union and @typeInfo(ret).error_union.payload == void;
}

/// The entries of the root's `const checks = .{` list, from the newline that
/// ends the opening line to the closing `};`, or null when either is missing.
/// Comments are blanked in place first, because a commented-out entry lists
/// nothing. Both wiring checks read the list through this one reader.
pub fn readChecksList(root_source: []u8) ?[]const u8 {
    text_match.blankComments(root_source);
    const open = "const checks = .{\n";
    const start = (std.mem.find(u8, root_source, open) orelse return null) + open.len;
    const len = std.mem.find(u8, root_source[start..], "\n};") orelse return null;
    return root_source[start - 1 ..][0 .. 1 + len];
}

/// The message for a root that has no readable `checks` list.
pub const no_list = "{s}: has no `const checks = .{{` list closed by `}};` for the wiring check to read";

/// True when `list` names the module at `path` under the modules directory,
/// either by its `@import` or by the `const` alias in `root_source` that
/// imports it. Both come from `readChecksList`, so comments are already blanked.
pub fn isListed(gpa: std.mem.Allocator, root_source: []const u8, list: []const u8, path: []const u8) !bool {
    const import = try gpa.print("@import(\"{s}{s}\")", .{ modules_prefix, path });
    defer gpa.free(import);
    if (std.mem.find(u8, list, import) != null) return true;
    const declaration = try gpa.print(" = {s};", .{import});
    defer gpa.free(declaration);
    const at = std.mem.find(u8, root_source, declaration) orelse return false;
    const name_start = (std.mem.findScalarLast(u8, root_source[0..at], ' ') orelse return false) + 1;
    const entry = try gpa.print("\n    {s},", .{root_source[name_start..at]});
    defer gpa.free(entry);
    return std.mem.find(u8, list, entry) != null;
}

/// One checker source with comments blanked.
const File = struct {
    path: []const u8,
    code: []u8,
};

/// A file under the checker's module directory that the root does not import
/// is reached only through a listed module. Each of its entry points must be
/// named by some other checker file, or its rule never runs. The name `check`
/// alone is refused, because every file contains the word and no caller could
/// be found by it.
pub fn checkUnlistedEntryPoints(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: Violations,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var dir = root.openDir(io, checker_dir, .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to open for check entry-point wiring with {s}", .{ checker_dir, @errorName(err) });
        return;
    };
    defer dir.close(io);
    var files: std.ArrayList(File) = .empty;
    var walker = try dir.walk(arena);
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const code = dir.readFileAlloc(io, entry.path, arena, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}/{s}: failed to read for check entry-point wiring with {s}", .{ checker_dir, entry.path, @errorName(err) });
            continue;
        };
        text_match.blankComments(code);
        try files.append(arena, .{ .path = try arena.dupe(u8, entry.path), .code = code });
    }
    try findUnlisted(gpa, files.items, violations);
}

fn findUnlisted(gpa: std.mem.Allocator, files: []const File, violations: Violations) !void {
    var root_code: []u8 = &.{};
    for (files) |file| if (std.mem.eql(u8, file.path, root_file)) {
        root_code = file.code;
    };
    const list = readChecksList(root_code) orelse {
        try appendViolation(gpa, violations, no_list, .{checker_root});
        return;
    };
    for (files) |file| {
        if (!std.mem.startsWith(u8, file.path, modules_prefix)) continue;
        if (try isListed(gpa, root_code, list, file.path[modules_prefix.len..])) continue;
        var at: usize = 0;
        while (std.mem.find(u8, file.code[at..], "\npub fn check")) |rel| {
            const name_start = at + rel + "\npub fn ".len;
            at = name_start;
            var name_end = name_start;
            while (name_end < file.code.len and text_match.isIdentChar(file.code[name_end])) name_end += 1;
            if (!listsViolations(file.code, name_end)) continue;
            const name = file.code[name_start..name_end];
            if (std.mem.eql(u8, name, "check")) {
                try appendViolation(
                    gpa,
                    violations,
                    "{s}/{s}: `pub fn check` is not listed and its name finds no caller; " ++
                        "name the rule it enforces, as in `checkAdrCitations`, so a caller can be found",
                    .{ checker_dir, file.path },
                );
                continue;
            }
            if (mentionedElsewhere(files, file.path, name)) continue;
            try appendViolation(
                gpa,
                violations,
                "{s}/{s}: `pub fn {s}` takes the violations list but no other checker file names it, so its rule never runs; " ++
                    "list the module in `checks` in {s}, forward it from a listed module, or call it from one",
                .{ checker_dir, file.path, name, checker_root },
            );
        }
    }
}

/// True when the parameter list that opens at `at` names the violations list.
fn listsViolations(code: []const u8, at: usize) bool {
    if (at >= code.len or code[at] != '(') return false;
    var depth: usize = 0;
    for (code[at..], at..) |c, i| {
        if (c == '(') depth += 1;
        if (c == ')') {
            depth -= 1;
            if (depth == 0) return std.mem.find(u8, code[at..i], "*std.ArrayList([]const u8)") != null;
        }
    }
    return false;
}

fn mentionedElsewhere(files: []const File, own: []const u8, name: []const u8) bool {
    for (files) |file| {
        if (!std.mem.eql(u8, file.path, own) and text_match.containsAsSymbol(file.code, name)) return true;
    }
    return false;
}

fn sample(arena: std.mem.Allocator, path: []const u8, text: []const u8) !File {
    const code = try arena.dupe(u8, text);
    text_match.blankComments(code);
    return .{ .path = path, .code = code };
}

fn findings(files: []const File) !usize {
    const gpa = std.testing.allocator;
    var violations: std.ArrayList([]const u8) = .empty;
    defer {
        for (violations.items) |msg| gpa.free(msg);
        violations.deinit(gpa);
    }
    try findUnlisted(gpa, files, &violations);
    return violations.items.len;
}

const listing = "const l = @import(\"source_check/listed.zig\");\n\nconst checks = .{\n    l,\n};\n";

const planted =
    \\
    \\pub fn checkLoose(
    \\    gpa: std.mem.Allocator,
    \\    violations: *std.ArrayList([]const u8),
    \\) !void {}
    \\pub fn checkShape(text: []const u8) bool {}
    \\
;

test "an unlisted module's entry point that no other file names is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = try sample(a, "source_check.zig", listing);
    const listed = try sample(a, "source_check/listed.zig", planted);
    // A listed module's own entry points belong to the reflected loop.
    try std.testing.expectEqual(@as(usize, 0), try findings(&.{ root, listed }));

    const unlisted = try sample(a, "source_check/nested/deep.zig", planted);
    try std.testing.expectEqual(@as(usize, 1), try findings(&.{ root, unlisted }));
}

test "a bare `check`, a renamed parameter, and a missing list are findings" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = try sample(a, "source_check.zig", listing);
    // Every file contains the word `check`, so the name finds no caller.
    const bare = try sample(a, "source_check/deep.zig", "\npub fn check(gpa: std.mem.Allocator, found: *std.ArrayList([]const u8)) !void {}\n");
    const user = try sample(a, "source_check/user.zig", "fn f() void { check(); }\n");
    try std.testing.expectEqual(@as(usize, 1), try findings(&.{ root, bare, user }));

    // The parameter is found by its type, whatever it is called.
    const renamed = try sample(a, "source_check/deep.zig", "\npub fn checkLoose(found: *std.ArrayList([]const u8)) !void {}\n");
    try std.testing.expectEqual(@as(usize, 1), try findings(&.{ root, renamed }));

    // One finding names the unreadable list, not one per module.
    const no_list_root = try sample(a, "source_check.zig", "const x = 1;\n");
    const loose = try sample(a, "source_check/deep.zig", planted);
    const other = try sample(a, "source_check/other.zig", planted);
    try std.testing.expectEqual(@as(usize, 1), try findings(&.{ no_list_root, loose, other }));
}

test "another file naming the entry point, outside a comment, accepts it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = try sample(a, "source_check.zig", listing);
    const deep = try sample(a, "source_check/deep.zig", planted);
    const commented = try sample(a, "source_check/user.zig", "// try deep.checkLoose(gpa, &violations);\n");
    try std.testing.expectEqual(@as(usize, 1), try findings(&.{ root, deep, commented }));

    const caller = try sample(a, "source_check/user.zig", "fn f() !void { try deep.checkLoose(gpa, &violations); }\n");
    try std.testing.expectEqual(@as(usize, 0), try findings(&.{ root, deep, caller }));

    // A longer name that merely contains it does not count.
    const longer = try sample(a, "source_check/user.zig", "fn f() !void { try deep.checkLooseEnds(gpa, &violations); }\n");
    try std.testing.expectEqual(@as(usize, 1), try findings(&.{ root, deep, longer }));
}

const Probe = struct {
    pub fn checkStandard(_: std.Io, _: std.mem.Allocator, _: std.Io.Dir, _: Violations) error{Probe}!void {}
    pub fn checkExtra(_: std.Io, _: std.mem.Allocator, _: std.Io.Dir, _: Violations, _: []const u8) !void {}
    pub fn checkFewer(_: std.mem.Allocator, _: Violations) !void {}
    pub fn checkShape(_: []const u8) bool {
        return true;
    }
    pub fn checkFlag(_: std.Io, _: std.mem.Allocator, _: std.Io.Dir, _: Violations) !bool {
        return true;
    }
};

test "only the exact entry signature is an entry signature" {
    try std.testing.expect(comptime isEntrySignature(@TypeOf(Probe.checkStandard)));
    try std.testing.expect(!comptime isEntrySignature(@TypeOf(Probe.checkExtra)));
    try std.testing.expect(!comptime isEntrySignature(@TypeOf(Probe.checkFewer)));
    try std.testing.expect(!comptime isEntrySignature(@TypeOf(Probe.checkShape)));
    try std.testing.expect(!comptime isEntrySignature(@TypeOf(Probe.checkFlag)));
}

test "a module the checks list names, by import or alias, is listed" {
    const gpa = std.testing.allocator;
    const root_source = try gpa.dupe(u8,
        \\const aliased = @import("source_check/a.zig");
        \\const unlisted = @import("source_check/u.zig");
        \\
        \\const checks = .{
        \\    // @import("source_check/z.zig"),
        \\    @import("source_check/b/c.zig"),
        \\    aliased,
        \\};
        \\
    );
    defer gpa.free(root_source);
    const list = readChecksList(root_source).?;
    try std.testing.expect(try isListed(gpa, root_source, list, "a.zig"));
    try std.testing.expect(try isListed(gpa, root_source, list, "b/c.zig"));
    try std.testing.expect(!try isListed(gpa, root_source, list, "u.zig"));
    try std.testing.expect(!try isListed(gpa, root_source, list, "c.zig"));
    try std.testing.expect(!try isListed(gpa, root_source, list, "z.zig"));
    var unopened = "const checks = .{\n    x,\n".*;
    try std.testing.expect(readChecksList(&unopened) == null);
    var open_only = "const x = 1;\n".*;
    try std.testing.expect(readChecksList(&open_only) == null);
}
