//! The Rust client's projection of `rooms_protocol.zig`: the same tables as
//! `&'static` constants over plain structs and enums, laid out the way
//! `rustfmt` lays out a struct literal so the committed file is fmt-clean.

const std = @import("std");
const p = @import("../rooms_protocol.zig");

const Out = std.ArrayList(u8);

pub fn generate(gpa: std.mem.Allocator) ![]u8 {
    var out: Out = .empty;
    errdefer out.deinit(gpa);
    try p.writeHeader(&out, gpa, "//!");
    try out.appendSlice(gpa, "\n#![allow(dead_code)]\n\n");
    try writeTypes(&out, gpa);
    try writeVocabulary(&out, gpa);
    try writeFieldLists(&out, gpa);
    try writeWatchKinds(&out, gpa);
    try writeRoomTails(&out, gpa);
    try out.appendSlice(gpa, "/// The text form of a registration id: its length, where the dashes sit, and\n" ++
        "/// the version and variant characters admitted (the variant without regard to\n" ++
        "/// case).\n");
    try out.print(gpa, "pub const REGISTRATION_ID_LENGTH: usize = {d};\n", .{p.registration_id.length});
    try out.appendSlice(gpa, "pub const REGISTRATION_ID_DASHES: &[usize] = &[");
    for (p.registration_id.dashes, 0..) |at, i| try out.print(gpa, "{s}{d}", .{ if (i == 0) "" else ", ", at });
    try out.appendSlice(gpa, "];\n");
    try out.print(gpa, "pub const REGISTRATION_ID_VERSION_AT: usize = {d};\n", .{p.registration_id.version_at});
    try out.print(gpa, "pub const REGISTRATION_ID_VERSIONS: &str = \"{s}\";\n", .{p.registration_id.versions});
    try out.print(gpa, "pub const REGISTRATION_ID_VARIANT_AT: usize = {d};\n", .{p.registration_id.variant_at});
    try out.print(gpa, "pub const REGISTRATION_ID_VARIANTS: &str = \"{s}\";\n", .{p.registration_id.variants});
    return out.toOwnedSlice(gpa);
}

fn rs(value: bool) []const u8 {
    return if (value) "true" else "false";
}

/// `registration_id` as `RegistrationId`: the variant name of a Zig tag.
fn writePascal(out: *Out, gpa: std.mem.Allocator, tag: []const u8) !void {
    var upper_next = true;
    for (tag) |ch| {
        if (ch == '_') {
            upper_next = true;
            continue;
        }
        try out.append(gpa, if (upper_next) std.ascii.toUpper(ch) else ch);
        upper_next = false;
    }
}

fn writeVariant(out: *Out, gpa: std.mem.Allocator, enum_name: []const u8, tag: []const u8) !void {
    try out.print(gpa, "{s}::", .{enum_name});
    try writePascal(out, gpa, tag);
}

fn writeEnum(out: *Out, gpa: std.mem.Allocator, comptime E: type, name: []const u8, doc: []const u8) !void {
    try out.print(gpa, "/// {s}\n#[derive(Clone, Copy, Debug, PartialEq, Eq)]\npub enum {s} {{\n", .{ doc, name });
    for (std.enums.values(E)) |value| {
        try out.append(gpa, '\t');
        try writePascal(out, gpa, @tagName(value));
        try out.appendSlice(gpa, ",\n");
    }
    try out.appendSlice(gpa, "}\n\n");
}

