//! The Deno client's projection of `rooms_protocol.zig`: the same tables as
//! readonly TypeScript, held to the server's own readers by
//! `apps/rooms/test/protocol_gen_test.ts`.

const std = @import("std");
const p = @import("../rooms_protocol.zig");

const Out = std.ArrayList(u8);

pub fn generate(gpa: std.mem.Allocator) ![]u8 {
    var out: Out = .empty;
    errdefer out.deinit(gpa);
    try p.writeHeader(&out, gpa, "//");
    try out.appendSlice(gpa, "// apps/rooms/test/protocol_gen_test.ts holds this module to the server's own\n// readers.\n\n");
    try writeTypes(&out, gpa);
    try writeVocabulary(&out, gpa);
    try writeFieldLists(&out, gpa);
    try writeWatchKinds(&out, gpa);
    try writeRoomTails(&out, gpa);
    // The pattern is wider than `deno fmt`'s line, so it sits on its own
    // continuation line the way the formatter would put it.
    try out.appendSlice(gpa, "/** The text form of a registration id, matched without regard to case. */\nexport const REGISTRATION_ID_PATTERN =\n\t/");
    try p.registration_id.writePattern(&out, gpa);
    try out.appendSlice(gpa, "/i;\n");
    return out.toOwnedSlice(gpa);
}

fn js(value: bool) []const u8 {
    return if (value) "true" else "false";
}

/// The wire name of every member of `E`, in declaration order. A container
/// constant, one per enum, so the slice outlives this call.
fn tagNames(comptime E: type) []const []const u8 {
    return &struct {
        const names = blk: {
            const values = std.enums.values(E);
            var out: [values.len][]const u8 = undefined;
            for (values, 0..) |value, i| out[i] = if (E == p.Ty) value.wireName() else @tagName(value);
            break :blk out;
        };
    }.names;
}

fn writeUnion(out: *Out, gpa: std.mem.Allocator, names: []const []const u8, name: []const u8, doc: []const u8) !void {
    try out.print(gpa, "/** {s} */\nexport type {s} =", .{ doc, name });
    for (names, 0..) |value, i| {
        try out.print(gpa, "{s} \"{s}\"", .{ if (i == 0) "" else " |", value });
    }
    try out.appendSlice(gpa, ";\n");
}

fn writeStrings(out: *Out, gpa: std.mem.Allocator, values: []const []const u8) !void {
    for (values, 0..) |value, i| try out.print(gpa, "{s}\"{s}\"", .{ if (i == 0) "" else ", ", value });
}

fn writeTypes(out: *Out, gpa: std.mem.Allocator) !void {
    try writeUnion(out, gpa, tagNames(p.Ty), "WireType", "The wire type of one field or trailing argument.");
    try out.appendSlice(gpa, "\n/** One positional wire value. */\n" ++
        "export interface Field {\n" ++
        "\treadonly name: string;\n" ++
        "\treadonly type: WireType;\n" ++
        "\t/** Whether a wire null is admitted in place of the value. */\n" ++
        "\treadonly nullable: boolean;\n" ++
        "\t/** The strings admitted, when the field is an enumeration. */\n" ++
        "\treadonly values: readonly string[];\n" ++
        "}\n\n");
    try writeUnion(out, gpa, tagNames(p.Effect), "Effect", "What a presence tail does to the member it names.");
    try writeUnion(out, gpa, tagNames(p.Sender), "Sender", "Who says a line carrying a tail.");
    try writeUnion(out, gpa, tagNames(p.TextRule), "TextRule", "What the display text of a line carrying a tail may be.");
    try out.appendSlice(gpa, "\n/** What rides after a room line's display text: `notify(from, text, tag, ...)`. */\n" ++
        "export interface RoomTail {\n" ++
        "\treadonly tag: string;\n" ++
        "\t/** The arguments after the tag. */\n" ++
        "\treadonly trailing: readonly Field[];\n" ++
        "\t/** The type of every argument after `trailing`, or null when nothing may follow. */\n" ++
        "\treadonly rest: WireType | null;\n" ++
        "\treadonly sender: Sender;\n" ++
        "\treadonly text: TextRule;\n" ++
        "\t/** Set on a presence tail; null on a tail that says nothing about membership. */\n" ++
        "\treadonly effect: Effect | null;\n" ++
        "}\n\n" ++
        "/** One directory watch notification: `notify(tag, ...args)`. */\n" ++
        "export interface WatchKind {\n" ++
        "\treadonly tag: string;\n" ++
        "\treadonly args: readonly Field[];\n" ++
        "\t/** Whether `args` is one whole publication record. */\n" ++
        "\treadonly room: boolean;\n" ++
        "}\n\n" ++
        "/** A verb and whether its target answers it. */\n" ++
        "export interface Verb {\n" ++
        "\treadonly name: string;\n" ++
        "\treadonly replies: boolean;\n" ++
        "}\n\n");
}

