//! The report behind the `profile-*` steps: for each phase a bench marked,
//! the self cost per source file and per function, and the callers of the
//! leaf functions at the top, read from the callgrind parts of one run and
//! written beside them as one markdown page.
//!
//! Inclusive cost and call trees follow inlining in a ReleaseFast build, so
//! they mislead. Self cost by file and by function does not, and that is what
//! the report ranks. A leaf's cost at each call site is exact, so the callers
//! of a generic helper such as memcpy say whose copy it was. Ir counts
//! instructions, so two runs of one build compare exactly on any machine.
const std = @import("std");
const callgrind = @import("callgrind.zig");
const Part = callgrind.Part;

const top_files = 12;
const top_functions = 24;
const top_leaves = 4;
const top_callers = 6;
const parts_suffix = ".callgrind";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const prefix = args.next() orelse return error.MissingPrefix;
    if (args.next() != null) return error.InvalidArguments;
    if (!std.mem.endsWith(u8, prefix, parts_suffix)) return error.InvalidPrefix;
    const dir_path = std.fs.path.dirname(prefix) orelse ".";
    const base = std.fs.path.basename(prefix);
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var parts: std.ArrayList(Part) = .empty;
    defer {
        for (parts.items) |*part| part.deinit(gpa);
        parts.deinit(gpa);
    }
    // callgrind writes the base file at exit, so its pid names this run and
    // keeps an earlier run's parts of the same name out.
    const final = try dir.readFileAlloc(io, base, gpa, .limited(1 << 30));
    defer gpa.free(final);
    const pid = callgrind.headerValue(final, "pid:") orelse return error.NotCallgrind;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory or !callgrind.isPart(entry.name, base)) continue;
        const bytes = try dir.readFileAlloc(io, entry.name, gpa, .limited(1 << 30));
        defer gpa.free(bytes);
        if (!std.mem.eql(u8, callgrind.headerValue(bytes, "pid:") orelse "", pid)) continue;
        var part = try callgrind.parsePart(gpa, bytes);
        if (part.total == 0) {
            part.deinit(gpa);
            continue;
        }
        try parts.append(gpa, part);
    }
    std.mem.sort(Part, parts.items, {}, Part.earlier);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const name = base[0 .. base.len - parts_suffix.len];
    try render(gpa, &out, name, parts.items);
    const report_path = try std.fmt.allocPrint(gpa, "{s}/{s}.md", .{ dir_path, name });
    defer gpa.free(report_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = report_path, .data = out.items });
    std.debug.print("{s}\nprofile report written to {s}\n", .{ out.items, report_path });
}

const Entry = struct {
    name: []const u8,
    cost: u64,

    fn costlier(_: void, a: Entry, b: Entry) bool {
        return a.cost > b.cost or (a.cost == b.cost and std.mem.lessThan(u8, a.name, b.name));
    }
};

fn ranked(gpa: std.mem.Allocator, map: *const std.StringHashMapUnmanaged(u64)) ![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(gpa);
    var items = map.iterator();
    while (items.next()) |item| try entries.append(gpa, .{ .name = item.key_ptr.*, .cost = item.value_ptr.* });
    std.mem.sort(Entry, entries.items, {}, Entry.costlier);
    return entries.toOwnedSlice(gpa);
}

fn render(gpa: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, parts: []const Part) !void {
    try print(gpa, out, "# {s} profile\n\nEach marked phase is one callgrind part. Ir is the instructions the phase executed, which a run of the same build repeats exactly. Self cost is ranked because inclusive cost follows inlining.\n\n| Part | Phase | Ir |\n| ---: | --- | ---: |\n", .{name});
    for (parts) |part| try print(gpa, out, "| {d} | {s} | {f} |\n", .{ part.number, part.trigger, grouped(part.total) });
    for (parts) |*part| {
        try print(gpa, out, "\n## {s} (part {d})\n\nSelf cost by file:\n\n| Ir | Share | File |\n| ---: | ---: | --- |\n", .{ part.trigger, part.number });
        try ranking(gpa, out, &part.files, part.total, top_files);
        try print(gpa, out, "\nSelf cost by function:\n\n| Ir | Share | Function |\n| ---: | ---: | --- |\n", .{});
        const functions = try ranked(gpa, &part.functions);
        defer gpa.free(functions);
        for (functions[0..@min(functions.len, top_functions)]) |entry| try row(gpa, out, entry, part.total);
        try leafCallers(gpa, out, part, functions);
    }
}