fn writeTypes(out: *Out, gpa: std.mem.Allocator) !void {
    try out.appendSlice(gpa, "/// The wire type of one field or trailing argument.\n" ++
        "#[derive(Clone, Copy, Debug, PartialEq, Eq)]\n" ++
        "pub enum Ty {\n" ++
        "\t/// Any string, empty included.\n\tString,\n" ++
        "\t/// A nonempty string.\n\tText,\n" ++
        "\t/// A non-negative integer.\n\tNatural,\n" ++
        "\tBoolean,\n" ++
        "\t/// A capability reference.\n\tReference,\n" ++
        "\t/// A directory-issued registration id in the form the `REGISTRATION_ID_*` constants declare.\n\tRegistrationId,\n" ++
        "\t/// A list whose rows a sibling table declares.\n\tList,\n" ++
        "\t/// Any argument at all; a sibling reader owns its shape.\n\tAny,\n" ++
        "}\n\n" ++
        "/// One positional wire value.\n" ++
        "pub struct Field {\n" ++
        "\tpub name: &'static str,\n" ++
        "\tpub ty: Ty,\n" ++
        "\t/// Whether a wire null is admitted in place of the value.\n" ++
        "\tpub nullable: bool,\n" ++
        "\t/// The strings admitted, when the field is an enumeration.\n" ++
        "\tpub values: &'static [&'static str],\n" ++
        "}\n\n");
    try writeEnum(out, gpa, p.Effect, "Effect", "What a presence tail does to the member it names.");
    try writeEnum(out, gpa, p.Sender, "Sender", "Who says a line carrying a tail.");
    try writeEnum(out, gpa, p.TextRule, "TextRule", "What the display text of a line carrying a tail may be.");
    try out.appendSlice(gpa, "/// What rides after a room line's display text: `notify(from, text, tag, ...)`.\n" ++
        "pub struct RoomTail {\n" ++
        "\tpub tag: &'static str,\n" ++
        "\t/// The arguments after the tag.\n" ++
        "\tpub trailing: &'static [Field],\n" ++
        "\t/// The type of every argument after `trailing`, or `None` when nothing may follow.\n" ++
        "\tpub rest: Option<Ty>,\n" ++
        "\tpub sender: Sender,\n" ++
        "\tpub text: TextRule,\n" ++
        "\t/// Set on a presence tail; `None` on a tail that says nothing about membership.\n" ++
        "\tpub effect: Option<Effect>,\n" ++
        "}\n\n" ++
        "/// One directory watch notification: `notify(tag, ...args)`.\n" ++
        "pub struct WatchKind {\n" ++
        "\tpub tag: &'static str,\n" ++
        "\tpub args: &'static [Field],\n" ++
        "\t/// Whether `args` is one whole publication record.\n" ++
        "\tpub room: bool,\n" ++
        "}\n\n" ++
        "/// A verb and whether its target answers it.\n" ++
        "pub struct Verb {\n" ++
        "\tpub name: &'static str,\n" ++
        "\tpub replies: bool,\n" ++
        "}\n\n");
}

fn writeStrings(out: *Out, gpa: std.mem.Allocator, values: []const []const u8) !void {
    try out.appendSlice(gpa, "&[");
    for (values, 0..) |value, i| try out.print(gpa, "{s}\"{s}\"", .{ if (i == 0) "" else ", ", value });
    try out.append(gpa, ']');
}

fn writeVocabulary(out: *Out, gpa: std.mem.Allocator) !void {
    try out.print(gpa, "pub const DIRECTORY: &str = \"{s}\";\npub const ROOM_SENDER: &str = \"{s}\";\n", .{ p.directory_name, p.room_sender });
    try out.print(gpa, "/// How long a one-shot client waits for its whole roster.\npub const SESSION_DEADLINE_MS: u64 = {d};\n\n", .{p.session_deadline_ms});
    for (p.verbs) |verb| {
        try out.appendSlice(gpa, "pub const ");
        try p.writeUpper(out, gpa, verb.name, '_');
        try out.print(gpa, ": &str = \"{s}\";\n", .{verb.name});
    }
    try out.appendSlice(gpa, "pub const ");
    try p.writeUpper(out, gpa, p.membership_ended, '_');
    try out.print(gpa, ": &str = \"{s}\";\n\n", .{p.membership_ended});
    try out.appendSlice(gpa, "/// The membership verbs and whether the seat answers each.\npub const MEMBERSHIP_VERBS: &[Verb] = &[\n");
    for (p.verbsOn(.membership)) |verb| {
        try out.print(gpa, "\tVerb {{\n\t\tname: \"{s}\",\n\t\treplies: {s},\n\t}},\n", .{ verb.name, rs(verb.replies) });
    }
    try out.appendSlice(gpa, "];\n\n");
    for (std.enums.values(p.Enumeration)) |enumeration| {
        try out.print(gpa, "pub const {s}: &[&str] = ", .{enumeration.stem()});
        try writeStrings(out, gpa, enumeration.values());
        try out.appendSlice(gpa, ";\n");
    }
    try out.append(gpa, '\n');
}

