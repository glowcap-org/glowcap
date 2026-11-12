//! Near-verbatim duplicate function bodies as a checked surface.
//!
//! Two copies of one body drift: a fix lands in one and the other keeps the
//! defect. Every `fn` in `src/`, `test/`, and `bench/` with at least
//! `min_body_lines` lines of code is tokenized with identifiers collapsed to
//! one token, so a renamed copy still matches, and hashed into
//! `shingle_len`-token shingles. Two bodies
//! whose shingle sets overlap at `min_overlap_percent` or more are one shape
//! written twice, and the check names both so the shape gets one owner. The
//! bar is near-verbatim on purpose: structural siblings that differ in their
//! facts (two wire records, two directions of one socket) share far less.
//! A body that is mostly `.field = value,` binding rows is a table, whose
//! values are its facts, so it is never compared: collapsing the value
//! identifiers would make any two tables with the same fields one shape. A
//! row whose value can fail or branch (`try`, `orelse`, `catch`, `if`,
//! `switch`) is logic and counts as code.

const std = @import("std");
const text_match = @import("text_match.zig");
const source_tree = @import("source_tree.zig");
const violation_log = @import("violation_log.zig");

const appendViolation = violation_log.appendViolation;

const min_body_lines: usize = 12;
const shingle_len: usize = 6;
const min_overlap_percent: usize = 90;
/// A shingle this many bodies share says nothing about any pair of them and
/// is left out of candidate selection. The exact overlap still counts it.
const max_shingle_owners: usize = 128;
/// A body with at least this share of initializer rows is a table.
const table_row_percent: usize = 60;
/// Repository directories whose Zig files are compared with each other.
const walked_roots = [_][]const u8{ "src", "test", "bench", "tools" };

const Body = struct {
    path: []const u8,
    line: usize,
    name: []const u8,
    lines: usize,
    /// Sorted, deduplicated shingle hashes.
    shingles: []const u64,

    fn deinit(self: Body, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        gpa.free(self.name);
        gpa.free(self.shingles);
    }
};

pub fn check(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var bodies: std.ArrayList(Body) = .empty;
    defer {
        for (bodies.items) |body| body.deinit(gpa);
        bodies.deinit(gpa);
    }
    for (walked_roots) |name| try collectTree(io, gpa, root, name, &bodies, violations);
    try reportDuplicates(gpa, violations, bodies.items);
}

/// Append every function body under the repository directory `name`.
fn collectTree(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    name: []const u8,
    bodies: *std.ArrayList(Body),
    violations: *std.ArrayList([]const u8),
) !void {
    const Sink = struct {
        gpa: std.mem.Allocator,
        bodies: *std.ArrayList(Body),
        fn visit(self: @This(), path: []const u8, contents: []u8) std.mem.Allocator.Error!void {
            try collectBodies(self.gpa, self.bodies, path, contents);
        }
    };
    try source_tree.visitSourceFiles(io, gpa, root, violations, "duplicate-body", name, &source_tree.isZigPath, Sink{ .gpa = gpa, .bodies = bodies }, Sink.visit);
}

/// Append every function body of `contents` long enough to compare.
fn collectBodies(gpa: std.mem.Allocator, bodies: *std.ArrayList(Body), path: []const u8, contents: []const u8) !void {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |line| try lines.append(gpa, line);

    var i: usize = 0;
    while (i < lines.items.len) : (i += 1) {
        const head = fnHead(lines.items[i]) orelse continue;
        // The signature may span lines; it ends on the line that opens the body.
        var open = i;
        while (open < lines.items.len and !std.mem.endsWith(u8, std.mem.trimEnd(u8, lines.items[open], " "), "{")) : (open += 1) {
            if (std.mem.endsWith(u8, std.mem.trimEnd(u8, lines.items[open], " "), ";")) break;
        }
        if (open >= lines.items.len or !std.mem.endsWith(u8, std.mem.trimEnd(u8, lines.items[open], " "), "{")) continue;
        var close = open + 1;
        while (close < lines.items.len and !isClose(lines.items[close], head.indent)) : (close += 1) {}
        if (close >= lines.items.len) continue;

        const body = lines.items[open + 1 .. close];
        var code_lines: usize = 0;
        for (body) |line| {
            if (!std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "//")) code_lines += 1;
        }
        if (code_lines >= min_body_lines and !isTable(body, code_lines)) {
            const shingles = try shinglesOf(gpa, body);
            errdefer gpa.free(shingles);
            const owned_path = try gpa.dupe(u8, path);
            errdefer gpa.free(owned_path);
            const owned_name = try gpa.dupe(u8, head.name);
            errdefer gpa.free(owned_name);
            try bodies.append(gpa, .{ .path = owned_path, .line = i + 1, .name = owned_name, .lines = code_lines, .shingles = shingles });
        }
        i = close;
    }
}

