//! Reflect the Host ABI into the Bend type the binding generator consumes.
const std = @import("std");
const host = @import("c_abi_host");

const Tag = struct {
    name: []const u8,
    value: u32,

    fn byValue(_: void, a: Tag, b: Tag) bool {
        return a.value < b.value;
    }
};

const tags = blk: {
    const prefix = "GLOWCAP_HOST_ACTION_";
    const declarations = std.meta.declarations(host);
    @setEvalBranchQuota(1000 + 32 * declarations.len);
    var found: []const Tag = &.{};
    for (declarations) |decl| {
        if (std.mem.startsWith(u8, decl, prefix))
            found = found ++ [_]Tag{.{ .name = decl[prefix.len..], .value = @field(host, decl) }};
    }
    if (found.len == 0) @compileError("Host ABI declares no actions");
    var sorted = found[0..found.len].*;
    std.mem.sort(Tag, &sorted, {}, Tag.byValue);
    for (sorted[1..], sorted[0 .. sorted.len - 1]) |current, previous| {
        if (current.value == previous.value)
            @compileError("duplicate Host action discriminant for " ++ current.name ++ " and " ++ previous.name);
    }
    break :blk sorted;
};

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    const out = &stdout.interface;
    try out.writeAll("import Base\n\ntype Tag is Data:\n");
    for (tags) |tag| try out.print("  {s}{{}}\n", .{tag.name});
    try out.writeAll("\ndef all() -> List<&2, Tag>:\n  [");
    for (tags, 0..) |tag, i| {
        if (i > 0) try out.writeAll(", ");
        try out.print("{s}{{}}", .{tag.name});
    }
    try out.writeAll("]\n\ndef name(t: Tag) -> String:\n  match t:\n");
    for (tags) |tag| try out.print("    case {s}{{}}:\n      \"{s}\"\n", .{ tag.name, tag.name });
    try out.writeAll("\ndef number(t: Tag) -> U32:\n  match t:\n");
    for (tags) |tag| try out.print("    case {s}{{}}:\n      {d}\n", .{ tag.name, tag.value });
    try out.flush();
}
