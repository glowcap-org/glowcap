//! Racket failure metadata mirrors the core's fields and allowed provenance.
const std = @import("std");
const s = @import("break_cause_schema.zig");
const Buffer = s.Buffer;
pub fn generate(out: *Buffer, a: std.mem.Allocator) !void {
    try @import("route_failure.zig").racket(out, a);
    inline for (.{ .{ s.Origin, "origin" }, .{ s.Reason, "reason" }, .{ s.RouteFailure, "route-failure" } }) |group| {
        try out.print(a, "\n(provide break-{s}-from-code break-{s}-code)\n(define (break-{s}-from-code code)\n  (case code\n", .{ group[1], group[1], group[1] });
        inline for (std.enums.values(group[0])) |value| {
            try out.print(a, "    [({d}) '", .{@backingInt(value)});
            try s.kebab(out, a, @tagName(value));
            try out.appendSlice(a, "]\n");
        }
        try out.print(a, "    [else #f]))\n(define (break-{s}-code value)\n  (case value\n", .{group[1]});
        inline for (std.enums.values(group[0])) |value| {
            try out.appendSlice(a, "    [(");
            try s.kebab(out, a, @tagName(value));
            try out.print(a, ") {d}]\n", .{@backingInt(value)});
        }
        try out.appendSlice(a, "    [else #f]))\n");
    }
    inline for (comptime std.meta.fieldNames(s.Context)) |name| {
        try out.appendSlice(a, "(provide break-context-");
        try s.kebab(out, a, name);
        try out.appendSlice(a, ")\n(define break-context-");
        try s.kebab(out, a, name);
        try out.print(a, " {d})\n", .{s.contextMask(name)});
    }
    try out.appendSlice(a,
        \\(provide (struct-out break-cause) break-cause-from-fields break-cause-label)
        \\(struct break-cause (origin reason context) #:transparent)
        \\(define (break-cause-from-fields origin reason context)
        \\  (define source (break-origin-from-code origin))
        \\  (define why (break-reason-from-code reason))
        \\  (and source why (exact-nonnegative-integer? context)
        \\
    );
    try out.print(a, "       (<= context {d})\n       (member (cons source why) '(\n", .{s.context_mask});
    inline for (std.enums.values(s.Origin)) |origin| inline for (std.enums.values(s.Reason)) |reason| {
        if (comptime s.valid(origin, reason)) {
            try out.appendSlice(a, "         (");
            try s.kebab(out, a, @tagName(origin));
            try out.appendSlice(a, " . ");
            try s.kebab(out, a, @tagName(reason));
            try out.appendSlice(a, ")\n");
        }
    };
    try out.appendSlice(a,
        \\       ))
        \\       (break-cause source why context)))
    );
    try @import("break_cause_queries.zig").generate(out, a, .racket);
    try out.appendSlice(a,
        \\(define (break-cause-label value)
        \\  (cond
        \\    [(not (break-cause? value)) #f]
        \\
    );
    inline for (.{ "restoration", "withdrawal" }) |name| {
        const cause = comptime blk: {
            var value: s.Cause = .{};
            @field(value.context, name) = true;
            break :blk value;
        };
        try out.appendSlice(a, "    [(not (zero? (bitwise-and (break-cause-context value) break-context-");
        try s.kebab(out, a, name);
        try out.print(a, "))) \"{s}\"]\n", .{cause.label().?});
    }
    try out.appendSlice(a, "    [(not (eq? (break-cause-origin value) 'local)) #f]\n    [else (case (break-cause-reason value)\n");
    inline for (std.enums.values(s.Reason)) |reason| if (comptime s.Cause.local(reason).label()) |label| {
        try out.appendSlice(a, "      [(");
        try s.kebab(out, a, @tagName(reason));
        try out.print(a, ") \"{s}\"]\n", .{label});
    };
    try out.appendSlice(a, "      [else #f])]))\n");
}
