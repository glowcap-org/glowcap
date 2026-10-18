//! The `bench-ab` step: one bench run alternately on a base revision and on
//! this tree, so both sides' numbers come from the same minutes of the same
//! machine. The base revision is archived once into `zig-out/scratch/ab/<rev>`
//! and built there with the same step and arguments, ReleaseFast on both
//! sides. Every line a run prints, on either stream, is read for the bench's
//! own `key=number` tokens: a line that carries one is a row, named by its
//! other tokens, and the table prints each row's metrics with the median of
//! each side, their ratio, and every pair's values.
//!
//! Usage, after the zig path the build step supplies:
//!   compare <zig> --base=<rev> [--pairs=N] <bench-step> [bench args...]

const std = @import("std");
const Io = std.Io;

const default_pairs = 3;
const scratch_root = "zig-out/scratch/ab";

const Args = struct {
    zig: []const u8,
    base: []const u8,
    pairs: usize,
    step: []const u8,
    bench_args: []const []const u8,
};

const Metric = struct { key: []const u8, text: []const u8, value: f64 };

/// One printed line that carried a metric: its non-metric tokens, joined,
/// name the row.
const Row = struct { identity: []const u8, metrics: []const Metric };

const Ctx = struct {
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    environ: ?*const std.process.Environ.Map,
    args: Args,
};

fn fail(comptime fmt: []const u8, args: anytype) error{BadArgument} {
    std.debug.print("bench-ab: " ++ fmt ++ "\n", args);
    return error.BadArgument;
}

fn usage() error{BadArgument} {
    return fail("usage: zig build bench-ab -- --base=<rev> [--pairs=N] <bench-step> [bench args...]", .{});
}

fn parseArgs(arena: std.mem.Allocator, raw: std.process.Args) !Args {
    var it = std.process.Args.Iterator.init(raw);
    _ = it.next();
    const zig = it.next() orelse return fail("missing the zig path the build step supplies", .{});
    var base: ?[]const u8 = null;
    var pairs: usize = default_pairs;
    var step: ?[]const u8 = null;
    while (it.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--base=")) {
            base = arg["--base=".len..];
        } else if (std.mem.startsWith(u8, arg, "--pairs=")) {
            pairs = std.fmt.parseInt(usize, arg["--pairs=".len..], 10) catch 0;
            if (pairs == 0) return fail("--pairs takes a positive count", .{});
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return fail("unknown option '{s}'", .{arg});
        } else {
            step = arg;
            break;
        }
    }
    var rest: std.ArrayList([]const u8) = .empty;
    while (it.next()) |arg| try rest.append(arena, arg);
    return .{
        .zig = zig,
        .base = base orelse return usage(),
        .pairs = pairs,
        .step = step orelse return usage(),
        .bench_args = rest.items,
    };
}

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    var ctx: Ctx = .{
        .io = init.io,
        .gpa = init.gpa,
        .arena = arena_state.allocator(),
        .environ = init.environ_map,
        .args = try parseArgs(arena_state.allocator(), init.minimal.args),
    };
    const base_dir = try prepareBase(&ctx);

    const pairs = ctx.args.pairs;
    const base_runs = try ctx.arena.alloc([]const Row, pairs);
    const tree_runs = try ctx.arena.alloc([]const Row, pairs);
    std.debug.print("bench-ab: building and warming both trees\n", .{});
    _ = try runBench(&ctx, base_dir);
    _ = try runBench(&ctx, null);
    for (0..pairs) |i| {
        // Reverse the order every other pair, so a drift across the run lands
        // on both sides equally.
        std.debug.print("bench-ab: pair {d} of {d}\n", .{ i + 1, pairs });
        if (i % 2 == 0) {
            base_runs[i] = try runBench(&ctx, base_dir);
            tree_runs[i] = try runBench(&ctx, null);
        } else {
            tree_runs[i] = try runBench(&ctx, null);
            base_runs[i] = try runBench(&ctx, base_dir);
        }
    }
    try report(&ctx, base_dir, base_runs, tree_runs);
}

