//! Every exported declaration must compile.
//!
//! Zig analyzes lazily: a public function nobody references is never
//! semantically checked, so it can drift against std or against its own layer
//! while the gate stays green. Referencing the whole public `pancake`
//! namespace recursively turns that drift into a compile error in
//! `zig build test` — the API surface is load-bearing even where no scenario
//! exercises it yet. (`std.testing` ships only the shallow `refAllDecls`,
//! which would skip the method bodies of exported types, so the recursive
//! walk lives here.)

const std = @import("std");
const pancake = @import("pancake");

/// A declaration that exists only to fire `@compileError` on misuse must not be
/// analyzed by this walk — referencing it *is* the misuse it traps. Each entry
/// names one such poison decl; a new trap added to the public surface earns its
/// row here in the same change.
fn isPoisonDecl(comptime T: type, comptime name: []const u8) bool {
    // `LazySequence.toOwned` is legal only on the `PipelineOp` instantiation;
    // every other instantiation carries it as a trap redirecting to
    // `toOwnedSlice`.
    return std.mem.eql(u8, name, "toOwned") and
        std.mem.indexOf(u8, @typeName(T), "LazySequence") != null and
        std.mem.indexOf(u8, @typeName(T), "PipelineOp") == null;
}

fn refAllDeclsRecursive(comptime T: type) void {
    inline for (comptime std.meta.declarations(T)) |decl| {
        if (comptime isPoisonDecl(T, decl.name)) continue;
        if (@TypeOf(@field(T, decl.name)) == type) {
            switch (@typeInfo(@field(T, decl.name))) {
                .@"struct", .@"enum", .@"union", .@"opaque" => refAllDeclsRecursive(@field(T, decl.name)),
                else => {},
            }
        }
        _ = &@field(T, decl.name);
    }
}

test "every exported pancake declaration is semantically analyzed" {
    @setEvalBranchQuota(1_000_000);
    comptime refAllDeclsRecursive(pancake);
}