/// Whether `table_row_percent` of the body's code lines are plain
/// `.field = value,` bindings.
fn isTable(body: []const []const u8, code_lines: usize) bool {
    var rows: usize = 0;
    for (body) |line| {
        if (isBindingRow(std.mem.trim(u8, line, " "))) rows += 1;
    }
    return rows * 100 >= code_lines * table_row_percent;
}

/// Whether `code` is `.field = value,` with a value that neither fails nor
/// branches.
fn isBindingRow(code: []const u8) bool {
    if (code.len < 2 or code[0] != '.' or !text_match.isIdentStart(code[1])) return false;
    const eq = std.mem.indexOf(u8, code, " = ") orelse return false;
    if (!std.mem.endsWith(u8, code, ",")) return false;
    const value = code[eq + 3 ..];
    for ([_][]const u8{ "try ", " orelse ", " catch ", "if (", "switch (" }) |logic| {
        if (std.mem.indexOf(u8, value, logic) != null) return false;
    }
    return true;
}

const FnHead = struct { indent: usize, name: []const u8 };

/// The declaration a line opens, when it is `[pub ][inline ]fn name(`.
fn fnHead(line: []const u8) ?FnHead {
    const indent = line.len - std.mem.trimStart(u8, line, " ").len;
    var rest = line[indent..];
    if (std.mem.startsWith(u8, rest, "pub ")) rest = rest[4..];
    if (std.mem.startsWith(u8, rest, "inline ")) rest = rest[7..];
    if (!std.mem.startsWith(u8, rest, "fn ")) return null;
    rest = rest[3..];
    var end: usize = 0;
    while (end < rest.len and text_match.isIdentChar(rest[end])) end += 1;
    if (end == 0 or end >= rest.len or rest[end] != '(') return null;
    return .{ .indent = indent, .name = rest[0..end] };
}

fn isClose(line: []const u8, indent: usize) bool {
    if (line.len < indent + 1) return false;
    for (line[0..indent]) |ch| if (ch != ' ') return false;
    return std.mem.eql(u8, std.mem.trimEnd(u8, line[indent..], " "), "}");
}

/// Sorted, deduplicated hashes of every `shingle_len`-token window of the
/// body's code, with each non-keyword, non-field identifier read as one
/// token.
fn shinglesOf(gpa: std.mem.Allocator, body: []const []const u8) ![]const u64 {
    var tokens: std.ArrayList([]const u8) = .empty;
    defer tokens.deinit(gpa);
    for (body) |line| {
        const code = text_match.codeOfLine(line);
        var i: usize = 0;
        while (i < code.len) {
            const ch = code[i];
            if (ch == ' ' or ch == '\t') {
                i += 1;
                continue;
            }
            const start = i;
            if (text_match.isIdentStart(ch) or (ch == '@' and i + 1 < code.len and text_match.isIdentStart(code[i + 1]))) {
                i += 1;
                while (i < code.len and text_match.isIdentChar(code[i])) i += 1;
                const word = code[start..i];
                const field = start > 0 and code[start - 1] == '.';
                const keep = word[0] == '@' or field or std.zig.Token.getKeyword(word) != null;
                try tokens.append(gpa, if (keep) word else "I");
            } else if (std.ascii.isDigit(ch)) {
                while (i < code.len and text_match.isIdentChar(code[i])) i += 1;
                try tokens.append(gpa, code[start..i]);
            } else {
                i += 1;
                if (i < code.len and isPairedOp(code[start .. i + 1])) i += 1;
                try tokens.append(gpa, code[start..i]);
            }
        }
    }
    var hashes: std.ArrayList(u64) = .empty;
    errdefer hashes.deinit(gpa);
    if (tokens.items.len >= shingle_len) {
        for (0..tokens.items.len - shingle_len + 1) |start| {
            var hasher = std.hash.Wyhash.init(0);
            for (tokens.items[start .. start + shingle_len]) |token| {
                hasher.update(token);
                hasher.update(&.{0});
            }
            try hashes.append(gpa, hasher.final());
        }
    }
    std.sort.pdq(u64, hashes.items, {}, std.sort.asc(u64));
    var unique: usize = 0;
    for (hashes.items) |hash| {
        if (unique == 0 or hashes.items[unique - 1] != hash) {
            hashes.items[unique] = hash;
            unique += 1;
        }
    }
    hashes.shrinkRetainingCapacity(unique);
    return hashes.toOwnedSlice(gpa);
}

