//! Transaction-local row access and borrowed-input ownership. Each operation
//! preserves aliased inputs before LMDB can evict or move their backing page.
const std = @import("std");
const core = @import("loam_core");
const c = @import("c.zig");

pub const Kv = struct {
    txn: *c.Txn,
    dbi: c_uint,
    borrowed: core.CollectionRow = .{ .key = "", .value = "" },

    pub fn next(self: *Kv, prefix_input: []const u8, after_input: ?[]const u8) !?core.CollectionRow {
        var kept: Kept = .{};
        defer kept.deinit();
        var inputs = [_][]const u8{ prefix_input, after_input orelse "" };
        try kept.keep(self.borrowed, &inputs);
        self.borrowed = .{ .key = "", .value = "" };
        const prefix = inputs[0];
        const after: ?[]const u8 = if (after_input != null) inputs[1] else null;
        var cursor: ?*c.Cursor = null;
        try check(c.mdb_cursor_open(self.txn, self.dbi, &cursor));
        defer c.mdb_cursor_close(cursor.?);
        const floor = if (after) |previous| (if (std.mem.order(u8, previous, prefix) == .gt) previous else prefix) else prefix;
        var key = val(floor);
        var value: c.Val = undefined;
        // MDB_SET_RANGE requires a nonempty key. Empty prefix with no floor
        // selects the first physical row, including on a brand-new database.
        var rc = c.mdb_cursor_get(cursor.?, &key, &value, if (floor.len == 0) c.first else c.set_range);
        if (rc == c.not_found) return null;
        try check(rc);
        if (after) |previous| {
            if (std.mem.eql(u8, valueBytes(key), previous)) {
                rc = c.mdb_cursor_get(cursor.?, &key, &value, c.next);
                if (rc == c.not_found) return null;
                try check(rc);
            }
        }
        if (!std.mem.startsWith(u8, valueBytes(key), prefix)) return null;
        self.borrowed = .{ .key = valueBytes(key), .value = valueBytes(value) };
        return self.borrowed;
    }

    pub fn get(self: *Kv, key_input: []const u8) !?[]const u8 {
        var kept: Kept = .{};
        defer kept.deinit();
        var inputs = [_][]const u8{key_input};
        try kept.keep(self.borrowed, &inputs);
        self.borrowed = .{ .key = "", .value = "" };
        var k = val(inputs[0]);
        var value: c.Val = undefined;
        const rc = c.mdb_get(self.txn, self.dbi, &k, &value);
        if (rc == c.not_found) return null;
        try check(rc);
        self.borrowed = .{ .key = "", .value = valueBytes(value) };
        return self.borrowed.value;
    }

    pub fn put(self: *Kv, key: []const u8, value: []const u8) !void {
        var kept: Kept = .{};
        defer kept.deinit();
        var inputs = [_][]const u8{ key, value };
        try kept.keep(self.borrowed, &inputs);
        self.borrowed = .{ .key = "", .value = "" };
        var k = val(inputs[0]);
        var v = val(inputs[1]);
        try check(c.mdb_put(self.txn, self.dbi, &k, &v, 0));
    }

    pub fn remove(self: *Kv, key: []const u8) !void {
        var kept: Kept = .{};
        defer kept.deinit();
        var inputs = [_][]const u8{key};
        try kept.keep(self.borrowed, &inputs);
        self.borrowed = .{ .key = "", .value = "" };
        var k = val(inputs[0]);
        try check(c.mdb_del(self.txn, self.dbi, &k, null));
    }
};

/// Copies of inputs that alias the row the transaction returned last. While
/// LMDB consumes an input it can evict that row's cached page or move the row,
/// so an aliased input is copied first. Inputs that fit go in `local`, which
/// holds two keys. Anything longer takes one C allocation that `deinit`
/// frees. Caller-owned inputs are used as they are.
const Kept = struct {
    local: [2 * core.max_key_bytes]u8 = undefined,
    heap: ?[]u8 = null,

    fn keep(self: *Kept, borrowed: core.CollectionRow, inputs: [][]const u8) !void {
        var length: usize = 0;
        for (inputs) |input| {
            if (aliases(input, borrowed)) length = try std.math.add(usize, length, input.len);
        }
        if (length == 0) return;
        const space = if (length <= self.local.len) self.local[0..length] else blk: {
            self.heap = try std.heap.c_allocator.alloc(u8, length);
            break :blk self.heap.?;
        };
        var used: usize = 0;
        for (inputs) |*input| {
            if (!aliases(input.*, borrowed)) continue;
            const copy = space[used..][0..input.len];
            @memcpy(copy, input.*);
            input.* = copy;
            used += copy.len;
        }
    }

    fn deinit(self: *Kept) void {
        if (self.heap) |bytes| std.heap.c_allocator.free(bytes);
    }
};

fn aliases(input: []const u8, row: core.CollectionRow) bool {
    return overlaps(input, row.key) or overlaps(input, row.value);
}

fn overlaps(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const first = @intFromPtr(a.ptr);
    const second = @intFromPtr(b.ptr);
    return if (first >= second) first - second < b.len else second - first < a.len;
}

pub fn val(bytes: []const u8) c.Val {
    return .{ .size = bytes.len, .data = @ptrCast(@constCast(bytes.ptr)) };
}

pub fn valueBytes(value: c.Val) []const u8 {
    const bytes: [*]const u8 = @ptrCast(value.data);
    return bytes[0..value.size];
}

pub fn check(rc: c_int) !void {
    return switch (rc) {
        0 => {},
        c.map_full => error.StorageCapacity,
        c.txn_full => error.TransactionCapacity,
        c.readers_full => error.ReaderCapacity,
        @backingInt(std.posix.E.NOSPC), @backingInt(std.posix.E.FBIG) => error.StorageCapacity,
        @backingInt(std.posix.E.NAMETOOLONG) => error.NameTooLong,
        // A failed metadata write fences the environment until it is reopened.
        c.panic => error.ReopenRequired,
        -30796, -30793, -30794 => error.Corrupt,
        else => error.StorageFailure,
    };
}
