//! The Python binding's ctypes signature factory, held to the arity of the
//! generated FFI facts it wraps.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;
const expectFileContains = util.expectFileContains;
const fileContains = util.fileContains;
const containsAsSymbol = util.containsAsSymbol;
const extractBraceBlock = util.extractBraceBlock;

/// The generated Python signature tables are factories the hand-written FFI
/// loaders call, passing the ctypes mirrors positionally: one archive per
/// `<name>_sigs`, whose parameter list is decided by which symbols the archive's
/// inventory actually declares. Omitting a symbol can therefore drop a
/// parameter, and Python only says so when the loader runs, which is a runtime
/// step rather than `check`. This holds each call's argument list to the
/// generated declaration.
pub fn checkPythonSigsFactoryArity(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const gen_path = "bindings/python/pancake/_sigs_gen.py";
    const gen = root.readFileAlloc(io, gen_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for the sigs-factory arity check with {s}", .{ gen_path, @errorName(err) });
        return;
    };
    defer gpa.free(gen);

    var dir = root.openDir(io, "bindings/python/pancake", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "bindings/python/pancake: failed to open for the sigs-factory arity check with {s}", .{@errorName(err)});
        return;
    };
    defer dir.close(io);

    var factories: usize = 0;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, gen, from, "\ndef ")) |at| {
        const name_start = at + "\ndef ".len;
        const open = std.mem.indexOfScalarPos(u8, gen, name_start, '(') orelse break;
        from = open;
        const name = gen[name_start..open];
        if (!std.mem.endsWith(u8, name, "_sigs")) continue;
        const declared = parenArgList(gen, open) orelse continue;
        factories += 1;

        // The one hand-written caller: `_bind(facade, lib, <name>(…))` or a
        // `sigs = <name>(…)` binding, in this package's loader for that archive.
        var walker = try dir.walkSelectively(gpa);
        defer walker.deinit();
        var found = false;
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".py")) continue;
            if (std.mem.eql(u8, entry.basename, "_sigs_gen.py")) continue;
            const src = dir.readFileAlloc(io, entry.path, gpa, .limited(1 << 20)) catch continue;
            defer gpa.free(src);
            var scan: usize = 0;
            while (std.mem.indexOfPos(u8, src, scan, name)) |site| {
                scan = site + 1;
                if (site + name.len >= src.len or src[site + name.len] != '(') continue;
                if (site > 0 and (std.ascii.isAlphanumeric(src[site - 1]) or src[site - 1] == '_')) continue;
                const passed = parenArgList(src, site + name.len) orelse continue;
                found = true;
                if (!argListsEqual(declared, passed)) {
                    const want = try joinArgList(gpa, declared);
                    defer gpa.free(want);
                    const got = try joinArgList(gpa, passed);
                    defer gpa.free(got);
                    try appendViolation(gpa, violations, "bindings/python/pancake/{s}: `{s}(…)` passes ({s}) but {s} declares ({s}) — a symbol's `python_omit` changed the generated parameter list; match the call, since Python only refuses this when the loader runs", .{ entry.path, name, got, gen_path, want });
                }
            }
        }
        if (!found) {
            try appendViolation(gpa, violations, "{s}: `{s}` has no caller under bindings/python/pancake — a generated signature table nothing loads, or the arity scanner no longer matches", .{ gen_path, name });
        }
    }
    if (factories == 0) {
        try appendViolation(gpa, violations, "{s}: found no `*_sigs` factories — the arity scanner no longer matches this generated table", .{gen_path});
    }
}

/// The text between the parenthesis at `open` and its match, or null when the
/// parentheses do not balance within the file.
fn parenArgList(src: []const u8, open: usize) ?[]const u8 {
    var depth: usize = 0;
    var i = open;
    while (i < src.len) : (i += 1) {
        switch (src[i]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return src[open + 1 .. i];
            },
            else => {},
        }
    }
    return null;
}

/// Whether two argument lists name the same identifiers in the same order,
/// ignoring the whitespace and trailing commas the two spellings differ on.
fn argListsEqual(a: []const u8, b: []const u8) bool {
    var it_a = argIter(a);
    var it_b = argIter(b);
    while (true) {
        const next_a = it_a.next();
        const next_b = it_b.next();
        if (next_a == null and next_b == null) return true;
        if (next_a == null or next_b == null) return false;
        if (!std.mem.eql(u8, next_a.?, next_b.?)) return false;
    }
}

const ArgIter = struct {
    rest: []const u8,

    fn next(self: *ArgIter) ?[]const u8 {
        while (self.rest.len != 0) {
            const at = std.mem.indexOfScalar(u8, self.rest, ',') orelse self.rest.len;
            const item = std.mem.trim(u8, self.rest[0..at], " \t\n\r");
            self.rest = if (at == self.rest.len) self.rest[at..] else self.rest[at + 1 ..];
            if (item.len != 0) return item;
        }
        return null;
    }
};

fn argIter(list: []const u8) ArgIter {
    return .{ .rest = list };
}

/// An argument list on one line, for a violation message the two spellings'
/// own line breaks would otherwise render unreadably.
fn joinArgList(gpa: std.mem.Allocator, list: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var it = argIter(list);
    var first = true;
    while (it.next()) |item| {
        if (!first) try out.appendSlice(gpa, ", ");
        first = false;
        try out.appendSlice(gpa, item);
    }
    return out.toOwnedSlice(gpa);
}
