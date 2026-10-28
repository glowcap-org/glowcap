//! The installed form of a GNU-format archive: member names reduced to file
//! names, as `ar` writes them. Zig's ELF archiver records each member under
//! its full cache path, so an identical object recompiled into a new cache
//! directory changes the archive's bytes, and every Rust build script that
//! watches the archive reruns. The renamed form depends only on member order,
//! file names, and contents. Zig's Mach-O archiver already writes file names,
//! so `layout` returns null for that format and the installer copies it as is.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// One run of the installed file's bytes.
pub const Piece = union(enum) {
    /// Bytes the layout built.
    bytes: []const u8,
    /// A range of the source file.
    source: struct { offset: u64, len: u64 },

    pub fn len(piece: Piece) u64 {
        return switch (piece) {
            .bytes => |bytes| bytes.len,
            .source => |range| range.len,
        };
    }
};

const magic = "!<arch>\n";
const header_len = 60;
/// Longest file name that fits the 16-byte name field with its `/` ending.
const max_inline_name = 15;

const Member = struct {
    name: []const u8,
    /// Header bytes after the name field: date, owner, group, mode, size, end.
    fields: [header_len - 16]u8,
    offset: u64,
    size: u64,
};

/// The pieces of `file`'s installed form, or null when it is not a GNU-format
/// archive. `arena` owns the result. Reads only headers and the two index
/// members, so the cost is independent of member size.
pub fn layout(arena: Allocator, io: Io, file: Io.File, size: u64) !?[]const Piece {
    var start: [magic.len]u8 = undefined;
    if (size < magic.len or try file.readPositionalAll(io, &start, 0) != magic.len) return null;
    if (!std.mem.eql(u8, &start, magic)) return null;

    var symbols: ?struct { header: [header_len]u8, data: []u8, wide: bool } = null;
    var long_names: []const u8 = "";
    var members: std.ArrayList(Member) = .empty;
    var offset: u64 = magic.len;
    while (offset < size) {
        var header: [header_len]u8 = undefined;
        if (try file.readPositionalAll(io, &header, offset) != header_len) return null;
        if (!std.mem.eql(u8, header[58..60], "`\n")) return null;
        const member_size = std.fmt.parseInt(u64, std.mem.trimEnd(u8, header[48..58], " "), 10) catch return null;
        const data = offset + header_len;
        if (member_size > size - @min(size, data)) return null;
        const name = std.mem.trimEnd(u8, header[0..16], " ");
        if (std.mem.eql(u8, name, "/") or std.mem.eql(u8, name, "/SYM64/")) {
            if (symbols != null or members.items.len != 0) return null;
            const bytes = try arena.alloc(u8, @intCast(member_size));
            if (try file.readPositionalAll(io, bytes, data) != bytes.len) return null;
            symbols = .{ .header = header, .data = bytes, .wide = name.len > 1 };
        } else if (std.mem.eql(u8, name, "//")) {
            if (long_names.len != 0 or members.items.len != 0) return null;
            const bytes = try arena.alloc(u8, @intCast(member_size));
            if (try file.readPositionalAll(io, bytes, data) != bytes.len) return null;
            long_names = bytes;
        } else {
            const full = resolveName(name, long_names) orelse return null;
            const base = std.fs.path.basenamePosix(full);
            if (base.len == 0) return null;
            try members.append(arena, .{ .name = base, .fields = header[16..].*, .offset = offset, .size = member_size });
        }
        offset = data + member_size + (member_size & 1);
    }

    var names: std.ArrayList(u8) = .empty;
    const name_fields = try arena.alloc([16]u8, members.items.len);
    for (members.items, name_fields) |member, *field| {
        @memset(field, ' ');
        if (member.name.len <= max_inline_name) {
            _ = std.fmt.bufPrint(field, "{s}/", .{member.name}) catch unreachable;
        } else {
            _ = std.fmt.bufPrint(field, "/{d}", .{names.items.len}) catch return null;
            try names.print(arena, "{s}/\n", .{member.name});
        }
    }

    var pieces: std.ArrayList(Piece) = .empty;
    try pieces.append(arena, .{ .bytes = magic });
    var next: u64 = magic.len;
    if (symbols) |table| next += header_len + table.data.len + (table.data.len & 1);
    if (names.items.len != 0) next += header_len + names.items.len + (names.items.len & 1);
    // Old header offset to new, which the symbol table's entries name.
    const moved = try arena.alloc(struct { old: u64, new: u64 }, members.items.len);
    for (members.items, moved) |member, *entry| {
        entry.* = .{ .old = member.offset, .new = next };
        next += header_len + member.size + (member.size & 1);
    }

    if (symbols) |table| {
        if (!rewriteOffsets(table.data, table.wide, moved)) return null;
        try pieces.append(arena, .{ .bytes = try arena.dupe(u8, &table.header) });
        try appendPadded(arena, &pieces, table.data);
    }
    if (names.items.len != 0) {
        const header = try std.fmt.allocPrint(arena, "{s: <16}{s: <32}{d: <10}`\n", .{ "//", "", names.items.len });
        try pieces.append(arena, .{ .bytes = header });
        try appendPadded(arena, &pieces, names.items);
    }
    for (members.items, name_fields) |member, field| {
        const header = try arena.alloc(u8, header_len);
        @memcpy(header[0..16], &field);
        @memcpy(header[16..], &member.fields);
        try pieces.append(arena, .{ .bytes = header });
        try pieces.append(arena, .{ .source = .{ .offset = member.offset + header_len, .len = member.size } });
        if (member.size & 1 != 0) try pieces.append(arena, .{ .bytes = "\n" });
    }
    return try pieces.toOwnedSlice(arena);
}