fn writeVocabulary(out: *Out, gpa: std.mem.Allocator) !void {
    try out.print(gpa, "export const DIRECTORY = \"{s}\";\n", .{p.directory_name});
    try out.print(gpa, "export const ROOM_SENDER = \"{s}\";\n", .{p.room_sender});
    try out.appendSlice(gpa, "/** How long a one-shot client waits for its whole roster. */\n");
    try out.print(gpa, "export const SESSION_DEADLINE_MS = {d};\n\n", .{p.session_deadline_ms});
    for (p.verbs) |verb| {
        try out.appendSlice(gpa, "export const ");
        try p.writeUpper(out, gpa, verb.name, '_');
        try out.print(gpa, " = \"{s}\";\n", .{verb.name});
    }
    try out.appendSlice(gpa, "export const ");
    try p.writeUpper(out, gpa, p.membership_ended, '_');
    try out.print(gpa, " = \"{s}\";\n\n", .{p.membership_ended});
    try out.appendSlice(gpa, "/** The membership verbs and whether the seat answers each. */\nexport const MEMBERSHIP_VERBS: readonly Verb[] = [\n");
    for (p.verbsOn(.membership)) |verb| {
        try out.print(gpa, "\t{{ name: \"{s}\", replies: {s} }},\n", .{ verb.name, js(verb.replies) });
    }
    try out.appendSlice(gpa, "];\n\n");
    for (std.enums.values(p.Enumeration)) |enumeration| {
        try out.print(gpa, "export const {s}: readonly string[] = [", .{enumeration.stem()});
        try writeStrings(out, gpa, enumeration.values());
        try out.appendSlice(gpa, "];\n");
    }
    try out.append(gpa, '\n');
}

fn writeFieldLists(out: *Out, gpa: std.mem.Allocator) !void {
    for (std.enums.values(p.Fields)) |list| {
        try out.print(gpa, "/** {s} */\nexport const {s}: readonly Field[] = [\n", .{ list.doc(), list.stem() });
        for (list.fields()) |field| {
            try out.print(gpa, "\t{{ name: \"{s}\", type: \"{s}\", nullable: {s}, values: {s} }},\n", .{
                field.name,
                field.ty.wireName(),
                js(field.nullable),
                if (field.values) |enumeration| enumeration.stem() else "[]",
            });
        }
        try out.appendSlice(gpa, "];\n\n");
    }
}

fn writeWatchKinds(out: *Out, gpa: std.mem.Allocator) !void {
    try out.appendSlice(gpa, "/** The directory watch notifications. */\nexport const WATCH_KINDS: readonly WatchKind[] = [\n");
    for (p.watch_kinds) |kind| {
        try out.print(gpa, "\t{{ tag: \"{s}\", args: {s}, room: {s} }},\n", .{ kind.tag, kind.args.stem(), js(kind.room()) });
    }
    try out.appendSlice(gpa, "];\n\n");
}

fn writeRoomTails(out: *Out, gpa: std.mem.Allocator) !void {
    try out.appendSlice(gpa, "/** What rides after a room line's display text. */\nexport const ROOM_TAILS: readonly RoomTail[] = [\n");
    for (p.room_tails) |tail| {
        try out.print(gpa, "\t{{\n\t\ttag: \"{s}\",\n\t\ttrailing: {s},\n\t\trest: ", .{
            tail.tag,
            if (tail.trailing) |trailing| trailing.stem() else "[]",
        });
        if (tail.rest) |ty| try out.print(gpa, "\"{s}\"", .{ty.wireName()}) else try out.appendSlice(gpa, "null");
        try out.print(gpa, ",\n\t\tsender: \"{s}\",\n\t\ttext: \"{s}\",\n\t\teffect: ", .{ @tagName(tail.sender), @tagName(tail.text) });
        if (tail.effect) |effect| try out.print(gpa, "\"{s}\"", .{@tagName(effect)}) else try out.appendSlice(gpa, "null");
        try out.appendSlice(gpa, ",\n\t},\n");
    }
    try out.appendSlice(gpa, "];\n\n");
}