fn isPairedOp(pair: []const u8) bool {
    for ([_][]const u8{ "==", "!=", "<=", ">=", "=>", "||", "&&", "..", "+=", "-=", "|=", "&=" }) |op| {
        if (std.mem.eql(u8, pair, op)) return true;
    }
    return false;
}

/// Name every pair of bodies at or above the overlap bar. Candidates come from
/// an index of shingle to owners. The exact overlap of their full sets decides.
fn reportDuplicates(gpa: std.mem.Allocator, violations: *std.ArrayList([]const u8), bodies: []const Body) !void {
    var owners: std.AutoHashMap(u64, std.ArrayList(u32)) = .init(gpa);
    defer {
        var it = owners.valueIterator();
        while (it.next()) |list| list.deinit(gpa);
        owners.deinit();
    }
    for (bodies, 0..) |body, id| {
        for (body.shingles) |hash| {
            const slot = try owners.getOrPut(hash);
            if (!slot.found_existing) slot.value_ptr.* = .empty;
            try slot.value_ptr.append(gpa, @intCast(id));
        }
    }
    var shared: std.AutoHashMap(u64, u32) = .init(gpa);
    defer shared.deinit();
    var it = owners.valueIterator();
    while (it.next()) |list| {
        if (list.items.len > max_shingle_owners) continue;
        for (list.items, 0..) |a, k| for (list.items[k + 1 ..]) |b| {
            const slot = try shared.getOrPut((@as(u64, a) << 32) | b);
            if (!slot.found_existing) slot.value_ptr.* = 0;
            slot.value_ptr.* += 1;
        };
    }
    var pairs = shared.iterator();
    while (pairs.next()) |pair| {
        const a = bodies[pair.key_ptr.* >> 32];
        const b = bodies[@as(u32, @truncate(pair.key_ptr.*))];
        // A candidate needs half its smaller set in the index before the exact
        // merge runs; a copy clears that by a wide margin.
        if (@as(usize, pair.value_ptr.*) * 2 < @min(a.shingles.len, b.shingles.len)) continue;
        const percent = overlapPercent(a.shingles, b.shingles);
        if (percent < min_overlap_percent) continue;
        try appendViolation(gpa, violations, "{s}:{d} {s} ({d} lines) duplicates {s}:{d} {s} at {d}% token overlap; give the shape one owner", .{ a.path, a.line, a.name, a.lines, b.path, b.line, b.name, percent });
    }
}

/// Jaccard overlap of two sorted unique sets, in whole percent.
fn overlapPercent(a: []const u64, b: []const u64) usize {
    var i: usize = 0;
    var j: usize = 0;
    var both: usize = 0;
    while (i < a.len and j < b.len) {
        if (a[i] == b[j]) {
            both += 1;
            i += 1;
            j += 1;
        } else if (a[i] < b[j]) {
            i += 1;
        } else {
            j += 1;
        }
    }
    const either = a.len + b.len - both;
    return if (either == 0) 0 else both * 100 / either;
}

const copy_a =
    \\fn drainPacket(self: *Session, out: *Frame) !void {
    \\    const slot = out orelse return error.NullPointer;
    \\    const prefix = self.prefix orelse return error.NullPointer;
    \\    if (self.cap < prefix_cap) {
    \\        self.len = prefix_cap;
    \\        return error.BufferTooSmall;
    \\    }
    \\    const popped = self.takeTransportOutbound() catch |err| return err;
    \\    const outbound = popped orelse return error.WouldBlock;
    \\    @memcpy(prefix[0..outbound.prefix_len], outbound.prefixBytes());
    \\    self.len = outbound.prefix_len;
    \\    slot.* = managedFrame(outbound.payload);
    \\    self.count += 1;
    \\    self.last = outbound.prefix_len;
    \\}
    \\
;

