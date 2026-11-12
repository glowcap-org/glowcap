//! Python failure metadata mirrors the core's fields and allowed provenance.
const std = @import("std");
const s = @import("break_cause_schema.zig");
const Buffer = s.Buffer;
pub fn generate(out: *Buffer, a: std.mem.Allocator) !void {
    inline for (.{ .{ s.Origin, "BreakOrigin" }, .{ s.Reason, "BreakReason" }, .{ s.RouteFailure, "RouteFailure" } }) |group| {
        try out.print(a, "\nclass {s}(IntEnum):\n", .{group[1]});
        inline for (std.enums.values(group[0])) |value| {
            try out.appendSlice(a, "    ");
            try s.upper(out, a, @tagName(value));
            try out.print(a, " = {d}\n", .{@backingInt(value)});
        }
        if (group[0] == s.RouteFailure) try @import("route_failure.zig").python(out, a);
    }
    inline for (comptime std.meta.fieldNames(s.Context)) |name| {
        try out.appendSlice(a, "\nBREAK_CONTEXT_");
        try s.upper(out, a, name);
        try out.print(a, " = {d}\n", .{s.contextMask(name)});
    }
    try out.appendSlice(a,
        \\
        \\@dataclass(frozen=True, slots=True)
        \\class BreakCause:
        \\    origin: BreakOrigin = BreakOrigin.UNSPECIFIED
        \\    reason: BreakReason = BreakReason.UNSPECIFIED
        \\    context: int = 0
        \\
        \\    @classmethod
        \\    def from_fields(cls, origin: int, reason: int, context: int) -> "BreakCause | None":
        \\        try:
        \\            source = BreakOrigin(origin)
        \\            why = BreakReason(reason)
        \\        except ValueError:
        \\            return None
        \\
    );
    try out.print(a, "        if context < 0 or context & ~{d}:\n            return None\n", .{s.context_mask});
    try out.appendSlice(a, "        if (source, why) not in (\n");
    inline for (std.enums.values(s.Origin)) |origin| inline for (std.enums.values(s.Reason)) |reason| {
        if (comptime s.valid(origin, reason)) {
            try out.appendSlice(a, "            (BreakOrigin.");
            try s.upper(out, a, @tagName(origin));
            try out.appendSlice(a, ", BreakReason.");
            try s.upper(out, a, @tagName(reason));
            try out.appendSlice(a, "),\n");
        }
    };
    try out.appendSlice(a,
        \\        ):
        \\            return None
        \\        return cls(source, why, context)
        \\
    );
    try @import("break_cause_queries.zig").generate(out, a, .python);
    try out.appendSlice(a,
        \\    def label(self) -> str | None:
        \\
    );
    inline for (.{ "restoration", "withdrawal" }) |name| {
        const cause = comptime blk: {
            var value: s.Cause = .{};
            @field(value.context, name) = true;
            break :blk value;
        };
        try out.appendSlice(a, "        if self.context & BREAK_CONTEXT_");
        try s.upper(out, a, name);
        try out.print(a, ":\n            return \"{s}\"\n", .{cause.label().?});
    }
    try out.appendSlice(a, "        if self.origin != BreakOrigin.LOCAL:\n            return None\n        return {\n");
    inline for (std.enums.values(s.Reason)) |reason| if (comptime s.Cause.local(reason).label()) |label| {
        try out.appendSlice(a, "            BreakReason.");
        try s.upper(out, a, @tagName(reason));
        try out.print(a, ": \"{s}\",\n", .{label});
    };
    try out.appendSlice(a, "        }.get(self.reason)\n");
}
