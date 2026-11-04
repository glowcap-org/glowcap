//! Rust creation projection. The template delegates promise ownership and
//! observation to the binding and adds no observation allocation of its own.
const std = @import("std");
const model = @import("model.zig");
const Creation = model.Creation;
const literal = @import("literal.zig").write;

pub fn emit(a: std.mem.Allocator, method: Creation) ![]u8 {
    if (!std.mem.eql(u8, method.wire_name, model.creation_method)) return error.UnsupportedProjection;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "// Generated from checked interface descriptions.\n");
    try out.print(a, "const MIN_TEXT_BYTES: usize = {d};\nconst MAX_TEXT_BYTES: usize = {d};\nconst ADD_VERB: &str = ", .{ method.minimum, method.maximum });
    try literal(&out, a, method.wire_name);
    try out.appendSlice(a, ";\n");
    const needs: @import("rust_support.zig").Needs = .{ .receipt = true, .replies = .initOne(.target) };
    try needs.emit(&out, a);
    try out.appendSlice(a, @embedFile("templates/creation.rs"));
    return out.toOwnedSlice(a);
}
