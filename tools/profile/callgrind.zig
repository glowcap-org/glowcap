//! A reader for callgrind's part format: for one dump, the self cost per
//! source file and per function, which functions are leaves, and who calls
//! them. Names are compressed as `(id) name` at first use and `(id)` after, in
//! one table for files and one for functions. The cost line after `calls=` is
//! that call's inclusive cost, so it never counts as self cost.
const std = @import("std");

/// One dump: the phase that triggered it and what the collected instructions
/// executed. Strings live in the part's arena.
pub const Part = struct {
    arena: std.heap.ArenaAllocator,
    number: u32 = 0,
    trigger: []const u8 = "unnamed",
    total: u64 = 0,
    /// Self cost by source file.
    files: std.StringHashMapUnmanaged(u64) = .empty,
    /// Self cost by `file:function`.
    functions: std.StringHashMapUnmanaged(u64) = .empty,
    /// Functions that call something, by `file:function`. The rest are leaves.
    callers_of_any: std.StringHashMapUnmanaged(void) = .empty,
    /// Each callee's call sites, by callee then caller `file:function`.
    call_sites: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(CallSite)) = .empty,

    pub const CallSite = struct { calls: u64 = 0, cost: u64 = 0 };

    pub fn deinit(self: *Part, gpa: std.mem.Allocator) void {
        self.files.deinit(gpa);
        self.functions.deinit(gpa);
        self.callers_of_any.deinit(gpa);
        var sites = self.call_sites.valueIterator();
        while (sites.next()) |callers| callers.deinit(gpa);
        self.call_sites.deinit(gpa);
        self.arena.deinit();
    }

    pub fn earlier(_: void, a: Part, b: Part) bool {
        return a.number < b.number;
    }

    /// A leaf's inclusive cost at each call site is the cost it did for that
    /// caller, so a generic helper at the top of a ranking can be attributed.
    pub fn isLeaf(self: *const Part, function: []const u8) bool {
        return !self.callers_of_any.contains(function);
    }
};

/// `<base>.<n>`: one dump of the run `base` names.
pub fn isPart(name: []const u8, base: []const u8) bool {
    if (name.len <= base.len + 1 or !std.mem.startsWith(u8, name, base) or name[base.len] != '.') return false;
    for (name[base.len + 1 ..]) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

pub fn headerValue(bytes: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, key)) return std.mem.trim(u8, line[key.len..], " \r");
    }
    return null;
}

/// Read one dump. `fi=` and `fe=` move the file in effect to an inlined
/// source without changing the function; `cfl=` and `cfi=` name the callee's
/// file for the next `cfn=`.
pub fn parsePart(gpa: std.mem.Allocator, bytes: []const u8) !Part {
    var part: Part = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer part.deinit(gpa);
    const arena = part.arena.allocator();
    var file_names: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer file_names.deinit(gpa);
    var function_names: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer function_names.deinit(gpa);
    var positions: usize = 1;
    var current_file: []const u8 = "?";
    var current_function: []const u8 = "?:?";
    var callee_file: []const u8 = "?";
    var callee: []const u8 = "?:?";
    var pending_calls: ?u64 = null;
    var self_total: u64 = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (isCostLine(line)) {
            var tokens = std.mem.tokenizeScalar(u8, line, ' ');
            for (0..positions) |_| _ = tokens.next() orelse return error.InvalidPart;
            const cost = try std.fmt.parseInt(u64, tokens.next() orelse return error.InvalidPart, 10);
            if (pending_calls) |calls| {
                pending_calls = null;
                try recordCall(gpa, &part, callee, current_function, calls, cost);
                callee_file = current_file;
                continue;
            }
            try add(gpa, &part.files, current_file, cost);
            try add(gpa, &part.functions, current_function, cost);
            self_total += cost;
            continue;
        }
        const equals = std.mem.indexOfScalar(u8, line, '=');
        const colon = std.mem.indexOfScalar(u8, line, ':');
        if (colon != null and (equals == null or colon.? < equals.?)) {
            try header(&part, arena, &positions, line[0 .. colon.? + 1], std.mem.trim(u8, line[colon.? + 1 ..], " "));
            continue;
        }
        const at = equals orelse continue;
        const key = line[0..at];
        const value = line[at + 1 ..];
        if (std.mem.eql(u8, key, "fl") or std.mem.eql(u8, key, "fi") or std.mem.eql(u8, key, "fe")) {
            current_file = try resolve(gpa, arena, &file_names, value);
            callee_file = current_file;
        } else if (std.mem.eql(u8, key, "cfl") or std.mem.eql(u8, key, "cfi")) {
            callee_file = try resolve(gpa, arena, &file_names, value);
        } else if (std.mem.eql(u8, key, "fn")) {
            const function = try resolve(gpa, arena, &function_names, value);
            current_function = try std.fmt.allocPrint(arena, "{s}:{s}", .{ current_file, function });
        } else if (std.mem.eql(u8, key, "cfn")) {
            const function = try resolve(gpa, arena, &function_names, value);
            callee = try std.fmt.allocPrint(arena, "{s}:{s}", .{ callee_file, function });
        } else if (std.mem.eql(u8, key, "calls")) {
            var tokens = std.mem.tokenizeScalar(u8, value, ' ');
            pending_calls = try std.fmt.parseInt(u64, tokens.next() orelse return error.InvalidPart, 10);
        }
    }
    if (part.total == 0) part.total = self_total;
    return part;
}