/// The body of one `Field` literal, each member on its own line under
/// `indent`, the vertical layout `rustfmt` gives a literal wider than its
/// struct-literal width.
fn writeFieldBody(out: *Out, gpa: std.mem.Allocator, field: p.Field, indent: []const u8) !void {
    try out.print(gpa, "{s}name: \"{s}\",\n{s}ty: ", .{ indent, field.name, indent });
    try writeVariant(out, gpa, "Ty", @tagName(field.ty));
    try out.print(gpa, ",\n{s}nullable: {s},\n{s}values: {s},\n", .{
        indent,
        rs(field.nullable),
        indent,
        if (field.values) |enumeration| enumeration.stem() else "&[]",
    });
}

fn writeFieldLists(out: *Out, gpa: std.mem.Allocator) !void {
    for (std.enums.values(p.Fields)) |list| {
        const fields = list.fields();
        try out.print(gpa, "/// {s}\npub const {s}: &[Field] = &[", .{ list.doc(), list.stem() });
        // `rustfmt` lets a sole element open on the array's own line and
        // indents its body once; two or more each sit on their own line.
        if (fields.len == 1) {
            try out.appendSlice(gpa, "Field {\n");
            try writeFieldBody(out, gpa, fields[0], "\t");
            try out.appendSlice(gpa, "}];\n\n");
            continue;
        }
        try out.append(gpa, '\n');
        for (fields) |field| {
            try out.appendSlice(gpa, "\tField {\n");
            try writeFieldBody(out, gpa, field, "\t\t");
            try out.appendSlice(gpa, "\t},\n");
        }
        try out.appendSlice(gpa, "];\n\n");
    }
}

fn writeWatchKinds(out: *Out, gpa: std.mem.Allocator) !void {
    try out.appendSlice(gpa, "/// The directory watch notifications.\npub const WATCH_KINDS: &[WatchKind] = &[\n");
    for (p.watch_kinds) |kind| {
        try out.print(gpa, "\tWatchKind {{\n\t\ttag: \"{s}\",\n\t\targs: {s},\n\t\troom: {s},\n\t}},\n", .{ kind.tag, kind.args.stem(), rs(kind.room()) });
    }
    try out.appendSlice(gpa, "];\n\n");
}

fn writeRoomTails(out: *Out, gpa: std.mem.Allocator) !void {
    try out.appendSlice(gpa, "/// What rides after a room line's display text.\npub const ROOM_TAILS: &[RoomTail] = &[\n");
    for (p.room_tails) |tail| {
        try out.print(gpa, "\tRoomTail {{\n\t\ttag: \"{s}\",\n\t\ttrailing: {s},\n\t\trest: ", .{
            tail.tag,
            if (tail.trailing) |trailing| trailing.stem() else "&[]",
        });
        if (tail.rest) |ty| {
            try out.appendSlice(gpa, "Some(");
            try writeVariant(out, gpa, "Ty", @tagName(ty));
            try out.append(gpa, ')');
        } else {
            try out.appendSlice(gpa, "None");
        }
        try out.appendSlice(gpa, ",\n\t\tsender: ");
        try writeVariant(out, gpa, "Sender", @tagName(tail.sender));
        try out.appendSlice(gpa, ",\n\t\ttext: ");
        try writeVariant(out, gpa, "TextRule", @tagName(tail.text));
        try out.appendSlice(gpa, ",\n\t\teffect: ");
        if (tail.effect) |effect| {
            try out.appendSlice(gpa, "Some(");
            try writeVariant(out, gpa, "Effect", @tagName(effect));
            try out.append(gpa, ')');
        } else {
            try out.appendSlice(gpa, "None");
        }
        try out.appendSlice(gpa, ",\n\t},\n");
    }
    try out.appendSlice(gpa, "];\n\n");
}
