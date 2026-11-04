//! Rust creation projection. The template delegates promise ownership and
//! observation to the binding and adds no observation allocation of its own.
const std = @import("std");
const model = @import("model.zig");
const Creation = model.Creation;
const calls = @import("calls.zig");
const callbacks = @import("callbacks.zig");
const literal = @import("literal.zig").write;

pub fn emit(a: std.mem.Allocator, method: Creation, reads: []const calls.Named) ![]u8 {
    if (!std.mem.eql(u8, method.wire_name, model.creation_method)) return error.UnsupportedProjection;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "// Generated from checked interface descriptions.\n");
    try out.print(a, "const MIN_TEXT_BYTES: usize = {d};\nconst MAX_TEXT_BYTES: usize = {d};\nconst ADD_VERB: &str = ", .{ method.minimum, method.maximum });
    try literal(&out, a, method.wire_name);
    try out.appendSlice(a, ";\n");
    var needs = try callbacks.requirements(reads);
    needs.receipt = true;
    needs.replies.insert(.target);
    try needs.emit(&out, a);
    try out.appendSlice(a, @embedFile("templates/creation.rs"));
    try callbacks.emitMethods(&out, a, reads);
    return out.toOwnedSlice(a);
}