/// The archived base tree, extracted once per revision. An interrupted
/// extraction leaves only the `.partial` directory, which the next run
/// replaces; the rename is the commit point.
fn prepareBase(ctx: *Ctx) ![]const u8 {
    const resolved = try runCapture(ctx, null, &.{ "git", "rev-parse", "--short=9", "--verify", try std.fmt.allocPrint(ctx.arena, "{s}^{{commit}}", .{ctx.args.base}) });
    const id = std.mem.trim(u8, resolved, " \n\r\t");
    const dir = try std.fmt.allocPrint(ctx.arena, scratch_root ++ "/{s}", .{id});
    const cwd = Io.Dir.cwd();
    if (cwd.access(ctx.io, dir, .{})) |_| {
        std.debug.print("bench-ab: base {s} already extracted at {s}\n", .{ id, dir });
        return dir;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    std.debug.print("bench-ab: extracting base {s} into {s}\n", .{ id, dir });
    const partial = try std.fmt.allocPrint(ctx.arena, "{s}.partial", .{dir});
    const tar = try std.fmt.allocPrint(ctx.arena, "{s}.tar", .{dir});
    try cwd.deleteTree(ctx.io, partial);
    try cwd.createDirPath(ctx.io, partial);
    _ = try runCapture(ctx, null, &.{ "git", "archive", "--format=tar", "-o", tar, id });
    _ = try runCapture(ctx, null, &.{ "tar", "-xf", tar, "-C", partial });
    try cwd.deleteFile(ctx.io, tar);
    try cwd.rename(partial, cwd, dir, ctx.io);
    return dir;
}

/// Run the bench step in `cwd` (null for this tree) and read its rows from
/// everything it printed: the benches report on stderr, as `std.debug.print`
/// does, and a build message on either stream carries no `key=number` token.
fn runBench(ctx: *Ctx, cwd: ?[]const u8) ![]const Row {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(ctx.gpa);
    try argv.appendSlice(ctx.gpa, &.{ ctx.args.zig, "build", ctx.args.step, "-Doptimize=ReleaseFast" });
    if (ctx.args.bench_args.len > 0) {
        try argv.append(ctx.gpa, "--");
        try argv.appendSlice(ctx.gpa, ctx.args.bench_args);
    }
    const printed = try runCapture(ctx, cwd, argv.items);
    return parseRows(ctx.arena, printed);
}

/// Run `argv` to completion and return what it printed on both streams,
/// stdout then stderr, arena-owned. A failure prints the command's stderr,
/// since that is where the build or the bench said what went wrong.
fn runCapture(ctx: *Ctx, cwd: ?[]const u8, argv: []const []const u8) ![]const u8 {
    const result = try std.process.run(ctx.gpa, ctx.io, .{
        .argv = argv,
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
        .environ_map = ctx.environ,
    });
    defer ctx.gpa.free(result.stdout);
    defer ctx.gpa.free(result.stderr);
    if (!result.term.success()) {
        std.debug.print("bench-ab: '{s}' failed in {s}:\n{s}", .{ argv[2], cwd orelse "this tree", result.stderr });
        return error.CommandFailed;
    }
    return std.mem.concat(ctx.arena, u8, &.{ result.stdout, "\n", result.stderr });
}

/// Every line that carries a `key=number` token is a row. A value's numeric
/// prefix is the number and a unit suffix (letters, `/`, `%`) joins the key,
/// so `p50=0.03ms` is the metric `p50[ms]` and `setup=1.2ms/conn` is
/// `setup[ms/conn]`. Anything else after the number, as in `pin=2,3`, is a
/// setting and names the row.
fn parseRows(arena: std.mem.Allocator, text: []const u8) ![]const Row {
    var rows: std.ArrayList(Row) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var identity: std.ArrayList(u8) = .empty;
        var metrics: std.ArrayList(Metric) = .empty;
        var tokens = std.mem.tokenizeAny(u8, line, " \t\r");
        while (tokens.next()) |token| {
            if (parseMetric(arena, token) catch null) |metric| {
                try metrics.append(arena, metric);
            } else {
                if (identity.items.len > 0) try identity.append(arena, ' ');
                try identity.appendSlice(arena, token);
            }
        }
        if (metrics.items.len == 0) continue;
        try rows.append(arena, .{ .identity = identity.items, .metrics = metrics.items });
    }
    return rows.items;
}

