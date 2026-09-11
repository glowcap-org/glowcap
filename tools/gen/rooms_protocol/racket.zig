//! The Racket client's projection of `rooms_protocol.zig`: verbs as the
//! symbols `session-send` takes, tags as the strings they arrive as, and the
//! tables as transparent structs.

const std = @import("std");
const p = @import("../rooms_protocol.zig");

const Out = std.ArrayList(u8);

pub fn generate(gpa: std.mem.Allocator) ![]u8 {
    var out: Out = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "#lang racket/base\n");
    try p.writeHeader(&out, gpa, ";;");
    try out.appendSlice(gpa, ";;\n;; A field names its wire type as a symbol, one of\n;;");
    for (std.enums.values(p.Ty)) |ty| try out.print(gpa, " '{s}", .{ty.wireName()});
    try out.appendSlice(gpa, ";\n" ++
        ";; `nullable?` says whether a wire null (`(void)` here) is admitted, and\n" ++
        ";; `values` lists the strings admitted when the field is an enumeration.\n" ++
        ";; Verbs are symbols, the way `session-send` takes them; tags are strings, the\n" ++
        ";; way they arrive.\n\n");
    try writeProvide(&out, gpa);
    try out.appendSlice(gpa, "(struct field (name type nullable? values) #:transparent)\n" ++
        ";; A watch notification: the tag, the fields after it, and whether they are one\n" ++
        ";; publication record.\n" ++
        "(struct watch-kind (tag args room?) #:transparent)\n" ++
        ";; What rides after a room line's display text: the tag, the fields after it,\n" ++
        ";; the type of every further argument or #f, the sender ('room 'member 'either),\n" ++
        ";; the text rule ('any 'empty 'nonempty), and the effect on the member named\n" ++
        ";; ('arrive 'depart 'stay) or #f.\n" ++
        "(struct room-tail (tag trailing rest sender text effect) #:transparent)\n\n");
    try writeVocabulary(&out, gpa);
    try writeFieldLists(&out, gpa);
    try writeWatchKinds(&out, gpa);
    try writeRoomTails(&out, gpa);
    try out.appendSlice(gpa, ";; The text form of a registration id, matched without regard to case.\n(define REGISTRATION-ID-RX #px\"(?i:");
    try p.registration_id.writePattern(&out, gpa);
    try out.appendSlice(gpa, ")\")\n");
    return out.toOwnedSlice(gpa);
}

fn rkt(value: bool) []const u8 {
    return if (value) "#t" else "#f";
}

fn writeStrings(out: *Out, gpa: std.mem.Allocator, values: []const []const u8) !void {
    try out.appendSlice(gpa, "'(");
    for (values, 0..) |value, i| try out.print(gpa, "{s}\"{s}\"", .{ if (i == 0) "" else " ", value });
    try out.append(gpa, ')');
}

fn writeProvide(out: *Out, gpa: std.mem.Allocator) !void {
    try out.appendSlice(gpa, "(provide\n  (struct-out field)\n  (struct-out watch-kind)\n  (struct-out room-tail)\n  DIRECTORY\n  ROOM-SENDER\n  SESSION-DEADLINE-MS\n");
    for (p.verbs) |verb| {
        try out.appendSlice(gpa, "  ");
        try p.writeUpper(out, gpa, verb.name, '-');
        try out.append(gpa, '\n');
    }
    try out.appendSlice(gpa, "  ");
    try p.writeUpper(out, gpa, p.membership_ended, '-');
    try out.appendSlice(gpa, "\n  MEMBERSHIP-VERBS\n");
    for (std.enums.values(p.Enumeration)) |enumeration| {
        try out.appendSlice(gpa, "  ");
        try p.writeKebab(out, gpa, enumeration.stem());
        try out.append(gpa, '\n');
    }
    for (std.enums.values(p.Fields)) |list| {
        try out.appendSlice(gpa, "  ");
        try p.writeKebab(out, gpa, list.stem());
        try out.append(gpa, '\n');
    }
    try out.appendSlice(gpa, "  WATCH-KINDS\n  ROOM-TAILS\n  REGISTRATION-ID-RX)\n\n");
}

