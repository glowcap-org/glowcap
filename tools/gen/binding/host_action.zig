//! Pass the Bend projections to the standard generated-file writer and verifier.
const std = @import("std");
const Output = @import("output").Output;
pub const source_dir = "tools/gen/binding/host_action";
pub const targets = [_]struct { renderer: []const u8, path: []const u8 }{
    .{ .renderer = "typescript", .path = "bindings/ts/runtime/internal/host_action.ts" },
    .{ .renderer = "rust", .path = "bindings/rust/src/host_action_gen.rs" },
    .{ .renderer = "python", .path = "bindings/python/glowcap/_host_action_gen.py" },
    .{ .renderer = "racket", .path = "bindings/racket/private/host-action-gen.rkt" },
};

pub const scripts = blk: {
    var paths: [targets.len][]const u8 = undefined;
    for (targets, 0..) |target, index| paths[index] = source_dir ++ "/" ++ target.renderer ++ ".bend";
    break :blk paths;
};

pub const step_name = "gen-binding-host-action";
pub const outputs = blk: {
    var files: [targets.len]Output = undefined;
    for (targets, 0..) |target, index| files[index] = .{
        .path = target.path,
        .generate = struct {
            fn bytes(allocator: std.mem.Allocator) ![]u8 {
                return allocator.dupe(u8, @embedFile(target.renderer));
            }
        }.bytes,
    };
    break :blk files;
};
