//! Rust's compact typed failure descriptor, reflected from the core contract.
const std = @import("std");
const s = @import("break_cause_schema.zig");
const Buffer = s.Buffer;
fn enumeration(out: *Buffer, a: std.mem.Allocator, comptime T: type, comptime name: []const u8) !void {
    try out.print(a, "\n#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]\n#[repr(u8)]\npub enum {s} {{\n", .{name});
    inline for (std.enums.values(T)) |value| {
        if (@backingInt(value) == 0) try out.appendSlice(a, "\t#[default]\n");
        try out.appendSlice(a, "\t");
        try s.pascal(out, a, @tagName(value));
        try out.print(a, " = {d},\n", .{@backingInt(value)});
    }
    try out.print(a, "}}\nimpl {s} {{\n\tpub fn from_raw(raw: u32) -> Option<Self> {{\n\t\tmatch raw {{\n", .{name});
    inline for (std.enums.values(T)) |value| {
        try out.print(a, "\t\t\t{d} => Some(Self::", .{@backingInt(value)});
        try s.pascal(out, a, @tagName(value));
        try out.appendSlice(a, "),\n");
    }
    try out.appendSlice(a, "\t\t\t_ => None,\n\t\t}\n\t}\n}\n");
}
pub fn generate(out: *Buffer, a: std.mem.Allocator) !void {
    try enumeration(out, a, s.Origin, "BreakOrigin");
    try enumeration(out, a, s.Reason, "BreakReason");
    try enumeration(out, a, s.RouteFailure, "RouteFailure");
    try @import("route_failure.zig").rust(out, a);
    try out.appendSlice(a, "\n" ++
        "#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]\n" ++
        "pub struct BreakContext(u8);\n" ++
        "impl BreakContext {\n");
    try out.print(a, "\tpub fn from_raw(raw: u32) -> Option<Self> {{\n\t\tif raw & !{d} == 0 {{ Some(Self(raw as u8)) }} else {{ None }}\n\t}}\n\tpub fn raw(self) -> u32 {{\n\t\tu32::from(self.0)\n\t}}\n", .{s.context_mask});
    inline for (@typeInfo(s.Context).@"struct".field_names) |name| {
        try out.print(a, "\tpub fn {s}(self) -> bool {{\n\t\tself.0 & {d} != 0\n\t}}\n\tpub fn with_{s}(self) -> Self {{\n\t\tSelf(self.0 | {d})\n\t}}\n", .{ name, s.contextMask(name), name, s.contextMask(name) });
    }
    try out.appendSlice(a, "}\n" ++
        "#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]\n" ++
        "pub struct BreakCause {\n" ++
        "\tpub origin: BreakOrigin,\n" ++
        "\tpub reason: BreakReason,\n" ++
        "\tpub context: BreakContext,\n" ++
        "}\n" ++
        "impl BreakCause {\n" ++
        "\tpub fn local(reason: BreakReason) -> Self {\n" ++
        "\t\tSelf {\n" ++
        "\t\t\torigin: BreakOrigin::Local,\n" ++
        "\t\t\treason,\n" ++
        "\t\t\tcontext: BreakContext::default(),\n" ++
        "\t\t}\n" ++
        "\t}\n" ++
        "\tpub fn partner() -> Self {\n" ++
        "\t\tSelf {\n" ++
        "\t\t\torigin: BreakOrigin::Partner,\n" ++
        "\t\t\treason: BreakReason::Application,\n" ++
        "\t\t\tcontext: BreakContext::default(),\n" ++
        "\t\t}\n" ++
        "\t}\n" ++
        "\tpub(crate) fn from_raw(raw: crate::sys::GlowcapBreakCause) -> Option<Self> {\n" ++
        "\t\tlet origin = BreakOrigin::from_raw(raw.origin)?;\n" ++
        "\t\tlet reason = BreakReason::from_raw(raw.reason)?;\n" ++
        "\t\tlet context = BreakContext::from_raw(raw.context)?;\n" ++
        "\t\tmatch (origin, reason) {\n");
    var first = true;
    inline for (std.enums.values(s.Origin)) |origin| inline for (std.enums.values(s.Reason)) |reason| {
        if (comptime s.valid(origin, reason)) {
            try out.appendSlice(a, if (first) "\t\t\t(" else "\n\t\t\t| (");
            first = false;
            try out.appendSlice(a, "BreakOrigin::");
            try s.pascal(out, a, @tagName(origin));
            try out.appendSlice(a, ", BreakReason::");
            try s.pascal(out, a, @tagName(reason));
            try out.append(a, ')');
        }
    };
    try out.appendSlice(a, " => Some(Self {\n\t\t\t\torigin,\n\t\t\t\treason,\n\t\t\t\tcontext,\n\t\t\t}),\n");
    try out.appendSlice(a, "\t\t\t_ => None,\n" ++
        "\t\t}\n" ++
        "\t}");
    try out.append(a, '\n');
    inline for (@typeInfo(s.Context).@"struct".field_names) |name| {
        try out.print(a, "\tpub fn with_{s}(mut self) -> Self {{\n\t\tself.context = self.context.with_{s}();\n\t\tself\n\t}}\n", .{ name, name });
    }
    try out.appendSlice(a, "\tpub(crate) fn raw(self) -> crate::sys::GlowcapBreakCause {\n" ++
        "\t\tcrate::sys::GlowcapBreakCause {\n" ++
        "\t\t\torigin: self.origin as u32,\n" ++
        "\t\t\treason: self.reason as u32,\n" ++
        "\t\t\tcontext: self.context.raw(),\n" ++
        "\t\t}\n" ++
        "\t}");
    try @import("break_cause_queries.zig").generate(out, a, .rust);
    try out.appendSlice(a, "\tpub fn label(self) -> Option<&'static str> {\n");
    inline for (.{ "restoration", "withdrawal" }) |name| {
        const cause = comptime blk: {
            var value: s.Cause = .{};
            @field(value.context, name) = true;
            break :blk value;
        };
        try out.print(a, "\t\tif self.context.{s}() {{\n\t\t\treturn Some(\"{s}\");\n\t\t}}\n", .{ name, cause.label().? });
    }
    try out.appendSlice(a, "\t\tif self.origin != BreakOrigin::Local {\n\t\t\treturn None;\n\t\t}\n\t\tmatch self.reason {\n");
    inline for (std.enums.values(s.Reason)) |reason| {
        if (comptime s.Cause.local(reason).label()) |label| {
            try out.appendSlice(a, "\t\t\tBreakReason::");
            try s.pascal(out, a, @tagName(reason));
            try out.print(a, " => Some(\"{s}\"),\n", .{label});
        }
    }
    try out.appendSlice(a, "\t\t\t_ => None,\n\t\t}\n\t}\n}\n");
}
