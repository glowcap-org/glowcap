//! Comptime reflection helpers shared by the `tools/gen/` generators, so a
//! generator names one helper rather than redeclaring it.

const std = @import("std");

/// The unqualified type name: strip the module path that `@typeName` carries,
/// so `foo.bar.Baz` becomes `Baz`.
pub fn baseName(comptime T: type) []const u8 {
    @setEvalBranchQuota(1_000_000);
    const name = @typeName(T);
    const dot = std.mem.findScalarLast(u8, name, '.');
    return if (dot) |i| name[i + 1 ..] else name;
}

/// One `pub(crate) const` line of a generated Rust constants file. The Rust
/// type is the Zig type's own name, so `i32`, `u32`, `isize`, and `usize` carry
/// across with no table and no cast at the Rust call site.
pub fn printRustConst(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    comptime rust_name: []const u8,
    comptime T: type,
    value: T,
) !void {
    const same_name_in_rust = comptime for (.{ i8, i16, i32, i64, i128, u8, u16, u32, u64, u128, isize, usize }) |R| {
        if (T == R) break true;
    } else false;
    if (!same_name_in_rust) @compileError(rust_name ++ " is a " ++ @typeName(T) ++ ", which Rust has no type of the same name for");
    try out.print(gpa, "pub(crate) const {s}: {s} = {d};\n", .{ rust_name, @typeName(T), value });
}

/// One Rust constant per public declaration of the namespace struct `Ns`, in
/// declaration order. The Rust name is `rust_prefix` followed by the upper-cased
/// Zig name, so adding a declaration adds its row.
pub fn printRustDecls(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    comptime Ns: type,
    comptime rust_prefix: []const u8,
) !void {
    inline for (comptime std.meta.declarations(Ns)) |name| {
        const value = @field(Ns, name);
        try printRustConst(gpa, out, rustName(rust_prefix, name), @TypeOf(value), value);
    }
}

/// One Rust constant per tag of the enum `E`, typed as the enum's tag integer.
pub fn printRustTags(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    comptime E: type,
    comptime rust_prefix: []const u8,
) !void {
    const Tag = @typeInfo(E).@"enum".tag_type;
    inline for (comptime std.meta.tags(E)) |tag| {
        try printRustConst(gpa, out, rustName(rust_prefix, @tagName(tag)), Tag, @backingInt(tag));
    }
}

/// `prefix ++ upper(name)`, the Rust spelling of a snake_case Zig name.
pub fn rustName(comptime prefix: []const u8, comptime name: []const u8) []const u8 {
    comptime {
        var buf: [prefix.len + name.len]u8 = undefined;
        @memcpy(buf[0..prefix.len], prefix);
        for (name, 0..) |c, i| buf[prefix.len + i] = std.ascii.toUpper(c);
        const done = buf;
        return &done;
    }
}
