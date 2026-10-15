//! Sparse byte-radix directory pages keep lookup and update work bounded.
const std = @import("std");
const core = @import("loam_access_core");
const loam = @import("loam_records");
const syrup = @import("syrup");
const s = syrup.RecordSyntax;
const fields = @import("fields.zig");
const profile = @import("profile.zig");

pub const DirectoryPage = struct {
    header: Header,
    targets: [256]loam.Edge = undefined,

    pub const Family = enum { resource, grant, identity };

    /// The page without its targets: what a lookup needs to find one key's
    /// edge in the record view, with no copy of the page.
    pub const Header = struct {
        owner: core.OwnerId,
        family: Family,
        level: u2,
        prefix: u32,
        mask: u256 = 0,

        pub fn count(self: Header) usize {
            return @popCount(self.mask);
        }

        /// Refuse a page that is not `owner`'s `family` page at `level` under
        /// `prefix`.
        pub fn expect(self: Header, owner: core.OwnerId, family: Family, level: u2, prefix: u32) !void {
            if (self.owner != owner or self.family != family or self.level != level or self.prefix != prefix) return error.InvalidRecord;
        }

        /// The edge `key` names, read from the view `decodeHeader` validated.
        pub fn target(self: Header, view: loam.View, key: u8) !?loam.ObjectId {
            if (self.mask & (@as(u256, 1) << key) == 0) return null;
            const edge = try view.edgeAt(rankIn(self.mask, key));
            if (edge.strength != strengthFor(self.family, self.level)) return error.InvalidRecord;
            return edge.target;
        }

        /// The smallest key at or above `from` with a target.
        pub fn nextKey(self: Header, from: u16) ?u8 {
            if (from >= 256) return null;
            const rest = self.mask >> @intCast(from);
            if (rest == 0) return null;
            return @intCast(from + @ctz(rest));
        }
    };

    pub fn count(self: *const DirectoryPage) usize {
        return self.header.count();
    }

    pub fn digit(slot: u32, level: u2) u8 {
        return @truncate(slot >> (@as(u5, 3 - @as(u5, level)) * 8));
    }

    pub fn prefixFor(slot: u32, level: u2) u32 {
        const bits: u6 = @as(u6, 4 - @as(u6, level)) * 8;
        return if (bits == 32) 0 else slot & (@as(u32, std.math.maxInt(u32)) << @as(u5, @intCast(bits)));
    }

    /// Leaf identity edges are weak: an identity row's life is its owner's,
    /// not the directory's.
    fn strengthFor(family: Family, level: u2) @FieldType(loam.Edge, "strength") {
        return if (family == .identity and level == 3) .weak else .strong;
    }

    fn rankIn(mask: u256, key: u8) usize {
        return @popCount(mask & ((@as(u256, 1) << key) - 1));
    }

    fn rank(self: *const DirectoryPage, key: u8) usize {
        return rankIn(self.header.mask, key);
    }

    pub fn get(self: *const DirectoryPage, key: u8) ?loam.ObjectId {
        if (self.header.mask & (@as(u256, 1) << key) == 0) return null;
        return self.targets[self.rank(key)].target;
    }

    pub fn set(self: *DirectoryPage, key: u8, target: loam.ObjectId) void {
        const index = self.rank(key);
        const n = self.count();
        if (self.get(key) == null) {
            std.mem.copyBackwards(loam.Edge, self.targets[index + 1 .. n + 1], self.targets[index..n]);
            self.header.mask |= @as(u256, 1) << key;
        }
        self.targets[index] = .{ .target = target, .strength = strengthFor(self.header.family, self.header.level) };
    }

    pub fn remove(self: *DirectoryPage, key: u8) void {
        if (self.get(key) == null) return;
        const index = self.rank(key);
        const n = self.count();
        std.mem.copyForwards(loam.Edge, self.targets[index .. n - 1], self.targets[index + 1 .. n]);
        self.header.mask &= ~(@as(u256, 1) << key);
    }

    pub fn encodeAlloc(self: *const DirectoryPage, allocator: std.mem.Allocator) ![]u8 {
        if (self.header.prefix != prefixFor(self.header.prefix, self.header.level)) return error.InvalidRecord;
        return syrup.render.renderRecordExact(allocator, write, .{self});
    }

    /// Validate the page record and read its header. The targets stay in the
    /// view as fixed-width edges, one per set mask bit in key order.
    pub fn decodeHeader(view: loam.View) !Header {
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
        const mask_bytes = try s.readBytes(b, &c);
        if (mask_bytes.len != 32 or prefix != prefixFor(prefix, level)) return error.InvalidRecord;
        const header: Header = .{ .owner = owner, .family = family, .level = level, .prefix = prefix, .mask = std.mem.readInt(u256, mask_bytes[0..32], .big) };
        if (header.count() != view.edge_count) return error.InvalidRecord;
        try s.readByte(b, &c, '>');
        try s.expectEnd(b, c);
        return header;
    }

    /// The whole page, for an edit. A lookup reads one edge through
    /// `decodeHeader` instead of copying every target.
    pub fn decode(view: loam.View) !DirectoryPage {
        var result: DirectoryPage = .{ .header = try decodeHeader(view) };
        var edges = view.edges();
        for (result.targets[0..result.count()]) |*target| {
            target.* = edges.next().?;
            if (target.strength != strengthFor(result.header.family, result.header.level)) return error.InvalidRecord;
        }
        return result;
    }

    fn write(sink: anytype, self: *const DirectoryPage) !void {
        try s.beginRecord(sink);
        try s.writeSymbol(sink, "access:directory");
        try s.writePositiveInt(sink, 1);
        try fields.writeWide(sink, @backingInt(self.header.owner));
        try s.writeSymbol(sink, @tagName(self.header.family));
        try s.writePositiveInt(sink, self.header.level);
        try s.writePositiveInt(sink, self.header.prefix);
        var mask: [32]u8 = undefined;
        std.mem.writeInt(u256, &mask, self.header.mask, .big);
        try s.writeBytes(sink, &mask);
        try s.endRecord(sink);
    }
};
