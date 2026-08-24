//! Borrowed and owned Syrup peer-locator and hint projection.
//!
//! Lazy hint backings borrow one validated wire span. Materialization is the
//! only allocating path and is named explicitly by the owned APIs.

const std = @import("std");

const model = @import("model");
const codec_order = @import("codec_order");

const shared = @import("../shared.zig");
const syntax = @import("syntax.zig");

const Error = shared.Error;

/// Borrowed peer locator: empty hint spellings and lazy non-empty dicts land in
/// `BorrowedHints` (one arm). `acceptable_location_raw` remains the signing
/// domain for start-session.
pub fn readPeerLocatorView(bytes: []const u8, cursor: *usize, limit: usize) Error!model.view.PeerLocator {
    try syntax.readByte(bytes, cursor, '<');
    const tag = try syntax.readSymbolLimited(bytes, cursor, limit);
    if (!std.mem.eql(u8, tag, "ocapn-peer")) {
        return Error.MalformedFrame;
    }
    const transport = try syntax.readSymbolLimited(bytes, cursor, limit);
    const designator = try syntax.readStringLimited(bytes, cursor, limit);
    const hints = try readHintsView(bytes, cursor, limit);
    try syntax.readByte(bytes, cursor, '>');
    return .{
        .transport = transport,
        .designator = designator,
        .hints = hints,
    };
}

/// Borrow one complete signed locator record. The caller keeps `bytes` alive
/// for the returned view and owns no cleanup.
pub fn readLocatorView(bytes: []const u8, cursor: *usize) Error!model.view.PeerLocator {
    return readPeerLocatorView(bytes, cursor, syntax.no_limit);
}

/// Borrowed find over the lazy dict span: walk `{name value …}` in place and
/// return the named entry's value borrowing the frame without allocating. An
/// exotic value under another name is skipped exactly as materialize skips it;
/// an exotic value under the *searched* name is malformed, because reserved
/// profile hints carry signed handshake authority.
fn syrupFindHint(hl: model.view.HintList, name: []const u8) model.view.Error!?model.HintValue {
    const bytes = hl.bytes;
    var cursor: usize = 1; // past the '{' of the balanced span readHintsView kept
    while (cursor < bytes.len and bytes[cursor] != '}') {
        const step = nextSyrupHintStep(bytes, &cursor, syntax.no_limit) catch return error.MalformedView;
        switch (step) {
            .known => |entry| if (std.mem.eql(u8, entry.name, name)) return entry.value,
            .skipped => |skipped| if (std.mem.eql(u8, skipped.name, name)) return error.MalformedView,
        }
    }
    return null;
}

fn syrupValidateHintShape(
    hl: model.view.HintList,
    wire_form: model.Hints.WireForm,
) model.view.ProjectError!void {
    if (wire_form == .boolean_false) return error.MalformedView;
    const bytes = hl.bytes;
    var cursor: usize = 1; // past the '{' of the balanced span readHintsView kept
    var previous_key: ?[]const u8 = null;
    var names: HintNameSet = .{};
    while (cursor < bytes.len and bytes[cursor] != '}') {
        const key = readSyrupHintKeyLimited(bytes, &cursor, syntax.no_limit) catch return error.MalformedView;
        if (!names.insert(key.name)) return error.MalformedView;
        if (previous_key) |previous| {
            if (!codec_order.byteSliceBefore(previous, key.encoded)) return error.MalformedView;
        }
        previous_key = key.encoded;
        syntax.skipSyrupValueLimited(bytes, &cursor, syntax.no_limit) catch return error.MalformedView;
    }
}

fn syrupMaterializeHintList(
    allocator: std.mem.Allocator,
    hl: model.view.HintList,
    wire_form: model.Hints.WireForm,
) model.view.Error!model.Hints {
    _ = wire_form;
    var cursor: usize = 0;
    const hints = readHintsOwned(allocator, hl.bytes, &cursor) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedView,
    };
    return hints;
}

const syrup_hint_list_vtable = model.view.HintList.VTable{
    .materialize = syrupMaterializeHintList,
    .validate_shape = syrupValidateHintShape,
    .find = syrupFindHint,
};

/// One hints-dict entry: a Cap'n Proto–expressible value, or an exotic Syrup
/// shape that was skipped (hints are advisory).
const SyrupHintStep = union(enum) {
    known: model.HintEntry,
    skipped: struct { name: []const u8 },
};

