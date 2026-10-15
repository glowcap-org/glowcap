//! Write the numbers docs quote from code.
//!
//! A doc that states a limit the code declares marks it:
//!
//!     at most <!-- value rust/src/history.rs LINES_KEPT -->500<!-- /value --> lines
//!
//! The path is relative to the doc, the name is a `const` or a struct field
//! default in that file, and an optional third word picks the form: `bytes`
//! renders `64 MiB`, `seconds` renders `1.2 seconds`, `milliseconds` renders
//! a millisecond count as seconds, `plain` renders bare digits for a number
//! that names something (a port), and the default renders a count such as
//! `4,096`.
//! This tool reads each constant and rewrites the text between the markers, so
//! the code stays the one home of the number. `check` fails when a doc is
//! stale or names a constant it cannot read.
//!
//! Usage: gen-doc-values write|check

const std = @import("std");
const kinds = @import("doc_kinds");

const open_tag = "<!-- value ";
const close_tag = "<!-- /value -->";

const Form = enum { count, bytes, seconds, milliseconds, plain };

/// A constant's value. A `Duration` is held in milliseconds.
const Value = struct { n: u64, millis: bool = false };

const EvalError = error{ ConstantChainTooDeep, ConstantNotFound, ConstantHasNoValue, ValueOverflows, NotAnInteger };

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const mode = args.next() orelse return usage();
    const check = if (std.mem.eql(u8, mode, "check")) true else if (std.mem.eql(u8, mode, "write")) false else return usage();

    const cwd = std.Io.Dir.cwd();
    var failed = false;
    var docs: std.ArrayList([]const u8) = .empty;
    for (kinds.root_docs) |path| try docs.append(gpa, path);
    for (kinds.doc_trees) |tree| try collect(io, gpa, cwd, tree, &docs);

    for (docs.items) |path| {
        const text = cwd.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch |err| switch (err) {
            // tolerant: a root doc this checkout does not carry quotes nothing.
            error.FileNotFound => continue,
            else => {
                std.debug.print("gen-doc-values: {s}: cannot read it ({s})\n", .{ path, @errorName(err) });
                failed = true;
                continue;
            },
        };
        if (std.mem.indexOf(u8, text, open_tag) == null) continue;
        const rendered = render(io, gpa, cwd, path, text) catch |err| {
            std.debug.print("gen-doc-values: {s}: {s}\n", .{ path, @errorName(err) });
            failed = true;
            continue;
        };
        if (std.mem.eql(u8, rendered, text)) continue;
        if (check) {
            std.debug.print("gen-doc-values: {s} quotes a stale value. Run `zig build gen-doc-values` and commit it.\n", .{path});
            failed = true;
        } else try cwd.writeFile(io, .{ .sub_path = path, .data = rendered });
    }
    if (failed) std.process.exit(1);
}

fn usage() void {
    std.debug.print("usage: gen-doc-values write|check\n", .{});
    std.process.exit(2);
}

fn collect(io: std.Io, gpa: std.mem.Allocator, cwd: std.Io.Dir, tree: []const u8, out: *std.ArrayList([]const u8)) !void {
    var dir = cwd.openDir(io, tree, .{ .iterate = true }) catch |err| switch (err) {
        // tolerant: a doc tree this checkout does not carry holds no markers.
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);
    var walker = try dir.walkSelectively(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) {
            if (!std.mem.eql(u8, entry.basename, "node_modules") and !std.mem.eql(u8, entry.basename, "target")) try walker.enter(io, entry);
            continue;
        }
        if (entry.kind != .file) continue;
        const path = try std.fs.path.join(gpa, &.{ tree, entry.path });
        if (kinds.isDoc(path)) try out.append(gpa, path);
    }
}

