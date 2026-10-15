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
pub fn readPeerLocatorView(bytes: []const u8, cursor: *usize) Error!model.view.PeerLocator {
    try syntax.readByte(bytes, cursor, '<');
    const tag = try syntax.readLabel(bytes, cursor);
    if (!std.mem.eql(u8, tag, "ocapn-peer")) {
        return Error.MalformedFrame;
    }
    const transport = try syntax.readSymbol(bytes, cursor);
    const designator = try syntax.readString(bytes, cursor);
    const hints = try readHintsView(bytes, cursor);
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
    return readPeerLocatorView(bytes, cursor);
}

/// Borrowed find over the lazy dict span: walk `{name value …}` in place and
/// return the named entry's value borrowing the frame without allocating. An
/// exotic value under another name is skipped exactly as materialize skips it.
/// An exotic value under the *searched* name is malformed, because a caller
/// that asks for a hint by name reads meaning into it.
fn syrupFindHint(hl: model.view.HintList, name: []const u8) model.view.Error!?model.HintValue {
    var walk = HintWalk.init(hl.bytes, 1);
    while (walk.next() catch return error.MalformedView) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.value orelse error.MalformedView;
    }
    return null;
}

fn syrupValidateHintShape(
    hl: model.view.HintList,
    wire_form: model.Hints.WireForm,
) model.view.ProjectError!void {
    if (wire_form == .boolean_false) return error.MalformedView;
    var walk = HintWalk.init(hl.bytes, 1);
    while (walk.next() catch return error.MalformedView) |_| {}
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

/// One pass over the entries of a `{name value …}` hint map, the rules every
/// reader of one shares: a String key whose name is valid and unseen, in
/// canonical key order, then a value the hint grammar knows read whole, or a
/// value of any other shape skipped. A reserved profile name carries signed
/// handshake authority, so under it a skipped value is refused here rather
/// than left for materialization to reject. The walk starts past the opening
/// brace and stops on the closing one, which the caller reads.
const HintWalk = struct {
    bytes: []const u8,
    cursor: usize,
    previous_key: ?[]const u8 = null,
    names: HintNameSet = .{},

    /// One entry: its name, and its value when the hint grammar knows it.
    const Entry = struct { name: []const u8, value: ?model.HintValue };

    fn init(bytes: []const u8, cursor: usize) HintWalk {
        return .{ .bytes = bytes, .cursor = cursor };
    }

    fn next(self: *HintWalk) Error!?Entry {
        if (self.cursor >= self.bytes.len) return Error.Incomplete;
        if (self.bytes[self.cursor] == '}') return null;
        const key_start = self.cursor;
        const name = try syntax.readString(self.bytes, &self.cursor);
        const key_encoded = self.bytes[key_start..self.cursor];
        if (!self.names.insert(name)) return Error.MalformedFrame;
        if (self.previous_key) |previous| {
            if (!codec_order.byteSliceBefore(previous, key_encoded)) return Error.MalformedFrame;
        }
        self.previous_key = key_encoded;
        const value = try readHintValue(self.bytes, &self.cursor);
        if (value == null and model.transport.isProfileHintName(name)) return Error.MalformedFrame;
        return .{ .name = name, .value = value };
    }
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

/// Read a value the hint grammar knows (a String, Bytes, a bounded Integer,
/// or a Boolean), or skip a value of any other Syrup shape and return null.
/// The digits of a length prefix or magnitude are scanned once to choose the
/// reader.
fn readHintValue(bytes: []const u8, cursor: *usize) Error!?model.HintValue {
    if (cursor.* >= bytes.len) return Error.Incomplete;
    switch (bytes[cursor.*]) {
        't', 'f' => return .{ .boolean = try syntax.readBool(bytes, cursor) },
        '0'...'9' => {
            const run = syntax.scanDecimal(bytes[cursor.*..]);
            const marker_index = cursor.* + run.len;
            if (marker_index >= bytes.len) return Error.Incomplete;
            switch (bytes[marker_index]) {
                '"' => return .{ .string = try syntax.readLeafScanned(bytes, cursor, run, '"') },
                ':' => return .{ .bytes = try syntax.readLeafScanned(bytes, cursor, run, ':') },
                '+', '-' => return .{ .integer = try syntax.readIntegerScanned(bytes, cursor, run) },
                else => {},
            }
        },
        else => {},
    }
    try syntax.skipSyrupValue(bytes, cursor);
    return null;
}

fn readHintsView(bytes: []const u8, cursor: *usize) Error!model.view.BorrowedHints {
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
        // Validate width and canonical key order now, so a lazy span is one the walk already
        // admitted. Strict order makes duplicate detection linear and gives a signed locator
        // one stable form across codec forwarding.
        const start = cursor.*;
        var walk = HintWalk.init(bytes, start + 1);
        while (try walk.next()) |_| {}
        cursor.* = walk.cursor;
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

/// Parse hints with allocation. Entries are heap-owned. Keys and values are
/// duped so the result outlives the frame. Free with `model.freeHints`.
/// Allocation failure propagates as `OutOfMemory`, never as a frame error:
/// running out of heap is not evidence the partner sent untrusted bytes.
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
        var entries: std.ArrayList(model.HintEntry) = .empty;
        errdefer {
            for (entries.items) |entry| model.freeHintEntry(allocator, entry);
            entries.deinit(allocator);
        }
        var walk = HintWalk.init(bytes, cursor.* + 1);
        while (try walk.next()) |entry| {
            const value = entry.value orelse continue;
            const name = try allocator.dupe(u8, entry.name);
            errdefer allocator.free(name);
            const cloned = try model.cloneHintValue(allocator, value);
            errdefer model.freeHintValue(allocator, cloned);
            try entries.append(allocator, .{ .name = name, .value = cloned });
        }
        cursor.* = walk.cursor;
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
    const tag = try syntax.readLabel(bytes, cursor);
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
