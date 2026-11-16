//! Values nested to a chosen depth around one innermost shape, in each form
//! the nesting ceiling (`model.max_value_depth`) is held on: the owned model,
//! the borrowed views, and the Host's value. The boundary tests sweep `depth`
//! across the ceiling and ask `admitted` what each path must answer.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const view = model.view;
const Value = glowcap.driver.core.Value;

/// What sits at the bottom of the chain. A leaf holds nothing. The others are
/// containers with nothing inside, and a container's items sit one level
/// deeper than it, empty or not.
pub const Shape = enum { leaf, empty_list, empty_struct, empty_run, run };

pub const all = [_]Shape{ .leaf, .empty_list, .empty_struct, .empty_run, .run };

/// Shapes the owned model can express: it has no integer-run arm.
pub const owned = [_]Shape{ .leaf, .empty_list, .empty_struct };

/// The depths a boundary test sweeps: one inside, the ceiling, one past.
pub const sweep = [_]usize{ model.max_value_depth - 1, model.max_value_depth, model.max_value_depth + 1 };

/// Whether the innermost node at `depth` is within the ceiling. A leaf may sit
/// at the ceiling and a container may not, because its items would sit past it.
pub fn admitted(shape: Shape, depth: usize) bool {
    return switch (shape) {
        .leaf => depth <= model.max_value_depth,
        else => depth < model.max_value_depth,
    };
}

/// The words of a non-empty run, 8-aligned as the views require.
const run_words align(8) = [_]u8{ 1, 0, 0, 0, 0, 0, 0, 0 };

/// `depth` single-element lists around `shape`: the innermost node sits at
/// `depth`. The slice is the argument list of one message.
pub fn ownedArgs(arena: std.mem.Allocator, depth: usize, shape: Shape) ![]const model.Argument {
    const innermost: model.Argument = switch (shape) {
        .leaf => .{ .void = {} },
        .empty_list => .{ .list = &.{} },
        .empty_struct => .{ .@"struct" = &.{} },
        .empty_run, .run => unreachable,
    };
    const backing = try arena.alloc([1]model.Argument, depth + 1);
    backing[depth][0] = innermost;
    var level = depth;
    while (level != 0) {
        level -= 1;
        backing[level][0] = .{ .list = &backing[level + 1] };
    }
    return &backing[0];
}

/// The same chain as borrowed views, runs included.
pub fn viewArgs(arena: std.mem.Allocator, depth: usize, shape: Shape) !view.Args {
    const innermost: view.Argument = switch (shape) {
        .leaf => .{ .void = {} },
        .empty_list => .{ .list = .fromViews(&.{}) },
        .empty_struct => .{ .@"struct" = .fromViews(&.{}) },
        .empty_run => .{ .list = .fromRun(run_words[0..0]) },
        .run => .{ .list = .fromRun(&run_words) },
    };
    const backing = try arena.alloc([1]view.Argument, depth + 1);
    backing[depth][0] = innermost;
    var level = depth;
    while (level != 0) {
        level -= 1;
        backing[level][0] = .{ .list = .fromViews(&backing[level + 1]) };
    }
    return .fromViews(&backing[0]);
}

/// The same chain as the Host's values, runs included.
pub fn valueArgs(arena: std.mem.Allocator, depth: usize, shape: Shape) ![]const Value {
    const innermost: Value = switch (shape) {
        .leaf => .{ .void = {} },
        .empty_list => .{ .list = &.{} },
        .empty_struct => .{ .@"struct" = &.{} },
        .empty_run => .{ .integers = &.{} },
        .run => .{ .integers = &.{1} },
    };
    const backing = try arena.alloc([1]Value, depth + 1);
    backing[depth][0] = innermost;
    var level = depth;
    while (level != 0) {
        level -= 1;
        backing[level][0] = .{ .list = &backing[level + 1] };
    }
    return &backing[0];
}

/// The chain as one owned argument whose every container slice is its own
/// allocation from `allocator`, the form a session takes ownership of when it
/// consumes a resolution.
pub fn ownedHeap(allocator: std.mem.Allocator, depth: usize, shape: Shape) !model.Argument {
    var node: model.Argument = switch (shape) {
        .leaf => .{ .void = {} },
        .empty_list => .{ .list = try allocator.alloc(model.Argument, 0) },
        .empty_struct => .{ .@"struct" = try allocator.alloc(model.StructEntry, 0) },
        .empty_run, .run => unreachable,
    };
    var level: usize = 0;
    while (level != depth) : (level += 1) {
        const wrap = allocator.alloc(model.Argument, 1) catch |err| {
            model.freeArgument(allocator, node);
            return err;
        };
        wrap[0] = node;
        node = .{ .list = wrap };
    }
    return node;
}