/// The doc with every marked value rewritten from its constant.
fn render(io: std.Io, gpa: std.mem.Allocator, cwd: std.Io.Dir, doc: []const u8, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    if (std.mem.endsWith(u8, doc, ".smd") and std.mem.indexOf(u8, text, open_tag) != null) {
        std.debug.print("gen-doc-values: {s}: the site renderer forbids HTML comments, so a site page links the repo doc that quotes the value\n", .{doc});
        return error.MarkerInSitePage;
    }
    while (std.mem.indexOfPos(u8, text, at, open_tag)) |open| {
        const spec_start = open + open_tag.len;
        const spec_end = std.mem.indexOfPos(u8, text, spec_start, "-->") orelse return error.UnclosedMarker;
        const value_start = spec_end + "-->".len;
        const close = std.mem.indexOfPos(u8, text, value_start, close_tag) orelse return error.MissingCloseMarker;
        var words = std.mem.tokenizeScalar(u8, text[spec_start..spec_end], ' ');
        const rel = words.next() orelse return error.MarkerNamesNoFile;
        const name = words.next() orelse return error.MarkerNamesNoConstant;
        const form: Form = if (words.next()) |word| std.meta.stringToEnum(Form, word) orelse return error.UnknownForm else .count;

        const source_path = try std.fs.path.resolvePosix(gpa, &.{ std.fs.path.dirname(doc) orelse ".", rel });
        const source = cwd.readFileAlloc(io, source_path, gpa, .limited(4 << 20)) catch {
            std.debug.print("gen-doc-values: {s}: cannot read `{s}`\n", .{ doc, source_path });
            return error.SourceUnreadable;
        };
        const value = constant(source, name, 0) catch |err| {
            std.debug.print("gen-doc-values: {s}: `{s}` in `{s}` ({s})\n", .{ doc, name, source_path, @errorName(err) });
            return err;
        };
        try out.appendSlice(gpa, text[at..value_start]);
        try format(gpa, &out, value, form);
        at = close;
    }
    try out.appendSlice(gpa, text[at..]);
    return out.items;
}

/// The value of `const NAME: T = expr;` in `source`, or of a struct field
/// default `NAME: T = expr,` on its own line or after `{` or `,` (the first one
/// in the file): a product of integer literals, `Duration::from_secs`/
/// `from_millis` calls, and other constants in the same file.
fn constant(source: []const u8, name: []const u8, depth: u8) EvalError!Value {
    if (depth > 8) return error.ConstantChainTooDeep;
    const decl = declaration(source, name) orelse return error.ConstantNotFound;
    const eq = std.mem.indexOfScalarPos(u8, source, decl.start, '=') orelse return error.ConstantHasNoValue;
    const end = std.mem.indexOfAnyPos(u8, source, eq, if (decl.field) ",\n}" else ";") orelse return error.ConstantHasNoValue;
    var result = Value{ .n = 1 };
    var factors = std.mem.splitScalar(u8, source[eq + 1 .. end], '*');
    while (factors.next()) |raw| {
        const factor = try term(source, std.mem.trim(u8, raw, " \t\n"), depth);
        result.n = std.math.mul(u64, result.n, factor.n) catch return error.ValueOverflows;
        result.millis = result.millis or factor.millis;
    }
    return result;
}

/// Where `name`'s declaration continues, and whether it is a field default.
fn declaration(source: []const u8, name: []const u8) ?struct { start: usize, field: bool } {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, source, at, name)) |hit| {
        at = hit + name.len;
        const after = source[at..];
        if (after.len == 0 or (after[0] != ':' and after[0] != ' ')) continue;
        if (std.mem.endsWith(u8, source[0..hit], "const ")) return .{ .start = at, .field = false };
        const line = std.mem.trim(u8, source[(std.mem.lastIndexOfScalar(u8, source[0..hit], '\n') orelse 0)..hit], " \t\n");
        const opens_field = line.len == 0 or line[line.len - 1] == '{' or line[line.len - 1] == ',';
        if (after[0] == ':' and opens_field) return .{ .start = at, .field = true };
    }
    return null;
}

fn term(source: []const u8, text: []const u8, depth: u8) EvalError!Value {
    if (call(text, "Duration::from_secs(")) |inner| return .{ .n = 1000 * try integer(inner), .millis = true };
    if (call(text, "Duration::from_millis(")) |inner| return .{ .n = try integer(inner), .millis = true };
    if (text.len > 0 and std.ascii.isDigit(text[0])) return .{ .n = try integer(text) };
    const last = if (std.mem.lastIndexOf(u8, text, "::")) |sep| text[sep + 2 ..] else text;
    return constant(source, last, depth + 1);
}

fn call(text: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, text, prefix) or !std.mem.endsWith(u8, text, ")")) return null;
    return text[prefix.len .. text.len - 1];
}

