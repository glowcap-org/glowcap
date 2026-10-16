//! `zig build ocapn-adoption-check`: validate draft and suite adoption accounting.
//! Shared with source-check and required before the live upstream suite runs.
//! Pending and deferred entries are valid accounting, never conformance passes.
const std = @import("std");
const adoption = @import("source_check/docs/ocapn_conformance.zig");

pub fn main(init: std.process.Init) !void {
    const args = init.minimal.args.vector;
    const plan = args.len == 2 and std.mem.eql(u8, std.mem.span(args[1]), "--next-suite-plan");
    if (args.len != 1 and !plan) {
        std.debug.print("usage: ocapn-adoption-check [--next-suite-plan]\n", .{});
        std.process.exit(2);
    }
    const gpa = init.arena.allocator();
    var violations: std.ArrayList([]const u8) = .empty;
    try adoption.checkManifest(init.io, gpa, std.Io.Dir.cwd(), &violations);
    for (violations.items) |message| std.debug.print("ocapn-adoption-check: {s}\n", .{message});
    if (violations.items.len != 0) std.process.exit(1);
    if (plan) {
        const entries = try adoption.nextSuitePlan(init.io, gpa, std.Io.Dir.cwd());
        const json = try std.json.Stringify.valueAlloc(gpa, entries, .{});
        try std.Io.File.stdout().writeStreamingAll(init.io, json);
    }
}
