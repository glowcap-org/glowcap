//! Pinned authoring inputs for interface generation and its independent proof.
//! This flat fixture registration does no filesystem loading or validation.
const std = @import("std");
const text = @import("text.zig");

pub const sources = [_]text.Source{
    .{ .path = "contracts.interface", .bytes = @embedFile("authored_entry") },
    .{ .path = "tasks.interface", .bytes = @embedFile("authored_tasks") },
    .{ .path = "loam.interface", .bytes = @embedFile("authored_loam") },
    .{ .path = "fixtures.interface", .bytes = @embedFile("authored_fixtures") },
};

/// Inputs and the compilation arena outlive the returned Model and emission.
pub fn compile(a: std.mem.Allocator, diagnostic: *text.Diagnostic, inputs: [sources.len]text.Source) !text.Compiled {
    diagnostic.* = .{};
    var bundle: text.Bundle = .{ .a = a, .diagnostic = diagnostic };
    for (inputs) |source| _ = try bundle.add(source);
    for (bundle.modules.items) |module| {
        for (module.header.imports) |*import| {
            for (inputs, 0..) |source, index| {
                if (std.mem.eql(u8, import.path, source.path)) {
                    import.target = index;
                    break;
                }
            } else return error.MissingImport;
        }
    }
    return bundle.compile();
}