/// Shared lazy walk: read a name, then keep a known HintValueKind or skip an
/// exotic Syrup value. Classification happens before parsing so malformed
/// known values remain malformed instead of being reinterpreted as advisory.
fn nextSyrupHintStep(bytes: []const u8, cursor: *usize, limit: usize) Error!SyrupHintStep {
    const key = try readSyrupHintKeyLimited(bytes, cursor, limit);
    if (try isKnownHintValue(bytes, cursor.*)) {
        const value = try readHintValueBorrowedLimited(bytes, cursor, limit);
        return .{ .known = .{ .name = key.name, .value = value } };
    }
    try syntax.skipSyrupValueLimited(bytes, cursor, limit);
    return .{ .skipped = .{ .name = key.name } };
}

const SyrupHintKey = struct {
    name: []const u8,
    encoded: []const u8,
};

const HintNameSet = struct {
    items: [model.max_locator_hint_count][]const u8 = undefined,
    len: usize = 0,

    fn insert(self: *HintNameSet, name: []const u8) bool {
        model.validateHintName(name) catch return false;
        if (self.len == self.items.len) return false;
        for (self.items[0..self.len]) |seen| {
            if (std.mem.eql(u8, seen, name)) return false;
        }
        self.items[self.len] = name;
        self.len += 1;
        return true;
    }
};

fn readSyrupHintKeyLimited(bytes: []const u8, cursor: *usize, limit: usize) Error!SyrupHintKey {
    const start = cursor.*;
    const name = try syntax.readStringLimited(bytes, cursor, limit);
    return .{ .name = name, .encoded = bytes[start..cursor.*] };
}

fn readHintsView(bytes: []const u8, cursor: *usize, limit: usize) Error!model.view.BorrowedHints {
    if (cursor.* >= bytes.len) return Error.Incomplete;
    if (bytes[cursor.*] == 'f') {
        cursor.* += 1;
        return .{ .empty = .boolean_false };
    }
    if (bytes[cursor.*] == '{') {
        if (cursor.* + 2 > bytes.len) return Error.Incomplete;
        if (bytes[cursor.* + 1] == '}') {
            cursor.* += 2;
            return .{ .empty = .map };
        }
        // Validate width and canonical key order now, while the frame limit is
        // available. Strict order makes duplicate detection linear and gives a
        // signed locator one stable spelling across codec forwarding.
        const start = cursor.*;
        try syntax.readByte(bytes, cursor, '{');
        var previous_key: ?[]const u8 = null;
        var names: HintNameSet = .{};
        while (cursor.* < bytes.len and bytes[cursor.*] != '}') {
            const key = try readSyrupHintKeyLimited(bytes, cursor, limit);
            if (!names.insert(key.name)) return Error.MalformedFrame;
            if (previous_key) |previous| {
                if (!codec_order.byteSliceBefore(previous, key.encoded)) return Error.MalformedFrame;
            }
            previous_key = key.encoded;
            if (try isKnownHintValue(bytes, cursor.*)) {
                _ = try readHintValueBorrowedLimited(bytes, cursor, limit);
            } else {
                try syntax.skipSyrupValueLimited(bytes, cursor, limit);
            }
        }
        try syntax.readByte(bytes, cursor, '}');
        const span = bytes[start..cursor.*];
        return .{
            .lazy = .{
                .wire_form = .map,
                .list = .{
                    .bytes = span,
                    .vtable = &syrup_hint_list_vtable,
                },
            },
        };
    }
    return Error.MalformedFrame;
}