/// A member's recorded name: inline before its `/`, or the `/`-ended entry
/// at the offset a `/<offset>` name gives into the long-name table.
fn resolveName(name: []const u8, long_names: []const u8) ?[]const u8 {
    if (name.len > 1 and name[0] == '/') {
        const at = std.fmt.parseInt(usize, name[1..], 10) catch return null;
        if (at >= long_names.len) return null;
        const end = std.mem.indexOfPos(u8, long_names, at, "/\n") orelse return null;
        return long_names[at..end];
    }
    if (name.len < 2 or name[name.len - 1] != '/') return null;
    return name[0 .. name.len - 1];
}

/// Rewrite each member offset in a symbol table (a big-endian count, that
/// many offsets, then the names), or report an offset no member starts at.
fn rewriteOffsets(data: []u8, wide: bool, moved: anytype) bool {
    const width: usize = if (wide) 8 else 4;
    if (data.len < width) return false;
    const count = readBig(data[0..width]);
    if (count > (data.len - width) / width) return false;
    for (0..@intCast(count)) |index| {
        const slot = data[width * (index + 1) ..][0..width];
        const old = readBig(slot);
        const entry = for (moved) |entry| {
            if (entry.old == old) break entry;
        } else return false;
        if (wide) {
            std.mem.writeInt(u64, slot[0..8], entry.new, .big);
        } else {
            std.mem.writeInt(u32, slot[0..4], std.math.cast(u32, entry.new) orelse return false, .big);
        }
    }
    return true;
}

fn readBig(bytes: []const u8) u64 {
    return if (bytes.len == 8) std.mem.readInt(u64, bytes[0..8], .big) else std.mem.readInt(u32, bytes[0..4], .big);
}

fn appendPadded(arena: Allocator, pieces: *std.ArrayList(Piece), bytes: []const u8) !void {
    try pieces.append(arena, .{ .bytes = bytes });
    if (bytes.len & 1 != 0) try pieces.append(arena, .{ .bytes = "\n" });
}

const testing = std.testing;

