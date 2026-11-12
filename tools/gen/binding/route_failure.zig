//! Dial reports and their exact inverse, reflected from RouteFailure.cause().
const std = @import("std");
const s = @import("break_cause_schema.zig");
const Buffer = s.Buffer;

pub fn rust(out: *Buffer, a: std.mem.Allocator) !void {
    try out.appendSlice(a, "impl RouteFailure {\n\tpub fn cause(self) -> BreakCause {\n\t\tmatch self {\n");
    inline for (std.enums.values(s.RouteFailure)) |value| {
        const cause = comptime value.cause();
        try out.appendSlice(a, "\t\t\tSelf::");
        try s.pascal(out, a, @tagName(value));
        try out.appendSlice(a, " => BreakCause {\n\t\t\t\torigin: BreakOrigin::");
        try s.pascal(out, a, @tagName(cause.origin));
        try out.appendSlice(a, ",\n\t\t\t\treason: BreakReason::");
        try s.pascal(out, a, @tagName(cause.reason));
        try out.print(a, ",\n\t\t\t\tcontext: BreakContext({d}),\n\t\t\t}},\n", .{s.contextBits(cause.context)});
    }
    try out.appendSlice(a, "\t\t}\n\t}\n\tpub fn from_cause(cause: BreakCause) -> Option<Self> {\n");
    inline for (std.enums.values(s.RouteFailure)) |value| {
        try out.appendSlice(a, "\t\tif cause == Self::");
        try s.pascal(out, a, @tagName(value));
        try out.appendSlice(a, ".cause() {\n\t\t\treturn Some(Self::");
        try s.pascal(out, a, @tagName(value));
        try out.appendSlice(a, ");\n\t\t}\n");
    }
    try out.appendSlice(a, "\t\tNone\n\t}\n}\n");
}

pub fn python(out: *Buffer, a: std.mem.Allocator) !void {
    try out.appendSlice(a, "\n    def cause(self) -> \"BreakCause\":\n");
    inline for (std.enums.values(s.RouteFailure)) |value| {
        const cause = comptime value.cause();
        try out.appendSlice(a, "        if self == self.");
        try s.upper(out, a, @tagName(value));
        try out.appendSlice(a, ":\n            return BreakCause(BreakOrigin.");
        try s.upper(out, a, @tagName(cause.origin));
        try out.appendSlice(a, ", BreakReason.");
        try s.upper(out, a, @tagName(cause.reason));
        try out.print(a, ", {d})\n", .{s.contextBits(cause.context)});
    }
    try out.appendSlice(a, "        raise ValueError(self)\n\n    @classmethod\n    def from_cause(cls, cause: \"BreakCause\") -> \"RouteFailure | None\":\n");
    inline for (std.enums.values(s.RouteFailure)) |value| {
        const cause = comptime value.cause();
        try out.appendSlice(a, "        if (cause.origin == BreakOrigin.");
        try s.upper(out, a, @tagName(cause.origin));
        try out.appendSlice(a, " and cause.reason == BreakReason.");
        try s.upper(out, a, @tagName(cause.reason));
        try out.print(a, " and cause.context == {d}):\n            return cls.", .{s.contextBits(cause.context)});
        try s.upper(out, a, @tagName(value));
        try out.append(a, '\n');
    }
    try out.appendSlice(a, "        return None\n");
}

pub fn ts(out: *Buffer, a: std.mem.Allocator) !void {
    try out.appendSlice(a, "\nexport function routeFailureCause(value: RouteFailure): BreakCause {\n    switch (value) {\n");
    inline for (std.enums.values(s.RouteFailure)) |value| {
        const cause = comptime value.cause();
        try out.appendSlice(a, "        case RouteFailure.");
        try s.pascal(out, a, @tagName(value));
        try out.appendSlice(a, ": return new BreakCause(BreakOrigin.");
        try s.pascal(out, a, @tagName(cause.origin));
        try out.appendSlice(a, ", BreakReason.");
        try s.pascal(out, a, @tagName(cause.reason));
        try out.print(a, ", {d});\n", .{s.contextBits(cause.context)});
    }
    try out.appendSlice(a, "    }\n}\nexport function routeFailureFromCause(cause: BreakCause): RouteFailure | null {\n");
    inline for (std.enums.values(s.RouteFailure)) |value| {
        const cause = comptime value.cause();
        try out.appendSlice(a, "    if (cause.origin === BreakOrigin.");
        try s.pascal(out, a, @tagName(cause.origin));
        try out.appendSlice(a, " && cause.reason === BreakReason.");
        try s.pascal(out, a, @tagName(cause.reason));
        try out.print(a, " && cause.context === {d}) return RouteFailure.", .{s.contextBits(cause.context)});
        try s.pascal(out, a, @tagName(value));
        try out.appendSlice(a, ";\n");
    }
    try out.appendSlice(a, "    return null;\n}\n");
}

pub fn racket(out: *Buffer, a: std.mem.Allocator) !void {
    try out.appendSlice(a, "\n(provide route-failure-cause route-failure-from-cause)\n(define (route-failure-cause value)\n  (case value\n");
    inline for (std.enums.values(s.RouteFailure)) |value| {
        const cause = comptime value.cause();
        try out.appendSlice(a, "    [(");
        try s.kebab(out, a, @tagName(value));
        try out.appendSlice(a, ") (break-cause '");
        try s.kebab(out, a, @tagName(cause.origin));
        try out.appendSlice(a, " '");
        try s.kebab(out, a, @tagName(cause.reason));
        try out.print(a, " {d})]\n", .{s.contextBits(cause.context)});
    }
    try out.appendSlice(a, "    [else #f]))\n(define (route-failure-from-cause cause)\n  (for/first ([value '(");
    inline for (std.enums.values(s.RouteFailure), 0..) |value, i| {
        if (i != 0) try out.append(a, ' ');
        try s.kebab(out, a, @tagName(value));
    }
    try out.appendSlice(a, ")]\n              #:when (equal? cause (route-failure-cause value)))\n    value))\n");
}