fn header(part: *Part, arena: std.mem.Allocator, positions: *usize, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "positions:")) {
        positions.* = std.mem.count(u8, value, " ") + 1;
    } else if (std.mem.eql(u8, key, "part:")) {
        part.number = try std.fmt.parseInt(u32, value, 10);
    } else if (std.mem.eql(u8, key, "desc:") and std.mem.startsWith(u8, value, "Trigger:")) {
        const trigger = std.mem.trim(u8, value["Trigger:".len..], " ");
        const request = "Client Request: ";
        part.trigger = try arena.dupe(u8, if (std.mem.startsWith(u8, trigger, request)) trigger[request.len..] else trigger);
    } else if (std.mem.eql(u8, key, "totals:") or std.mem.eql(u8, key, "summary:")) {
        var tokens = std.mem.tokenizeScalar(u8, value, ' ');
        part.total = try std.fmt.parseInt(u64, tokens.next() orelse "0", 10);
    }
}

fn isCostLine(line: []const u8) bool {
    return std.ascii.isDigit(line[0]) or line[0] == '+' or line[0] == '-' or line[0] == '*';
}

fn resolve(gpa: std.mem.Allocator, arena: std.mem.Allocator, table: *std.StringHashMapUnmanaged([]const u8), text: []const u8) ![]const u8 {
    if (text.len == 0 or text[0] != '(') return try arena.dupe(u8, text);
    const close = std.mem.indexOfScalar(u8, text, ')') orelse return error.InvalidPart;
    const id = text[1..close];
    const rest = std.mem.trimStart(u8, text[close + 1 ..], " ");
    if (rest.len == 0) return table.get(id) orelse error.InvalidPart;
    const name = try arena.dupe(u8, rest);
    try table.put(gpa, try arena.dupe(u8, id), name);
    return name;
}

fn add(gpa: std.mem.Allocator, map: *std.StringHashMapUnmanaged(u64), key: []const u8, cost: u64) !void {
    const slot = try map.getOrPut(gpa, key);
    if (!slot.found_existing) slot.value_ptr.* = 0;
    slot.value_ptr.* += cost;
}

fn recordCall(gpa: std.mem.Allocator, part: *Part, callee: []const u8, caller: []const u8, calls: u64, cost: u64) !void {
    try part.callers_of_any.put(gpa, caller, {});
    const sites = try part.call_sites.getOrPut(gpa, callee);
    if (!sites.found_existing) sites.value_ptr.* = .empty;
    const site = try sites.value_ptr.getOrPut(gpa, caller);
    if (!site.found_existing) site.value_ptr.* = .{};
    site.value_ptr.calls += calls;
    site.value_ptr.cost += cost;
}

test "self cost follows name compression and inlined files, and call lines count as call sites" {
    const fixture =
        \\# callgrind format
        \\version: 1
        \\creator: callgrind-3.24.0
        \\pid: 42
        \\cmd: bench
        \\part: 3
        \\desc: Trigger: Client Request: hot-read
        \\positions: line
        \\events: Ir
        \\
        \\ob=(1) /bench
        \\fl=(1) src/a.zig
        \\fn=(1) a.one
        \\10 100
        \\cfl=(2) src/b.zig
        \\cfn=(2) b.two
        \\calls=1 20
        \\10 500
        \\fi=(2)
        \\12 7
        \\fe=(1)
        \\13 3
        \\cfn=(2)
        \\calls=2 20
        \\13 40
        \\fl=(2)
        \\fn=(2)
        \\20 50
        \\
        \\totals: 160
    ;
    var part = try parsePart(std.testing.allocator, fixture);
    defer part.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 3), part.number);
    try std.testing.expectEqualStrings("hot-read", part.trigger);
    try std.testing.expectEqual(@as(u64, 160), part.total);
    try std.testing.expectEqual(@as(u64, 103), part.files.get("src/a.zig").?);
    try std.testing.expectEqual(@as(u64, 57), part.files.get("src/b.zig").?);
    try std.testing.expectEqual(@as(u64, 110), part.functions.get("src/a.zig:a.one").?);
    try std.testing.expectEqual(@as(u64, 50), part.functions.get("src/b.zig:b.two").?);
    try std.testing.expect(!part.isLeaf("src/a.zig:a.one"));
    try std.testing.expect(part.isLeaf("src/b.zig:b.two"));
    // The second call names no file, so the callee keeps the file in effect.
    const site = part.call_sites.get("src/b.zig:b.two").?.get("src/a.zig:a.one").?;
    try std.testing.expectEqual(@as(u64, 1), site.calls);
    try std.testing.expectEqual(@as(u64, 500), site.cost);
    const inlined = part.call_sites.get("src/a.zig:b.two").?.get("src/a.zig:a.one").?;
    try std.testing.expectEqual(@as(u64, 2), inlined.calls);
    try std.testing.expectEqual(@as(u64, 40), inlined.cost);
}

test "parts are the base name followed by a dump number" {
    try std.testing.expect(isPart("loam-profile.callgrind.12", "loam-profile.callgrind"));
    try std.testing.expect(!isPart("loam-profile.callgrind", "loam-profile.callgrind"));
    try std.testing.expect(!isPart("loam-profile.callgrind.md", "loam-profile.callgrind"));
    try std.testing.expect(!isPart("other.callgrind.1", "loam-profile.callgrind"));
    try std.testing.expectEqualStrings("42", headerValue("version: 1\npid: 42\ncmd: x\n", "pid:").?);
}
