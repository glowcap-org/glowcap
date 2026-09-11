//! The Zig client's projection of `rooms_protocol.zig`: the same tables as
//! comptime-known arrays, so a reader can look a field's position up at
//! compile time.

const std = @import("std");
const p = @import("../rooms_protocol.zig");

const Out = std.ArrayList(u8);

pub fn generate(gpa: std.mem.Allocator) ![]u8 {
    var out: Out = .empty;
    errdefer out.deinit(gpa);
    try p.writeHeader(&out, gpa, "//!");
    try out.append(gpa, '\n');
    try writeTypes(&out, gpa);
    try writeVocabulary(&out, gpa);
    try writeFieldLists(&out, gpa);
    try writeWatchKinds(&out, gpa);
    try writeRoomTails(&out, gpa);
    try out.appendSlice(gpa, "/// The text form of a registration id: its length, where the dashes sit, and\n" ++
        "/// the version and variant characters admitted (the variant without regard to\n" ++
        "/// case).\n");
    try out.print(gpa, "pub const registration_id_length: usize = {d};\n", .{p.registration_id.length});
    try out.appendSlice(gpa, "pub const registration_id_dashes = [_]usize{ ");
    for (p.registration_id.dashes, 0..) |at, i| try out.print(gpa, "{s}{d}", .{ if (i == 0) "" else ", ", at });
    try out.appendSlice(gpa, " };\n");
    try out.print(gpa, "pub const registration_id_version_at: usize = {d};\n", .{p.registration_id.version_at});
    try out.print(gpa, "pub const registration_id_versions = \"{s}\";\n", .{p.registration_id.versions});
    try out.print(gpa, "pub const registration_id_variant_at: usize = {d};\n", .{p.registration_id.variant_at});
    try out.print(gpa, "pub const registration_id_variants = \"{s}\";\n", .{p.registration_id.variants});
    return out.toOwnedSlice(gpa);
}

fn zg(value: bool) []const u8 {
    return if (value) "true" else "false";
}

fn writeEnum(out: *Out, gpa: std.mem.Allocator, comptime E: type, name: []const u8, doc: []const u8) !void {
    try out.print(gpa, "/// {s}\npub const {s} = enum {{", .{ doc, name });
    for (std.enums.values(E), 0..) |value, i| {
        try out.print(gpa, "{s}{s}", .{ if (i == 0) " " else ", ", @tagName(value) });
    }
    try out.appendSlice(gpa, " };\n\n");
}

fn writeTypes(out: *Out, gpa: std.mem.Allocator) !void {
    try out.appendSlice(gpa, "/// The wire type of one field or trailing argument.\n" ++
        "pub const Ty = enum {\n" ++
        "    /// Any string, empty included.\n    string,\n" ++
        "    /// A nonempty string.\n    text,\n" ++
        "    /// A non-negative integer.\n    natural,\n" ++
        "    boolean,\n" ++
        "    /// A capability reference.\n    reference,\n" ++
        "    /// A directory-issued registration id in the form the `registration_id_*` constants declare.\n    registration_id,\n" ++
        "    /// A list whose rows a sibling table declares.\n    list,\n" ++
        "    /// Any argument at all; a sibling reader owns its shape.\n    any,\n" ++
        "};\n\n" ++
        "/// One positional wire value.\n" ++
        "pub const Field = struct {\n" ++
        "    name: []const u8,\n" ++
        "    ty: Ty,\n" ++
        "    /// Whether a wire null is admitted in place of the value.\n" ++
        "    nullable: bool,\n" ++
        "    /// The strings admitted, when the field is an enumeration.\n" ++
        "    values: []const []const u8,\n" ++
        "};\n\n");
    try writeEnum(out, gpa, p.Effect, "Effect", "What a presence tail does to the member it names.");
    try writeEnum(out, gpa, p.Sender, "Sender", "Who says a line carrying a tail.");
    try writeEnum(out, gpa, p.TextRule, "TextRule", "What the display text of a line carrying a tail may be.");
    try out.appendSlice(gpa, "/// What rides after a room line's display text: `notify(from, text, tag, ...)`.\n" ++
        "pub const RoomTail = struct {\n" ++
        "    tag: []const u8,\n" ++
        "    /// The arguments after the tag.\n" ++
        "    trailing: []const Field,\n" ++
        "    /// The type of every argument after `trailing`, or null when nothing may follow.\n" ++
        "    rest: ?Ty,\n" ++
        "    sender: Sender,\n" ++
        "    text: TextRule,\n" ++
        "    /// Set on a presence tail; null on a tail that says nothing about membership.\n" ++
        "    effect: ?Effect,\n" ++
        "};\n\n" ++
        "/// One directory watch notification: `notify(tag, ...args)`.\n" ++
        "pub const WatchKind = struct {\n" ++
        "    tag: []const u8,\n" ++
        "    args: []const Field,\n" ++
        "    /// Whether `args` is one whole publication record.\n" ++
        "    room: bool,\n" ++
        "};\n\n" ++
        "/// A verb and whether its target answers it.\n" ++
        "pub const Verb = struct {\n" ++
        "    name: []const u8,\n" ++
        "    replies: bool,\n" ++
        "};\n\n");
}