fn parseMetric(arena: std.mem.Allocator, token: []const u8) !?Metric {
    const eq = std.mem.indexOfScalar(u8, token, '=') orelse return null;
    if (eq == 0) return null;
    const text = token[eq + 1 ..];
    var digits: usize = 0;
    while (digits < text.len and std.mem.indexOfScalar(u8, "0123456789.+-", text[digits]) != null) digits += 1;
    if (digits == 0) return null;
    const value = std.fmt.parseFloat(f64, text[0..digits]) catch return null;
    for (text[digits..]) |c| if (!std.ascii.isAlphabetic(c) and c != '/' and c != '%') return null;
    const key = if (digits == text.len) token[0..eq] else try std.fmt.allocPrint(arena, "{s}[{s}]", .{ token[0..eq], text[digits..] });
    return .{ .key = key, .text = text, .value = value };
}

/// The `n`th row named `identity` in one run, so a bench that prints one
/// identity several times still lines up pair by pair.
fn nth(rows: []const Row, identity: []const u8, n: usize) ?Row {
    var seen: usize = 0;
    for (rows) |row| {
        if (!std.mem.eql(u8, row.identity, identity)) continue;
        if (seen == n) return row;
        seen += 1;
    }
    return null;
}

fn metricOf(row: ?Row, key: []const u8) ?Metric {
    const r = row orelse return null;
    for (r.metrics) |m| if (std.mem.eql(u8, m.key, key)) return m;
    return null;
}

fn median(values: []f64) f64 {
    std.mem.sort(f64, values, {}, std.sort.asc(f64));
    const mid = values.len / 2;
    return if (values.len % 2 == 1) values[mid] else (values[mid - 1] + values[mid]) / 2;
}

/// The decimal places a bench printed a value with: `68.2` has one, `70` none.
fn places(text: []const u8) usize {
    const point = std.mem.indexOfScalar(u8, text, '.') orelse return 0;
    var count: usize = 0;
    while (point + 1 + count < text.len and std.ascii.isDigit(text[point + 1 + count])) count += 1;
    return count;
}

/// A median printed with the most places any of its inputs carried, so it
/// reads like the bench's own rows.
fn number(buf: []u8, value: f64, precision: usize) ![]const u8 {
    return std.fmt.bufPrint(buf, "{[value]d:.[precision]}", .{ .value = value, .precision = precision });
}

