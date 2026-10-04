//! Sparse byte-radix directory pages keep lookup and update work bounded.
const std = @import("std");
const core = @import("loam_access_core");
const loam = @import("loam_records");
const syrup = @import("syrup");
const s = syrup.RecordSyntax;
const fields = @import("fields.zig");
const profile = @import("profile.zig");

pub const DirectoryPage = struct {
    owner: core.OwnerId,
    family: Family,
    level: u2,
    prefix: u32,
    mask: u256 = 0,
    targets: [256]loam.Edge = undefined,

    pub const Family = enum { resource, grant, identity };

    pub fn count(self: *const DirectoryPage) usize {
        return @popCount(self.mask);
    }

    pub fn digit(slot: u32, level: u2) u8 {
        return @truncate(slot >> (@as(u5, 3 - @as(u5, level)) * 8));
    }

    pub fn prefixFor(slot: u32, level: u2) u32 {
        const bits: u6 = @as(u6, 4 - @as(u6, level)) * 8;
        return if (bits == 32) 0 else slot & (@as(u32, std.math.maxInt(u32)) << @as(u5, @intCast(bits)));
    }

    fn rank(self: *const DirectoryPage, key: u8) usize {
        return @popCount(self.mask & ((@as(u256, 1) << key) - 1));
    }

    pub fn get(self: *const DirectoryPage, key: u8) ?loam.ObjectId {
        if (self.mask & (@as(u256, 1) << key) == 0) return null;
        return self.targets[self.rank(key)].target;
    }

    pub fn set(self: *DirectoryPage, key: u8, target: loam.ObjectId) void {
        const index = self.rank(key);
        const n = self.count();
        if (self.get(key) == null) {
            std.mem.copyBackwards(loam.Edge, self.targets[index + 1 .. n + 1], self.targets[index..n]);
            self.mask |= @as(u256, 1) << key;
        }
        self.targets[index] = .{ .target = target, .strength = if (self.family == .identity and self.level == 3) .weak else .strong };
    }

    pub fn remove(self: *DirectoryPage, key: u8) void {
        if (self.get(key) == null) return;
        const index = self.rank(key);
        const n = self.count();
        std.mem.copyForwards(loam.Edge, self.targets[index .. n - 1], self.targets[index + 1 .. n]);
        self.mask &= ~(@as(u256, 1) << key);
    }

    pub fn encodeAlloc(self: *const DirectoryPage, allocator: std.mem.Allocator) ![]u8 {
        if (self.prefix != prefixFor(self.prefix, self.level)) return error.InvalidRecord;
        return syrup.render.renderRecordExact(allocator, write, .{self});
    }

    pub fn decode(view: loam.View) !DirectoryPage {
        if (view.schema != profile.directory or view.schema_version != 1 or view.payload.len > 192) return error.InvalidRecord;
        const b = view.payload;
        var c: usize = 0;
        try s.readByte(b, &c, '<');
        if (!std.mem.eql(u8, try s.readSymbol(b, &c), "access:directory")) return error.InvalidRecord;
        if (try s.readPositiveInt(b, &c) != 1) return error.UnsupportedVersion;
        const owner: core.OwnerId = @fromBackingInt(try fields.readWide(b, &c));
        const tag = try s.readSymbol(b, &c);
        const family: Family = if (std.mem.eql(u8, tag, "resource")) .resource else if (std.mem.eql(u8, tag, "grant")) .grant else if (std.mem.eql(u8, tag, "identity")) .identity else return error.InvalidRecord;
        const level = std.math.cast(u2, try s.readPositiveInt(b, &c)) orelse return error.InvalidRecord;
        const prefix = std.math.cast(u32, try s.readPositiveInt(b, &c)) orelse return error.InvalidRecord;
        const mask_bytes = try s.readBytesLimited(b, &c, b.len);
        if (mask_bytes.len != 32 or prefix != prefixFor(prefix, level)) return error.InvalidRecord;
        var result: DirectoryPage = .{ .owner = owner, .family = family, .level = level, .prefix = prefix, .mask = std.mem.readInt(u256, mask_bytes[0..32], .big) };
        if (result.count() != view.edge_count) return error.InvalidRecord;
        var edges = view.edges();
        for (result.targets[0..result.count()]) |*target| {
            target.* = edges.next().?;
            const strength: @FieldType(loam.Edge, "strength") = if (family == .identity and level == 3) .weak else .strong;
            if (target.strength != strength) return error.InvalidRecord;
        }
        try s.readByte(b, &c, '>');
        try s.expectEnd(b, c);
        return result;
    }

    fn write(sink: anytype, self: *const DirectoryPage) !void {
        try s.beginRecord(sink);
        try s.writeSymbol(sink, "access:directory");
        try s.writePositiveInt(sink, 1);
        try fields.writeWide(sink, @backingInt(self.owner));
        try s.writeSymbol(sink, @tagName(self.family));
        try s.writePositiveInt(sink, self.level);
        try s.writePositiveInt(sink, self.prefix);
        var mask: [32]u8 = undefined;
        std.mem.writeInt(u256, &mask, self.mask, .big);
        try s.writeBytes(sink, &mask);
        try s.endRecord(sink);
    }
};