fn writeStrings(out: *Out, gpa: std.mem.Allocator, values: []const []const u8) !void {
    for (values, 0..) |value, i| try out.print(gpa, "{s}\"{s}\"", .{ if (i == 0) " " else ", ", value });
    try out.appendSlice(gpa, " }");
}

fn writeVocabulary(out: *Out, gpa: std.mem.Allocator) !void {
    try out.print(gpa, "pub const directory = \"{s}\";\npub const room_sender = \"{s}\";\n", .{ p.directory_name, p.room_sender });
    try out.print(gpa, "/// How long a one-shot client waits for its whole roster.\npub const session_deadline_ms: u32 = {d};\n\n", .{p.session_deadline_ms});
    for (p.verbs) |verb| {
        try out.appendSlice(gpa, "pub const ");
        try p.writeSnake(out, gpa, verb.name);
        try out.print(gpa, " = \"{s}\";\n", .{verb.name});
    }
    try out.appendSlice(gpa, "pub const ");
    try p.writeSnake(out, gpa, p.membership_ended);
    try out.print(gpa, " = \"{s}\";\n\n", .{p.membership_ended});
    try out.appendSlice(gpa, "/// The membership verbs and whether the seat answers each.\npub const membership_verbs = [_]Verb{\n");
    for (p.verbsOn(.membership)) |verb| {
        try out.print(gpa, "    .{{ .name = \"{s}\", .replies = {s} }},\n", .{ verb.name, zg(verb.replies) });
    }
    try out.appendSlice(gpa, "};\n\n");
    for (std.enums.values(p.Enumeration)) |enumeration| {
        try out.appendSlice(gpa, "pub const ");
        try p.writeSnake(out, gpa, enumeration.stem());
        try out.appendSlice(gpa, " = [_][]const u8{");
        try writeStrings(out, gpa, enumeration.values());
        try out.appendSlice(gpa, ";\n");
    }
    try out.append(gpa, '\n');
}

fn writeFieldLists(out: *Out, gpa: std.mem.Allocator) !void {
    for (std.enums.values(p.Fields)) |list| {
        try out.print(gpa, "/// {s}\npub const ", .{list.doc()});
        try p.writeSnake(out, gpa, list.stem());
        try out.appendSlice(gpa, " = [_]Field{\n");
        for (list.fields()) |field| {
            try out.print(gpa, "    .{{ .name = \"{s}\", .ty = .{s}, .nullable = {s}, .values = ", .{ field.name, @tagName(field.ty), zg(field.nullable) });
            if (field.values) |enumeration| {
                try out.append(gpa, '&');
                try p.writeSnake(out, gpa, enumeration.stem());
            } else {
                try out.appendSlice(gpa, "&.{}");
            }
            try out.appendSlice(gpa, " },\n");
        }
        try out.appendSlice(gpa, "};\n\n");
    }
}

fn writeWatchKinds(out: *Out, gpa: std.mem.Allocator) !void {
    try out.appendSlice(gpa, "/// The directory watch notifications.\npub const watch_kinds = [_]WatchKind{\n");
    for (p.watch_kinds) |kind| {
        try out.print(gpa, "    .{{ .tag = \"{s}\", .args = &", .{kind.tag});
        try p.writeSnake(out, gpa, kind.args.stem());
        try out.print(gpa, ", .room = {s} }},\n", .{zg(kind.room())});
    }
    try out.appendSlice(gpa, "};\n\n");
}

fn writeRoomTails(out: *Out, gpa: std.mem.Allocator) !void {
    try out.appendSlice(gpa, "/// What rides after a room line's display text.\npub const room_tails = [_]RoomTail{\n");
    for (p.room_tails) |tail| {
        try out.print(gpa, "    .{{ .tag = \"{s}\", .trailing = ", .{tail.tag});
        if (tail.trailing) |trailing| {
            try out.append(gpa, '&');
            try p.writeSnake(out, gpa, trailing.stem());
        } else {
            try out.appendSlice(gpa, "&.{}");
        }
        try out.appendSlice(gpa, ", .rest = ");
        if (tail.rest) |ty| try out.print(gpa, ".{s}", .{@tagName(ty)}) else try out.appendSlice(gpa, "null");
        try out.print(gpa, ", .sender = .{s}, .text = .{s}, .effect = ", .{ @tagName(tail.sender), @tagName(tail.text) });
        if (tail.effect) |effect| try out.print(gpa, ".{s}", .{@tagName(effect)}) else try out.appendSlice(gpa, "null");
        try out.appendSlice(gpa, " },\n");
    }
    try out.appendSlice(gpa, "};\n\n");
}