const copy_b =
    \\fn drainStream(this: *Session, result: *Frame) !void {
    \\    const target = result orelse return error.NullPointer;
    \\    const head = this.prefix orelse return error.NullPointer;
    \\    if (this.cap < prefix_cap) {
    \\        this.len = prefix_cap;
    \\        return error.BufferTooSmall;
    \\    }
    \\    const popped = this.takeTransportOutbound() catch |err| return err;
    \\    const outbound = popped orelse return error.WouldBlock;
    \\    @memcpy(head[0..outbound.prefix_len], outbound.prefixBytes());
    \\    this.len = outbound.prefix_len;
    \\    target.* = managedFrame(outbound.payload);
    \\    this.count += 1;
    \\    this.last = outbound.prefix_len;
    \\}
    \\
;

const different =
    \\fn receive(self: *Session, out: []u8) !usize {
    \\    var total: usize = 0;
    \\    while (total < out.len) {
    \\        const got = self.socket.read(out[total..]) catch |err| switch (err) {
    \\            error.WouldBlock => break,
    \\            else => return err,
    \\        };
    \\        if (got == 0) return error.ConnectionLost;
    \\        total += got;
    \\        self.bytes_in += got;
    \\        if (self.bytes_in > self.limit) return error.Overflow;
    \\    }
    \\    self.reads += 1;
    \\    return total;
    \\}
    \\
;

fn freeViolations(gpa: std.mem.Allocator, violations: *std.ArrayList([]const u8)) void {
    for (violations.items) |message| gpa.free(message);
    violations.deinit(gpa);
}

fn violationsFor(gpa: std.mem.Allocator, sources: []const []const u8) !std.ArrayList([]const u8) {
    var bodies: std.ArrayList(Body) = .empty;
    defer {
        for (bodies.items) |body| body.deinit(gpa);
        bodies.deinit(gpa);
    }
    for (sources, 0..) |source, n| {
        const path = try std.fmt.allocPrint(gpa, "src/{d}.zig", .{n});
        defer gpa.free(path);
        try collectBodies(gpa, &bodies, path, source);
    }
    var violations: std.ArrayList([]const u8) = .empty;
    errdefer freeViolations(gpa, &violations);
    try reportDuplicates(gpa, &violations, bodies.items);
    return violations;
}

test "a renamed copy is reported once and a differing body is not" {
    const gpa = std.testing.allocator;
    var violations = try violationsFor(gpa, &.{ copy_a, copy_b, different });
    defer freeViolations(gpa, &violations);
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
    try std.testing.expect(std.mem.indexOf(u8, violations.items[0], "drainPacket") != null);
    try std.testing.expect(std.mem.indexOf(u8, violations.items[0], "drainStream") != null);
}

test "a body below the length floor is never compared" {
    const gpa = std.testing.allocator;
    const short = "fn a(x: u32) u32 {\n    const y = x + 1;\n    return y * 2;\n}\n";
    var violations = try violationsFor(gpa, &.{ short, short });
    defer freeViolations(gpa, &violations);
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "a table of fallible rows is still compared" {
    const gpa = std.testing.allocator;
    const decode =
        \\fn decode(r: *Reader) !T {
        \\    return .{
        \\        .a = try r.readInt(u32, .little),
        \\        .b = try r.readInt(u32, .little),
        \\        .c = try r.readInt(u32, .little),
        \\        .d = try r.readInt(u32, .little),
        \\        .e = try r.readInt(u32, .little),
        \\        .f = try r.readInt(u32, .little),
        \\        .g = try r.readInt(u32, .little),
        \\        .h = try r.readInt(u32, .little),
        \\        .i = try r.readInt(u32, .little),
        \\        .j = try r.readInt(u32, .little),
        \\        .k = try r.readInt(u32, .little),
        \\        .l = std.math.cast(u32, r.n) orelse return error.TooBig,
        \\    };
        \\}
        \\
    ;
    var violations = try violationsFor(gpa, &.{ decode, decode });
    defer freeViolations(gpa, &violations);
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

test "a table of bindings is never compared" {
    const gpa = std.testing.allocator;
    const first =
        \\fn table(self: *A) T {
        \\    return .{
        \\        .abi_version = version,
        \\        .ctx = self,
        \\        .read = readA,
        \\        .write = writeA,
        \\        .close = closeA,
        \\        .listen = listenA,
        \\        .accept = acceptA,
        \\        .locator = locatorA,
        \\        .advertise = advertiseA,
        \\        .failure = failureA,
        \\        .key = keyA,
        \\        .stop = stopA,
        \\    };
        \\}
        \\
    ;
    var violations = try violationsFor(gpa, &.{ first, first });
    defer freeViolations(gpa, &violations);
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}