/// The callers of the leaf functions among the top of the ranking, each
/// call site with its calls and the instructions the leaf ran for it.
fn leafCallers(gpa: std.mem.Allocator, out: *std.ArrayList(u8), part: *const Part, functions: []const Entry) !void {
    var shown: usize = 0;
    for (functions[0..@min(functions.len, top_functions)]) |leaf| {
        if (shown == top_leaves) break;
        if (!part.isLeaf(leaf.name)) continue;
        const sites = part.call_sites.getPtr(leaf.name) orelse continue;
        shown += 1;
        try print(gpa, out, "\nCallers of `{s}`:\n\n| Ir | Calls | Caller |\n| ---: | ---: | --- |\n", .{leaf.name});
        var entries: std.ArrayList(Entry) = .empty;
        defer entries.deinit(gpa);
        var items = sites.iterator();
        while (items.next()) |item| try entries.append(gpa, .{ .name = item.key_ptr.*, .cost = item.value_ptr.cost });
        std.mem.sort(Entry, entries.items, {}, Entry.costlier);
        for (entries.items[0..@min(entries.items.len, top_callers)]) |entry| {
            try print(gpa, out, "| {f} | {f} | {s} |\n", .{ grouped(entry.cost), grouped(sites.get(entry.name).?.calls), entry.name });
        }
    }
}

fn ranking(gpa: std.mem.Allocator, out: *std.ArrayList(u8), map: *const std.StringHashMapUnmanaged(u64), total: u64, limit: usize) !void {
    const entries = try ranked(gpa, map);
    defer gpa.free(entries);
    for (entries[0..@min(entries.len, limit)]) |entry| try row(gpa, out, entry, total);
}

fn row(gpa: std.mem.Allocator, out: *std.ArrayList(u8), entry: Entry, total: u64) !void {
    const share = @as(f64, @floatFromInt(entry.cost)) * 100 / @as(f64, @floatFromInt(@max(total, 1)));
    try print(gpa, out, "| {f} | {d:.1}% | {s} |\n", .{ grouped(entry.cost), share, entry.name });
}

fn print(gpa: std.mem.Allocator, out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(text);
    try out.appendSlice(gpa, text);
}

const Grouped = struct {
    buffer: [27]u8,
    len: usize,

    pub fn format(self: Grouped, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(self.buffer[self.buffer.len - self.len ..]);
    }
};

/// `value` with a comma every three digits.
fn grouped(value: u64) Grouped {
    var result: Grouped = .{ .buffer = undefined, .len = 0 };
    var rest = value;
    var digits: usize = 0;
    while (true) {
        if (digits != 0 and digits % 3 == 0) {
            result.len += 1;
            result.buffer[result.buffer.len - result.len] = ',';
        }
        result.len += 1;
        result.buffer[result.buffer.len - result.len] = @intCast('0' + rest % 10);
        digits += 1;
        rest /= 10;
        if (rest == 0) return result;
    }
}

test {
    _ = callgrind;
}

test "grouped digits" {
    try std.testing.expectFmt("0", "{f}", .{grouped(0)});
    try std.testing.expectFmt("999", "{f}", .{grouped(999)});
    try std.testing.expectFmt("1,000", "{f}", .{grouped(1000)});
    try std.testing.expectFmt("3,876,773,333", "{f}", .{grouped(3_876_773_333)});
}