fn writeVocabulary(out: *Out, gpa: std.mem.Allocator) !void {
    try out.print(gpa, "(define DIRECTORY \"{s}\")\n(define ROOM-SENDER \"{s}\")\n", .{ p.directory_name, p.room_sender });
    try out.print(gpa, ";; How long a one-shot client waits for its whole roster.\n(define SESSION-DEADLINE-MS {d})\n\n", .{p.session_deadline_ms});
    for (p.verbs) |verb| {
        try out.appendSlice(gpa, "(define ");
        try p.writeUpper(out, gpa, verb.name, '-');
        try out.print(gpa, " '{s})\n", .{verb.name});
    }
    try out.appendSlice(gpa, "(define ");
    try p.writeUpper(out, gpa, p.membership_ended, '-');
    try out.print(gpa, " \"{s}\")\n\n", .{p.membership_ended});
    try out.appendSlice(gpa, ";; The membership verbs and whether the seat answers each.\n(define MEMBERSHIP-VERBS\n  (list\n");
    const membership = p.verbsOn(.membership);
    for (membership, 0..) |verb, i| {
        try out.print(gpa, "   (cons '{s} {s}){s}\n", .{ verb.name, rkt(verb.replies), if (i + 1 == membership.len) "))" else "" });
    }
    try out.append(gpa, '\n');
    for (std.enums.values(p.Enumeration)) |enumeration| {
        try out.appendSlice(gpa, "(define ");
        try p.writeKebab(out, gpa, enumeration.stem());
        try out.append(gpa, ' ');
        try writeStrings(out, gpa, enumeration.values());
        try out.appendSlice(gpa, ")\n");
    }
    try out.append(gpa, '\n');
}

fn writeFieldLists(out: *Out, gpa: std.mem.Allocator) !void {
    for (std.enums.values(p.Fields)) |list| {
        try out.print(gpa, ";; {s}\n(define ", .{list.doc()});
        try p.writeKebab(out, gpa, list.stem());
        try out.appendSlice(gpa, "\n  (list\n");
        const fields = list.fields();
        for (fields, 0..) |field, i| {
            try out.print(gpa, "   (field \"{s}\" '{s} {s} ", .{ field.name, field.ty.wireName(), rkt(field.nullable) });
            if (field.values) |enumeration| try p.writeKebab(out, gpa, enumeration.stem()) else try out.appendSlice(gpa, "'()");
            try out.print(gpa, "){s}\n", .{if (i + 1 == fields.len) "))" else ""});
        }
        try out.append(gpa, '\n');
    }
}

fn writeWatchKinds(out: *Out, gpa: std.mem.Allocator) !void {
    try out.appendSlice(gpa, ";; The directory watch notifications.\n(define WATCH-KINDS\n  (list\n");
    for (p.watch_kinds, 0..) |kind, i| {
        try out.print(gpa, "   (watch-kind \"{s}\" ", .{kind.tag});
        try p.writeKebab(out, gpa, kind.args.stem());
        try out.print(gpa, " {s}){s}\n", .{ rkt(kind.room()), if (i + 1 == p.watch_kinds.len) "))" else "" });
    }
    try out.append(gpa, '\n');
}

fn writeRoomTails(out: *Out, gpa: std.mem.Allocator) !void {
    try out.appendSlice(gpa, ";; What rides after a room line's display text.\n(define ROOM-TAILS\n  (list\n");
    for (p.room_tails, 0..) |tail, i| {
        try out.print(gpa, "   (room-tail \"{s}\" ", .{tail.tag});
        if (tail.trailing) |trailing| try p.writeKebab(out, gpa, trailing.stem()) else try out.appendSlice(gpa, "'()");
        if (tail.rest) |ty| try out.print(gpa, " '{s}", .{ty.wireName()}) else try out.appendSlice(gpa, " #f");
        try out.print(gpa, " '{s} '{s}", .{ @tagName(tail.sender), @tagName(tail.text) });
        if (tail.effect) |effect| try out.print(gpa, " '{s}", .{@tagName(effect)}) else try out.appendSlice(gpa, " #f");
        try out.print(gpa, "){s}\n", .{if (i + 1 == p.room_tails.len) "))" else ""});
    }
    try out.append(gpa, '\n');
}
