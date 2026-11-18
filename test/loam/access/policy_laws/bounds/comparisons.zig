//! Supply the actual Zig decisions for unbounded and ordered limits to Bend.
const std = @import("std");
const bounds = @import("policy_bounds");

pub fn main(init: std.process.Init) !void {
    var buffer: [512]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    const writer = &output.interface;
    try writer.writeAll(
        \\import Base
        \\
        \\type Comparison is Data:
        \\  UnrestrictedParent{}
        \\  UnrestrictedChild{}
        \\  Ordered{order: Cmp}
        \\
    );
    const Tag = @typeInfo(bounds.Comparison).@"union".tag_type.?;
    const max = std.math.maxInt(u64);
    inline for (std.enums.values(bounds.Operator)) |operator| {
        const name = switch (operator) {
            .lower_bound, .upper_bound => @tagName(operator),
        };
        try writer.print("\ndef {s}(comparison: Comparison) -> Bool:\n  match comparison:\n", .{name});
        inline for (std.enums.values(Tag)) |tag| switch (tag) {
            .unrestricted_parent => {
                _ = try answer(operator, .unrestricted_parent, null, null);
                try writer.print("    case UnrestrictedParent{{}}: {s}\n", .{try answer(operator, .unrestricted_parent, max, null)});
            },
            .unrestricted_child => try writer.print("    case UnrestrictedChild{{}}: {s}\n", .{try answer(operator, .unrestricted_child, null, 0)}),
            .ordered => {
                try writer.writeAll("    case Ordered{order}:\n      match order:\n");
                inline for (std.enums.values(std.math.Order)) |order| {
                    const ctor, const a, const b = switch (order) {
                        .lt => .{ "LT", 0, max },
                        .eq => .{ "EQ", max, max },
                        .gt => .{ "GT", max, 0 },
                    };
                    try writer.print("        case {s}{{}}: {s}\n", .{ ctor, try answer(operator, .{ .ordered = order }, a, b) });
                }
            },
        };
    }
    try writer.flush();
}

// Check that the public operations reach this decision and return its operand.
fn answer(op: bounds.Operator, comparison: bounds.Comparison, child: ?u64, parent: ?u64) ![]const u8 {
    const allowed = bounds.accepts(op, comparison);
    if (bounds.fits(op, child, parent) != allowed) return error.MisclassifiedLimit;
    if (bounds.intersect(op, child, parent) != (if (allowed) child else parent)) return error.WrongOperand;
    return if (allowed) "True{}" else "False{}";
}