/// The table: one block per row of the tree's first run, one line per
/// metric. A side that lacks the row in a pair prints `-` there and its
/// median counts the pairs it has.
fn report(ctx: *Ctx, base_dir: []const u8, base_runs: []const []const Row, tree_runs: []const []const Row) !void {
    var buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writer(ctx.io, &buf);
    const w = &stdout.interface;
    try w.print("bench-ab: {s} on base {s} and this tree, {d} pairs, ReleaseFast", .{ ctx.args.step, base_dir[scratch_root.len + 1 ..], base_runs.len });
    for (ctx.args.bench_args) |arg| try w.print(" {s}", .{arg});
    try w.writeAll("\n");
    const template = tree_runs[0];
    for (template, 0..) |row, j| {
        var occurrence: usize = 0;
        for (template[0..j]) |earlier| {
            if (std.mem.eql(u8, earlier.identity, row.identity)) occurrence += 1;
        }
        try w.print("\n{s}\n", .{row.identity});
        try w.print("  {s:<24} {s:>14} {s:>14} {s:>10}   pairs base|tree\n", .{ "metric", "base", "tree", "tree/base" });
        for (row.metrics) |metric| {
            var base_values: std.ArrayList(f64) = .empty;
            var tree_values: std.ArrayList(f64) = .empty;
            var pairs: std.ArrayList(u8) = .empty;
            var precision: usize = 0;
            for (base_runs, tree_runs) |base_run, tree_run| {
                const b = metricOf(nth(base_run, row.identity, occurrence), metric.key);
                const t = metricOf(nth(tree_run, row.identity, occurrence), metric.key);
                if (b) |m| try base_values.append(ctx.arena, m.value);
                if (t) |m| try tree_values.append(ctx.arena, m.value);
                for ([_]?Metric{ b, t }) |side| if (side) |m| {
                    precision = @max(precision, places(m.text));
                };
                try pairs.print(ctx.arena, " {s}|{s}", .{ if (b) |m| m.text else "-", if (t) |m| m.text else "-" });
            }
            var base_buf: [400]u8 = undefined;
            var tree_buf: [400]u8 = undefined;
            try w.print("  {s:<24}", .{metric.key});
            try w.print(" {s:>14}", .{if (base_values.items.len > 0) try number(&base_buf, median(base_values.items), precision) else "-"});
            try w.print(" {s:>14}", .{if (tree_values.items.len > 0) try number(&tree_buf, median(tree_values.items), precision) else "-"});
            if (base_values.items.len > 0 and tree_values.items.len > 0 and median(base_values.items) != 0) {
                try w.print(" {d:>10.3}", .{median(tree_values.items) / median(base_values.items)});
            } else {
                try w.print(" {s:>10}", .{"-"});
            }
            try w.print("  {s}\n", .{pairs.items});
        }
    }
    try w.flush();
}

test "rows are the lines with key=number tokens, named by the rest" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const rows = try parseRows(arena_state.allocator(), "building\nroundtrip transport=tcp call=greet p50_ns=19340 rps=51000.5 pin=2,3\n  zig (zig) p50=0.03ms setup=1.2ms/conn\n");
    try std.testing.expectEqual(2, rows.len);
    try std.testing.expectEqualStrings("roundtrip transport=tcp call=greet pin=2,3", rows[0].identity);
    try std.testing.expectEqual(2, rows[0].metrics.len);
    try std.testing.expectEqualStrings("p50_ns", rows[0].metrics[0].key);
    try std.testing.expectEqual(19340, rows[0].metrics[0].value);
    try std.testing.expectEqual(51000.5, rows[0].metrics[1].value);
    try std.testing.expectEqualStrings("zig (zig)", rows[1].identity);
    try std.testing.expectEqualStrings("p50[ms]", rows[1].metrics[0].key);
    try std.testing.expectEqualStrings("0.03ms", rows[1].metrics[0].text);
    try std.testing.expectEqualStrings("setup[ms/conn]", rows[1].metrics[1].key);
}

test "the nth row of one identity lines up repeated rows" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const rows = try parseRows(arena_state.allocator(), "row a=1\nrow a=2\nother a=3\n");
    try std.testing.expectEqual(2, nth(rows, "row", 1).?.metrics[0].value);
    try std.testing.expectEqual(null, nth(rows, "row", 2));
    try std.testing.expectEqual(3, metricOf(nth(rows, "other", 0), "a").?.value);
    try std.testing.expectEqual(null, metricOf(nth(rows, "other", 0), "b"));
}

test "a median prints with the places its inputs carried" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqual(1, places("68.2"));
    try std.testing.expectEqual(0, places("70"));
    try std.testing.expectEqual(2, places("1.25ms"));
    try std.testing.expectEqualStrings("68.1", try number(&buf, 68.1, places("68.2")));
    try std.testing.expectEqualStrings("70", try number(&buf, 70, places("70")));
}

test "median of an even count averages the middle pair" {
    var even = [_]f64{ 4, 1, 3, 2 };
    try std.testing.expectEqual(2.5, median(&even));
    var odd = [_]f64{ 9, 1, 5 };
    try std.testing.expectEqual(5, median(&odd));
}