fn integer(text: []const u8) EvalError!u64 {
    var n: u64 = 0;
    for (text) |c| switch (c) {
        '_' => {},
        '0'...'9' => n = std.math.add(u64, std.math.mul(u64, n, 10) catch return error.ValueOverflows, c - '0') catch return error.ValueOverflows,
        else => return error.NotAnInteger,
    };
    return n;
}

fn format(gpa: std.mem.Allocator, out: *std.ArrayList(u8), value: Value, form: Form) !void {
    switch (form) {
        .count => try grouped(gpa, out, value.n),
        .plain => try out.print(gpa, "{d}", .{value.n}),
        .bytes => {
            const units = [_]struct { size: u64, name: []const u8 }{
                .{ .size = 1 << 30, .name = "GiB" }, .{ .size = 1 << 20, .name = "MiB" }, .{ .size = 1 << 10, .name = "KiB" },
            };
            for (units) |unit| if (value.n >= unit.size and value.n % unit.size == 0) {
                return out.print(gpa, "{d} {s}", .{ value.n / unit.size, unit.name });
            };
            try grouped(gpa, out, value.n);
            try out.appendSlice(gpa, " bytes");
        },
        .seconds, .milliseconds => {
            const millis = if (value.millis or form == .milliseconds) value.n else value.n * 1000;
            try out.print(gpa, "{d}", .{millis / 1000});
            if (millis % 1000 != 0) {
                var frac = millis % 1000;
                var digits: [3]u8 = undefined;
                var len: usize = 3;
                while (frac % 10 == 0) : (len -= 1) frac /= 10;
                _ = std.fmt.bufPrint(&digits, "{d:0>3}", .{millis % 1000}) catch unreachable;
                try out.print(gpa, ".{s}", .{digits[0..len]});
            }
            try out.appendSlice(gpa, if (millis == 1000) " second" else " seconds");
        },
    }
}

/// `4096` as `4,096`.
fn grouped(gpa: std.mem.Allocator, out: *std.ArrayList(u8), n: u64) !void {
    var buf: [32]u8 = undefined;
    const digits = std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable;
    for (digits, 0..) |c, i| {
        if (i > 0 and (digits.len - i) % 3 == 0) try out.append(gpa, ',');
        try out.append(gpa, c);
    }
}

test "constants evaluate through products, durations and names" {
    const source =
        \\pub const LINES_KEPT: usize = 500;
        \\const FILE_BYTES: usize = 64 * 1024 * 1024;
        \\pub const COMPACT_AT: usize = LINES_KEPT * 2;
        \\const INTERVAL: Duration = Duration::from_millis(1_200);
        \\const WAIT_MS = 30_000;
        \\pub const Options = struct {
        \\    max_calls: usize = 64,
        \\    call_bytes: usize = 16 * 1024,
        \\};
        \\pub const Inline = struct { max_names: usize = 16, max_fetches: usize = LINES_KEPT };
    ;
    try std.testing.expectEqual(@as(u64, 500), (try constant(source, "LINES_KEPT", 0)).n);
    try std.testing.expectEqual(@as(u64, 1000), (try constant(source, "COMPACT_AT", 0)).n);
    try std.testing.expectError(error.ConstantNotFound, constant(source, "LINES", 0));
    try std.testing.expectEqual(@as(u64, 64), (try constant(source, "max_calls", 0)).n);
    try std.testing.expectEqual(@as(u64, 16384), (try constant(source, "call_bytes", 0)).n);
    try std.testing.expectEqual(@as(u64, 16), (try constant(source, "max_names", 0)).n);
    try std.testing.expectEqual(@as(u64, 500), (try constant(source, "max_fetches", 0)).n);
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try format(gpa, &out, try constant(source, "FILE_BYTES", 0), .bytes);
    try out.append(gpa, '|');
    try format(gpa, &out, try constant(source, "INTERVAL", 0), .seconds);
    try out.append(gpa, '|');
    try format(gpa, &out, .{ .n = 4096 }, .count);
    try out.append(gpa, '|');
    try format(gpa, &out, try constant(source, "WAIT_MS", 0), .milliseconds);
    try std.testing.expectEqualStrings("64 MiB|1.2 seconds|4,096|30 seconds", out.items);
}
