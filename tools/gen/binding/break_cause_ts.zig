//! TypeScript failure metadata mirrors the core's fields and allowed provenance.
const std = @import("std");
const s = @import("break_cause_schema.zig");
const Buffer = s.Buffer;
pub fn generate(out: *Buffer, a: std.mem.Allocator) !void {
    try @import("route_failure.zig").ts(out, a);
    inline for (.{ .{ s.Origin, "BreakOrigin" }, .{ s.Reason, "BreakReason" }, .{ s.RouteFailure, "RouteFailure" } }) |group| {
        try out.print(a, "\nexport enum {s} {{\n", .{group[1]});
        inline for (std.enums.values(group[0])) |value| {
            try out.appendSlice(a, "\t");
            try s.pascal(out, a, @tagName(value));
            try out.print(a, " = {d},\n", .{@backingInt(value)});
        }
        try out.appendSlice(a, "}\n");
        if (group[0] == s.RouteFailure) continue;
        try out.print(a, "function read{s}(raw: number): {s} | null {{\n\tswitch (raw) {{\n", .{ group[1], group[1] });
        inline for (std.enums.values(group[0])) |value| {
            try out.print(a, "\t\tcase {d}: return {s}.", .{ @backingInt(value), group[1] });
            try s.pascal(out, a, @tagName(value));
            try out.appendSlice(a, ";\n");
        }
        try out.appendSlice(a, "\t\tdefault: return null;\n\t}\n}\n");
    }
    try out.appendSlice(a, "\nexport enum BreakContext {\n");
    inline for (@typeInfo(s.Context).@"struct".field_names) |name| {
        try out.appendSlice(a, "\t");
        try s.pascal(out, a, name);
        try out.print(a, " = {d},\n", .{s.contextMask(name)});
    }
    try out.appendSlice(a,
        \\}
        \\export interface RawBreakCause { origin: number; reason: number; context: number }
        \\export class BreakCause implements RawBreakCause {
        \\    constructor(
        \\        readonly origin: BreakOrigin = BreakOrigin.Unspecified,
        \\        readonly reason: BreakReason = BreakReason.Unspecified,
        \\        readonly context: number = 0,
        \\    ) {}
        \\    static local(reason: BreakReason): BreakCause { return new BreakCause(BreakOrigin.Local, reason); }
        \\    static partner(): BreakCause { return new BreakCause(BreakOrigin.Partner, BreakReason.Application); }
        \\    static fromRaw(raw: RawBreakCause): BreakCause | null {
        \\        const origin = readBreakOrigin(raw.origin);
        \\        const reason = readBreakReason(raw.reason);
        \\
    );
    try out.print(a, "        if (origin === null || reason === null || !Number.isInteger(raw.context) || raw.context < 0 || raw.context > {d}) return null;\n", .{s.context_mask});
    try out.appendSlice(a, "        switch (origin) {\n");
    inline for (std.enums.values(s.Origin)) |origin| {
        try out.appendSlice(a, "            case BreakOrigin.");
        try s.pascal(out, a, @tagName(origin));
        try out.appendSlice(a, ":\n                if (");
        comptime var first = true;
        inline for (std.enums.values(s.Reason)) |reason| {
            if (comptime s.valid(origin, reason)) {
                if (!first) try out.appendSlice(a, " || ");
                try out.appendSlice(a, "reason === BreakReason.");
                try s.pascal(out, a, @tagName(reason));
                first = false;
            }
        }
        try out.appendSlice(a, ") return new BreakCause(origin, reason, raw.context);\n                return null;\n");
    }
    try out.appendSlice(a,
        \\        }
        \\    }
    );
    try @import("break_cause_queries.zig").generate(out, a, .ts);
    try out.appendSlice(a,
        \\    label(): string | null {
        \\
    );
    inline for (.{ "restoration", "withdrawal" }) |name| {
        const cause = comptime blk: {
            var value: s.Cause = .{};
            @field(value.context, name) = true;
            break :blk value;
        };
        try out.appendSlice(a, "        if (this.context & BreakContext.");
        try s.pascal(out, a, name);
        try out.print(a, ") return \"{s}\";\n", .{cause.label().?});
    }
    try out.appendSlice(a, "        if (this.origin !== BreakOrigin.Local) return null;\n        switch (this.reason) {\n");
    inline for (std.enums.values(s.Reason)) |reason| if (comptime s.Cause.local(reason).label()) |label| {
        try out.appendSlice(a, "            case BreakReason.");
        try s.pascal(out, a, @tagName(reason));
        try out.print(a, ": return \"{s}\";\n", .{label});
    };
    try out.appendSlice(a, "            default: return null;\n        }\n    }\n}\n");
}
