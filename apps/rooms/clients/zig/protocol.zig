//! How this client reads the Rooms wire: the generated grammar beside this
//! file, and the native checks that hold one wire argument to a declared field.
//!
//! `protocol_gen.zig` is the table every sibling client reads, emitted from
//! `tools/gen/rooms_protocol.zig` by `zig build gen-rooms-protocol`. Nothing
//! here restates a tag, an arity, or a type. This file is only the Zig way of
//! asking that table whether an argument fits, so a new watch kind, notify
//! tail, or record field is one edit in the generator.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;

/// The generated grammar, reached through this file so the client has one path
/// to the table rather than two.
pub const gen = @import("protocol_gen.zig");

/// Where a named field sits in a generated record. Bind the answer to a
/// container-level constant, so the search runs at compile time and a record
/// the generator reorders moves the read with it.
pub fn indexOf(comptime fields: []const gen.Field, comptime name: []const u8) usize {
    for (fields, 0..) |field, at| {
        if (std.mem.eql(u8, field.name, name)) return at;
    }
    @compileError("the generated record has no field named " ++ name);
}

/// The generated tail carrying this tag, resolved the same way.
pub fn tailFor(comptime tag: []const u8) gen.RoomTail {
    for (gen.room_tails) |tail| {
        if (std.mem.eql(u8, tail.tag, tag)) return tail;
    }
    @compileError("the generated table has no room tail tagged " ++ tag);
}

/// Whether one wire argument is a value of the declared type.
pub fn admitsType(ty: gen.Ty, arg: model.Argument) bool {
    return switch (ty) {
        .string => arg == .string,
        .text => arg == .string and arg.string.len > 0,
        .natural => arg == .integer and arg.integer >= 0,
        .boolean => arg == .boolean,
        .reference => arg == .reference,
        .registration_id => arg == .string and registrationId(arg.string),
        .list => arg == .list,
        .any => true,
    };
}

/// Whether one wire argument fits its declared field: a wire null where the
/// field admits one, a member of the enumeration where the field has one, and
/// the declared type.
pub fn admits(field: gen.Field, arg: model.Argument) bool {
    if (arg == .void) return field.nullable;
    if (field.values.len > 0) {
        if (arg != .string) return false;
        var named = false;
        for (field.values) |value| {
            if (std.mem.eql(u8, value, arg.string)) named = true;
        }
        if (!named) return false;
    }
    return admitsType(field.ty, arg);
}

/// Whether a run of wire arguments is exactly the declared fields, one value
/// each.
pub fn fits(fields: []const gen.Field, args: []const model.Argument) bool {
    if (args.len != fields.len) return false;
    for (fields, args) |field, arg| {
        if (!admits(field, arg)) return false;
    }
    return true;
}

/// A directory-issued registration id: the text form the generated constants
/// declare, in either case, with the version and variant characters the sibling
/// clients hold it to.
pub fn registrationId(value: []const u8) bool {
    if (value.len != gen.registration_id_length) return false;
    for (value, 0..) |byte, at| {
        if (std.mem.indexOfScalar(usize, &gen.registration_id_dashes, at) != null) {
            if (byte != '-') return false;
        } else if (at == gen.registration_id_version_at) {
            if (std.mem.indexOfScalar(u8, gen.registration_id_versions, byte) == null) return false;
        } else if (at == gen.registration_id_variant_at) {
            if (std.mem.indexOfScalar(u8, gen.registration_id_variants, std.ascii.toLower(byte)) == null) return false;
        } else if (!std.ascii.isHex(byte)) {
            return false;
        }
    }
    return true;
}

/// One directory publication, in the generated record's order.
pub const RoomInfo = struct {
    name: []const u8,
    count: ?i64,
    id: []const u8,
    kind: []const u8,
    origin: []const u8,
    proof: []const u8,
    offers: ?[]const u8,
};

/// Where each publication field sits, and a compile-time check that the struct
/// above still names the generated record's fields in its order.
const publication = struct {
    const name = indexOf(&gen.publication_fields, "name");
    const count = indexOf(&gen.publication_fields, "count");
    const id = indexOf(&gen.publication_fields, "id");
    const kind = indexOf(&gen.publication_fields, "kind");
    const origin = indexOf(&gen.publication_fields, "origin");
    const proof = indexOf(&gen.publication_fields, "proof");
    const offers = indexOf(&gen.publication_fields, "offers");
};

comptime {
    const member_names = @typeInfo(RoomInfo).@"struct".field_names;
    if (member_names.len != gen.publication_fields.len) {
        @compileError("RoomInfo does not follow the generated publication record");
    }
    for (gen.publication_fields, member_names) |field, member_name| {
        if (!std.mem.eql(u8, field.name, member_name)) {
            @compileError("RoomInfo does not follow the generated publication record");
        }
    }
}