/// Parse hints with allocation; entries are heap-owned. Keys and values are
/// duped so the result outlives the frame. Free with `model.freeHints`.
/// Allocation failure propagates as `OutOfMemory`, never as a frame error:
/// running out of heap is not evidence the partner sent hostile bytes.
fn readHintsOwned(allocator: std.mem.Allocator, bytes: []const u8, cursor: *usize) shared.WalkError!model.Hints {
    if (cursor.* >= bytes.len) return Error.Incomplete;
    if (bytes[cursor.*] == 'f') {
        cursor.* += 1;
        return model.Hints.emptyFalse();
    }
    if (bytes[cursor.*] == '{') {
        if (cursor.* + 2 > bytes.len) return Error.Incomplete;
        if (bytes[cursor.* + 1] == '}') {
            cursor.* += 2;
            return model.Hints.emptyMap();
        }
        cursor.* += 1;
        var entries: std.ArrayList(model.HintEntry) = .empty;
        var previous_key: ?[]const u8 = null;
        var names: HintNameSet = .{};
        errdefer {
            for (entries.items) |entry| model.freeHintEntry(allocator, entry);
            entries.deinit(allocator);
        }
        while (cursor.* < bytes.len and bytes[cursor.*] != '}') {
            const key = try readSyrupHintKeyLimited(bytes, cursor, syntax.no_limit);
            if (!names.insert(key.name)) return Error.MalformedFrame;
            if (previous_key) |previous| {
                if (!codec_order.byteSliceBefore(previous, key.encoded)) return Error.MalformedFrame;
            }
            previous_key = key.encoded;
            if (try isKnownHintValue(bytes, cursor.*)) {
                const value = try readHintValueBorrowedLimited(bytes, cursor, syntax.no_limit);
                const name = try allocator.dupe(u8, key.name);
                errdefer allocator.free(name);
                const cloned = try model.cloneHintValue(allocator, value);
                errdefer model.freeHintValue(allocator, cloned);
                try entries.append(allocator, .{ .name = name, .value = cloned });
            } else {
                try syntax.skipSyrupValueLimited(bytes, cursor, syntax.no_limit);
                if (model.transport.isProfileHintName(key.name)) return Error.MalformedFrame;
            }
        }
        try syntax.readByte(bytes, cursor, '}');
        return .{
            .entries = try entries.toOwnedSlice(allocator),
            .wire_form = .map,
        };
    }
    return Error.MalformedFrame;
}

/// Allocates hint entries. Free the result's hints with `model.freeHints`.
/// Used for sturdyref arguments where the actor needs the hints (e.g. sturdyref
/// enlivener extracting host/port).
pub fn readLocatorOwned(allocator: std.mem.Allocator, bytes: []const u8, cursor: *usize) shared.WalkError!model.PeerLocator {
    try syntax.readByte(bytes, cursor, '<');
    const tag = try syntax.readSymbol(bytes, cursor);
    if (!std.mem.eql(u8, tag, "ocapn-peer")) return Error.MalformedFrame;
    const transport = try syntax.readSymbol(bytes, cursor);
    const designator = try syntax.readString(bytes, cursor);
    const hints = try readHintsOwned(allocator, bytes, cursor);
    errdefer model.freeHints(allocator, hints);
    try syntax.readByte(bytes, cursor, '>');
    model.validatePeerLocator(.{
        .transport = transport,
        .designator = designator,
        .hints = hints,
    }) catch return Error.MalformedFrame;
    const t = try allocator.dupe(u8, transport);
    errdefer allocator.free(t);
    const d = try allocator.dupe(u8, designator);
    return .{ .transport = t, .designator = d, .hints = hints };
}

fn isKnownHintValue(bytes: []const u8, cursor: usize) Error!bool {
    if (cursor >= bytes.len) return Error.Incomplete;
    return switch (bytes[cursor]) {
        't', 'f' => true,
        '0'...'9' => blk: {
            const marker_index = cursor + syntax.countDigits(bytes[cursor..]);
            if (marker_index >= bytes.len) return Error.Incomplete;
            break :blk switch (bytes[marker_index]) {
                '"', ':', '+', '-' => true,
                else => false,
            };
        },
        else => false,
    };
}

fn readHintValueBorrowedLimited(bytes: []const u8, cursor: *usize, limit: usize) Error!model.HintValue {
    if (cursor.* >= bytes.len) return Error.Incomplete;
    return switch (bytes[cursor.*]) {
        '0'...'9' => blk: {
            const marker_index = cursor.* + syntax.countDigits(bytes[cursor.*..]);
            if (marker_index >= bytes.len) return Error.Incomplete;
            break :blk switch (bytes[marker_index]) {
                '"' => .{ .string = try syntax.readStringLimited(bytes, cursor, limit) },
                ':' => .{ .bytes = try syntax.readBytesLimited(bytes, cursor, limit) },
                '+', '-' => .{ .integer = try syntax.readInteger(bytes, cursor) },
                else => Error.MalformedFrame,
            };
        },
        't', 'f' => .{ .boolean = try syntax.readBool(bytes, cursor) },
        else => Error.MalformedFrame,
    };
}
