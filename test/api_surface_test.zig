//! Every exported declaration must compile.
//!
//! Zig analyzes lazily: a public function nobody references is never
//! semantically checked, so it can drift against std or against its own layer
//! while the gate stays green. Referencing the whole public `glowcap`
//! namespace recursively turns that drift into a compile error in
//! `zig build test`, the API surface matters even where no scenario
//! exercises it yet. (`std.testing` ships only the shallow `refAllDecls`, status-allow: pending state or quoted runtime label
//! which would skip the method bodies of exported types, so the recursive
//! walk lives here.)

const std = @import("std");
const glowcap = @import("glowcap");

fn refAllDeclsRecursive(comptime T: type) void {
    inline for (comptime std.meta.declarations(T)) |decl_name| {
        if (@TypeOf(@field(T, decl_name)) == type) {
            switch (@typeInfo(@field(T, decl_name))) {
                .@"struct", .@"enum", .@"union", .@"opaque" => refAllDeclsRecursive(@field(T, decl_name)),
                else => {},
            }
        }
        _ = &@field(T, decl_name);
    }
}

test "every exported glowcap declaration is semantically analyzed" {
    @setEvalBranchQuota(1_000_000);
    comptime refAllDeclsRecursive(glowcap);
}