/// A GNU archive whose members carry `names` and `contents`, with a symbol
/// table naming each member in `symbol_members` by its header offset. The
/// installer's tests build their archives with it too.
pub fn fixture(gpa: Allocator, names: []const []const u8, contents: []const []const u8, symbol_members: []const usize) ![]u8 {
    var long_names: std.ArrayList(u8) = .empty;
    defer long_names.deinit(gpa);
    const fields = try gpa.alloc([16]u8, names.len);
    defer gpa.free(fields);
    for (names, fields) |name, *field| {
        @memset(field, ' ');
        _ = try std.fmt.bufPrint(field, "/{d}", .{long_names.items.len});
        try long_names.print(gpa, "{s}/\n", .{name});
    }
    const table_len = 4 + 4 * symbol_members.len + 2 * symbol_members.len;
    const offsets = try gpa.alloc(u64, names.len);
    defer gpa.free(offsets);
    var at: u64 = magic.len + header_len + table_len + (table_len & 1) + header_len + long_names.items.len + (long_names.items.len & 1);
    for (contents, offsets) |content, *offset| {
        offset.* = at;
        at += header_len + content.len + (content.len & 1);
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, magic);
    try out.print(gpa, "{s: <16}{d: <12}{d: <6}{d: <6}{d: <8}{d: <10}`\n", .{ "/", 0, 0, 0, 0, table_len });
    var count: [4]u8 = undefined;
    std.mem.writeInt(u32, &count, @intCast(symbol_members.len), .big);
    try out.appendSlice(gpa, &count);
    for (symbol_members) |member| {
        std.mem.writeInt(u32, &count, @intCast(offsets[member]), .big);
        try out.appendSlice(gpa, &count);
    }
    for (symbol_members) |member| try out.print(gpa, "{c}\x00", .{@as(u8, 'a') + @as(u8, @intCast(member))});
    if (table_len & 1 != 0) try out.append(gpa, '\n');
    try out.print(gpa, "{s: <16}{s: <32}{d: <10}`\n", .{ "//", "", long_names.items.len });
    try out.appendSlice(gpa, long_names.items);
    if (long_names.items.len & 1 != 0) try out.append(gpa, '\n');
    for (fields, contents) |field, content| {
        try out.print(gpa, "{s}{d: <12}{d: <6}{d: <6}{d: <8}{d: <10}`\n", .{ &field, 0, 0, 0, 644, content.len });
        try out.appendSlice(gpa, content);
        if (content.len & 1 != 0) try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

/// The installed bytes `layout` describes for `bytes`, or null when it keeps
/// the file as is.
fn installed(arena: Allocator, dir: Io.Dir, bytes: []const u8) !?[]const u8 {
    try dir.writeFile(testing.io, .{ .sub_path = "lib.a", .data = bytes });
    const file = try dir.openFile(testing.io, "lib.a", .{});
    defer file.close(testing.io);
    const pieces = try layout(arena, testing.io, file, bytes.len) orelse return null;
    var out: std.ArrayList(u8) = .empty;
    for (pieces) |piece| switch (piece) {
        .bytes => |run| try out.appendSlice(arena, run),
        .source => |range| try out.appendSlice(arena, bytes[@intCast(range.offset)..][0..@intCast(range.len)]),
    };
    return out.items;
}

test "members recorded under different cache directories install identically" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Odd sizes exercise padding, and the directories differ in length so
    // every member header moves.
    const contents: []const []const u8 = &.{ "zig object", "c object!" };
    const first = try installed(arena, tmp.dir, try fixture(arena, &.{ "/cache/o/1a/glowcap_loam_zcu.o", "/cache/o/2b/mdb.o" }, contents, &.{ 1, 0 }));
    const second = try installed(arena, tmp.dir, try fixture(arena, &.{ "/work/.zig-cache/o/3c4d5e/glowcap_loam_zcu.o", "/cache/o/2b/mdb.o" }, contents, &.{ 1, 0 }));
    try testing.expectEqualStrings(first.?, second.?);

    // The result is the archive `ar` writes: a short name inline, a long one
    // in the name table, and each symbol naming its member's new header.
    const out = first.?;
    const table_len = 4 + 2 * 4 + 2 * 2;
    const names_at = magic.len + header_len + table_len;
    try testing.expectEqualStrings("glowcap_loam_zcu.o/\n", out[names_at + header_len ..][0..20]);
    const objects_at = names_at + header_len + 20;
    try testing.expectEqualStrings("/0              ", out[objects_at..][0..16]);
    const mdb_at = objects_at + header_len + contents[0].len;
    try testing.expectEqualStrings("mdb.o/          ", out[mdb_at..][0..16]);
    try testing.expectEqualStrings("c object!\n", out[mdb_at + header_len ..][0..10]);
    const symbols = out[magic.len + header_len ..];
    try testing.expectEqual(mdb_at, std.mem.readInt(u32, symbols[4..8], .big));
    try testing.expectEqual(objects_at, std.mem.readInt(u32, symbols[8..12], .big));
}

test "other formats and inconsistent archives install unchanged" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.expectEqual(null, try installed(arena, tmp.dir, "\x7fELF shared object"));
    try testing.expectEqual(null, try installed(arena, tmp.dir, magic ++ "#1/4            0           0     0     0       8         `\nb.o\x00data"));
    const archive = try fixture(arena, &.{"/cache/o/1a/a.o"}, &.{"object"}, &.{0});
    // A symbol table entry no member header starts at.
    archive[magic.len + header_len + 7] +%= 1;
    try testing.expectEqual(null, try installed(arena, tmp.dir, archive));
    try testing.expectEqual(null, try installed(arena, tmp.dir, archive[0 .. archive.len - 3]));
}
