//! Fixtures for tests of the views walk: a chain of nested lists and a view
//! whose count and cursor disagree.

const std = @import("std");
const model = @import("glowcap").ocapn.model;

pub const Nested = struct {
    backing: []const [1]model.Argument,

    /// A chain of `containers` lists around one innermost argument.
    pub fn build(arena: std.mem.Allocator, containers: usize, innermost: model.Argument) !Nested {
        const backing = try arena.alloc([1]model.Argument, containers + 1);
        backing[containers][0] = innermost;
        var depth = containers;
        while (depth != 0) {
            depth -= 1;
            backing[depth][0] = .{ .list = &backing[depth + 1] };
        }
        return .{ .backing = backing };
    }

    pub fn args(self: Nested) model.view.Args {
        return .fromOwnedSlice(&self.backing[0]);
    }
};

pub const Lying = struct {
    pub const table: model.view.Args.VTable = .{ .len = len, .at = at, .next = next, .tail = tail };
    pub const shorter = model.view.Args.Ctx{ .w0 = 1 };
    pub const longer = model.view.Args.Ctx{ .w0 = 3 };
    pub const failing = model.view.Args.Ctx{ .w0 = 2 };

    /// The count it claims is `w0`, and the cursor yields two integers, or
    /// fails on the second when `w0` is 2.
    fn len(ctx: model.view.Args.Ctx) model.view.ProjectError!usize {
        return @intCast(ctx.w0);
    }
    fn at(_: model.view.Args.Ctx, _: usize) model.view.ProjectError!model.view.Argument {
        return error.MalformedView;
    }
    fn next(ctx: model.view.Args.Ctx, cursor: *u64, out: *model.view.Argument) model.view.ProjectError!bool {
        if (cursor.* >= 2) return false;
        if (cursor.* == 1 and ctx.w0 == 2) return error.MalformedView;
        out.* = .{ .integer = @intCast(cursor.*) };
        cursor.* += 1;
        return true;
    }
    fn tail(_: model.view.Args.Ctx, _: usize) model.view.ProjectError!model.view.Args.Ctx {
        return error.MalformedView;
    }
};
