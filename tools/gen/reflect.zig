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

/// One public integer constant a generator leaves out, with the reason it
/// stays out. The reason is required text, so a reader of the table learns
/// where the constant reaches consumers instead, or why it must not.
pub const ConstOmission = struct { name: []const u8, reason: []const u8 };

/// A module whose integer constants belong to another owner. `by` names the
/// header or contract that emits them, in the words a failure message prints.
/// `omits` lists the constants that owner itself leaves out, which it does not
/// own and a covered module must therefore carry on its own. A namespace shared
/// across archives passes an empty list, because its own guard forces every
/// constant of it to be emitted.
pub const ConstOwner = struct { by: []const u8, module: type, omits: []const ConstOmission };

fn isIntegerConst(comptime M: type, comptime name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "GLOWCAP_")) return false;
    return switch (@typeInfo(@TypeOf(@field(M, name)))) {
        .int, .comptime_int => true,
        else => false,
    };
}

fn declaredIn(comptime modules: anytype, comptime name: []const u8) bool {
    inline for (modules) |M| {
        if (@hasDecl(M, name)) return true;
    }
    return false;
}

fn listed(comptime names: []const []const u8, comptime name: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

fn omitsName(comptime omits: []const ConstOmission, comptime name: []const u8) bool {
    for (omits) |row| {
        if (std.mem.eql(u8, row.name, name)) return true;
    }
    return false;
}

/// The covering owner of `name` among `covered`, as an index, or `covered.len`.
/// An owner covers a name it declares and does not omit.
fn coveringOwner(comptime covered: anytype, comptime name: []const u8) usize {
    inline for (covered, 0..) |owner, i| {
        if (@hasDecl(owner.module, name) and !omitsName(owner.omits, name)) return i;
    }
    return covered.len;
}

/// Coverage guard for a constant list, both directions. Call it from a
/// top-level `comptime` block. It walks the integer `GLOWCAP_*` declarations
/// of the modules in `modules` and nothing else. Each one must be in
/// `emitted`, have a row in `omitted`, or be declared by a module in
/// `covered` with the same value, which makes it that owner's constant. A name
/// in `emitted` must be declared by a walked module, an omission row must name
/// a walked integer declaration, give a reason, and name no emitted or covered
/// constant, and no name may repeat in either list. `owner` names the output.
/// `add_hint` is the caller's instruction for a constant the output does not
/// yet account for, printed in that failure.
pub fn guardConstants(
    comptime owner: []const u8,
    comptime add_hint: []const u8,
    comptime modules: anytype,
    comptime emitted: []const []const u8,
    comptime omitted: []const ConstOmission,
    comptime covered: anytype,
) void {
    comptime {
        // The widest walk, the binding registries over nine archive modules, needs 2^18 branches. This sets four times that.
        @setEvalBranchQuota(1 << 20);
        for (modules) |M| {
            for (@typeInfo(M).@"struct".decl_names) |name| {
                if (!isIntegerConst(M, name)) continue;
                if (listed(emitted, name)) continue;
                const i = coveringOwner(covered, name);
                if (i < covered.len) {
                    const own = covered[i];
                    if (@field(M, name) != @field(own.module, name))
                        @compileError(owner ++ " re-exports " ++ name ++ " with a value that differs from " ++ own.by ++ ": a re-export must alias the owner's declaration");
                    continue;
                }
                if (!omitsName(omitted, name)) @compileError("constant not in " ++ owner ++ ": " ++ name ++ " (" ++ add_hint ++ ")");
            }
        }
        for (emitted, 0..) |name, i| {
            if (!declaredIn(modules, name)) @compileError(owner ++ " carries '" ++ name ++ "', which no walked module declares: remove it from the list");
            if (listed(emitted[0..i], name)) @compileError(owner ++ " carries '" ++ name ++ "' more than once: remove the repeat");
        }
        for (omitted, 0..) |row, i| {
            if (!declaredIn(modules, row.name)) @compileError(owner ++ " omits '" ++ row.name ++ "', which no walked module declares: remove the row");
            const is_int = for (modules) |M| {
                if (@hasDecl(M, row.name) and isIntegerConst(M, row.name)) break true;
            } else false;
            if (!is_int) @compileError(owner ++ " omits '" ++ row.name ++ "', which is not an integer constant: remove the row");
            if (std.mem.trim(u8, row.reason, " \t\r\n").len == 0) @compileError(owner ++ " omits '" ++ row.name ++ "' with no reason: give it one");
            if (listed(emitted, row.name)) @compileError(owner ++ " omits '" ++ row.name ++ "', which it also carries: remove the row");
            if (coveringOwner(covered, row.name) < covered.len)
                @compileError(owner ++ " omits '" ++ row.name ++ "', which " ++ covered[coveringOwner(covered, row.name)].by ++ " already owns: remove the row");
            if (omitsName(omitted[0..i], row.name)) @compileError(owner ++ " omits '" ++ row.name ++ "' more than once: remove the repeat");
        }
    }
}