/// The publication a directory row or a room watch kind carries, or null when
/// the arguments are not that record. A wire null is an unknown count and an
/// absent offer, never a malformed row.
pub fn roomInfo(fields: []const model.Argument) ?RoomInfo {
    if (!fits(&gen.publication_fields, fields)) return null;
    return .{
        .name = fields[publication.name].string,
        .count = if (fields[publication.count] == .void) null else fields[publication.count].integer,
        .id = fields[publication.id].string,
        .kind = fields[publication.kind].string,
        .origin = fields[publication.origin].string,
        .proof = fields[publication.proof].string,
        .offers = if (fields[publication.offers] == .void) null else fields[publication.offers].string,
    };
}

/// How a watch notification can be wrong.
pub const WatchError = error{
    MalformedWatchNotification,
    MalformedRoomWatchNotification,
    MalformedMemberWatchNotification,
    MalformedWatchTruncation,
    UnknownWatchEvent,
};

/// Which refusal a malformed notification takes, decided by what the table says
/// its kind carries: a whole room record, a member's registration, or the
/// omission count.
fn malformedWatch(kind: gen.WatchKind) WatchError {
    if (kind.room) return error.MalformedRoomWatchNotification;
    for (kind.args) |field| {
        if (field.ty == .registration_id) return error.MalformedMemberWatchNotification;
    }
    return error.MalformedWatchTruncation;
}

/// Hold a directory watch notification to the generated kind it names. A room
/// kind answers the publication it carries; the member and truncation kinds are
/// valid but carry no room for this small terminal client to print, so they
/// answer null. A malformed or unknown event is refused rather than skipped.
pub fn watchEvent(args: []const model.Argument) WatchError!?RoomInfo {
    if (args.len == 0 or args[0] != .string) return error.MalformedWatchNotification;
    for (gen.watch_kinds) |kind| {
        if (!std.mem.eql(u8, kind.tag, args[0].string)) continue;
        if (!fits(kind.args, args[1..])) return malformedWatch(kind);
        return if (kind.room) roomInfo(args[1..]) else null;
    }
    return error.UnknownWatchEvent;
}

/// Where the rooms and the registrations sit in the watch snapshot.
const snapshot = struct {
    const rooms = indexOf(&gen.watch_snapshot_fields, "rooms");
    const registrations = indexOf(&gen.watch_snapshot_fields, "registrations");
};

/// Whether `watchPublications` answered the baseline a watcher folds its deltas
/// into: the rooms, the registration rows, and the omission count.
pub fn validWatchSnapshot(arg: model.Argument) bool {
    if (arg != .list or !fits(&gen.watch_snapshot_fields, arg.list)) return false;
    for (arg.list[snapshot.rooms].list) |row| {
        if (row != .list or roomInfo(row.list) == null) return false;
    }
    for (arg.list[snapshot.registrations].list) |row| {
        if (row != .list or !fits(&gen.registration_row_fields, row.list)) return false;
    }
    return true;
}

/// Whether a room line's sender, display text, and arguments after the tag are
/// what the generated tail declares.
pub fn tailFits(tail: gen.RoomTail, from: []const u8, text: []const u8, extra: []const model.Argument) bool {
    const by_room = std.mem.eql(u8, from, gen.room_sender);
    switch (tail.sender) {
        .room => if (!by_room) return false,
        .member => if (by_room) return false,
        .either => {},
    }
    switch (tail.text) {
        .empty => if (text.len != 0) return false,
        .nonempty => if (text.len == 0) return false,
        .any => {},
    }
    if (extra.len < tail.trailing.len) return false;
    if (!fits(tail.trailing, extra[0..tail.trailing.len])) return false;
    const rest_ty = tail.rest orelse return extra.len == tail.trailing.len;
    for (extra[tail.trailing.len..]) |arg| {
        if (!admitsType(rest_ty, arg)) return false;
    }
    return true;
}

/// The presence a room line carries after its display text, when the tag names
/// a presence tail and the arguments are that tail's shape. An ordinary chat
/// line carries none, and so does a malformed tail, so the line still draws.
pub fn presenceTail(from: []const u8, text: []const u8, args: []const model.Argument) ?gen.RoomTail {
    if (args.len < 3 or args[2] != .string) return null;
    for (gen.room_tails) |tail| {
        if (!std.mem.eql(u8, tail.tag, args[2].string)) continue;
        if (tail.effect == null or !tailFits(tail, from, text, args[3..])) return null;
        return tail;
    }
    return null;
}
