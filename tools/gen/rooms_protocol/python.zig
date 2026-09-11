//! The Python client's projection of `rooms_protocol.zig`: the same tables
//! as plain tuples and dicts, so the module needs nothing but `re`.

const std = @import("std");
const p = @import("../rooms_protocol.zig");

const Out = std.ArrayList(u8);

pub fn generate(gpa: std.mem.Allocator) ![]u8 {
    var out: Out = .empty;
    errdefer out.deinit(gpa);
    try p.writeHeader(&out, gpa, "#");
    try out.appendSlice(gpa, "#\n# A field is (name, type, nullable, values). The type is one of\n# ");
    for (std.enums.values(p.Ty), 0..) |ty, i| {
        try out.print(gpa, "{s}\"{s}\"", .{ if (i == 0) "" else ", ", ty.wireName() });
    }
    try out.appendSlice(gpa, ";\n# values is the tuple of strings admitted when the field is an enumeration.\n\nimport re\n\n");
    try writeVocabulary(&out, gpa);
    try writeFieldLists(&out, gpa);
    try writeWatchKinds(&out, gpa);
    try writeRoomTails(&out, gpa);
    try out.appendSlice(gpa, "# The text form of a registration id, matched without regard to case.\nREGISTRATION_ID_PATTERN = re.compile(r\"");
    try p.registration_id.writePattern(&out, gpa);
    try out.appendSlice(gpa, "\", re.IGNORECASE)\n");
    return out.toOwnedSlice(gpa);
}

fn py(value: bool) []const u8 {
    return if (value) "True" else "False";
}

/// A tuple of strings in Python's own notation: `()`, `("a",)`, `("a", "b")`.
fn writeTuple(out: *Out, gpa: std.mem.Allocator, values: []const []const u8) !void {
    try out.append(gpa, '(');
    for (values, 0..) |value, i| try out.print(gpa, "{s}\"{s}\"", .{ if (i == 0) "" else ", ", value });
    if (values.len == 1) try out.append(gpa, ',');
    try out.append(gpa, ')');
}

fn writeVocabulary(out: *Out, gpa: std.mem.Allocator) !void {
    try out.print(gpa, "DIRECTORY = \"{s}\"\nROOM_SENDER = \"{s}\"\n", .{ p.directory_name, p.room_sender });
    try out.print(gpa, "# How long a one-shot client waits for its whole roster.\nSESSION_DEADLINE_MS = {d}\n\n", .{p.session_deadline_ms});
    for (p.verbs) |verb| {
        try p.writeUpper(out, gpa, verb.name, '_');
        try out.print(gpa, " = \"{s}\"\n", .{verb.name});
    }
    try p.writeUpper(out, gpa, p.membership_ended, '_');
    try out.print(gpa, " = \"{s}\"\n\n", .{p.membership_ended});
    try out.appendSlice(gpa, "# The membership verbs and whether the seat answers each.\nMEMBERSHIP_VERBS = (\n");
    for (p.verbsOn(.membership)) |verb| try out.print(gpa, "    (\"{s}\", {s}),\n", .{ verb.name, py(verb.replies) });
    try out.appendSlice(gpa, ")\n\n");
    for (std.enums.values(p.Enumeration)) |enumeration| {
        try out.print(gpa, "{s} = ", .{enumeration.stem()});
        try writeTuple(out, gpa, enumeration.values());
        try out.append(gpa, '\n');
    }
    try out.appendSlice(gpa, "\n# What a presence tail does to the member it names.\n");
    for (std.enums.values(p.Effect)) |effect| {
        try p.writeUpper(out, gpa, @tagName(effect), '_');
        try out.print(gpa, " = \"{s}\"\n", .{@tagName(effect)});
    }
    try out.append(gpa, '\n');
}

fn writeFieldLists(out: *Out, gpa: std.mem.Allocator) !void {
    for (std.enums.values(p.Fields)) |list| {
        try out.print(gpa, "# {s}\n{s} = (\n", .{ list.doc(), list.stem() });
        for (list.fields()) |field| {
            try out.print(gpa, "    (\"{s}\", \"{s}\", {s}, ", .{ field.name, field.ty.wireName(), py(field.nullable) });
            if (field.values) |enumeration| try out.appendSlice(gpa, enumeration.stem()) else try out.appendSlice(gpa, "()");
            try out.appendSlice(gpa, "),\n");
        }
        try out.appendSlice(gpa, ")\n\n");
    }
}

fn writeWatchKinds(out: *Out, gpa: std.mem.Allocator) !void {
    try out.appendSlice(gpa, "# The directory watch notifications: tag -> (the fields after the tag, whether\n# they are one publication record).\nWATCH_KINDS = {\n");
    for (p.watch_kinds) |kind| {
        try out.print(gpa, "    \"{s}\": ({s}, {s}),\n", .{ kind.tag, kind.args.stem(), py(kind.room()) });
    }
    try out.appendSlice(gpa, "}\n\n");
}

fn writeRoomTails(out: *Out, gpa: std.mem.Allocator) !void {
    try out.appendSlice(gpa, "# What rides after a room line's display text: tag -> (the fields after the\n" ++
        "# tag, the type of every further argument or None, the sender (\"room\",\n" ++
        "# \"member\", or \"either\"), the text rule (\"any\", \"empty\", or \"nonempty\"), and\n" ++
        "# the effect on the member named or None).\nROOM_TAILS = {\n");
    for (p.room_tails) |tail| {
        try out.print(gpa, "    \"{s}\": ({s}, ", .{ tail.tag, if (tail.trailing) |trailing| trailing.stem() else "()" });
        if (tail.rest) |ty| try out.print(gpa, "\"{s}\"", .{ty.wireName()}) else try out.appendSlice(gpa, "None");
        try out.print(gpa, ", \"{s}\", \"{s}\", ", .{ @tagName(tail.sender), @tagName(tail.text) });
        if (tail.effect) |effect| try p.writeUpper(out, gpa, @tagName(effect), '_') else try out.appendSlice(gpa, "None");
        try out.appendSlice(gpa, "),\n");
    }
    try out.appendSlice(gpa, "}\n\n");
}
