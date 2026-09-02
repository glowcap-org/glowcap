//! Borrowed codec-neutral Passable projection over Syrup bytes.
//!
//! Argument, reference, collection, and resolution views share one bounded
//! walker. Signed handoff envelopes live in `values/handoff.zig`; vtable
//! backings re-walk only their already-validated borrowed regions.

const std = @import("std");

const model = @import("model");
const codec_order = @import("codec_order");

const shared = @import("../shared.zig");
const syntax = @import("syntax.zig");
const locators = @import("locator.zig");
const handoff = @import("values/handoff.zig");

const Error = shared.Error;

/// Borrowed reference descriptor exactly as the wire carries it, before the
/// projection into the codec-neutral `model.view.Reference`.
const ReferenceView = union(enum) {
    near: model.NearRef,
    far: model.FarRef,
    promise: model.PromiseRef,
    sturdy: SturdyRefView,

    const SturdyRefView = struct {
        peer: model.view.PeerLocator,
        swissnum: []const u8,
    };
};

// ── Codec-neutral view projection ────────────────────────────────────────────
//
// `decodeBody` projects the borrowed codec-neutral `model.view.Body` over the
// frame's bytes — the single message shape the engine dispatches on. The
// unbounded sequences (`Args`, `PositionList`) are reached through inline
// vtable backings whose `Ctx.bytes` borrow the list region; `at` re-walks the
// Syrup bytes lazily. Argument projection is full fidelity — every arm the
// encoder emits decodes back. The backings re-walk a region that already
// framed successfully, so they pass `syntax.no_limit`.

const neutral_args_vtable = model.view.Args.VTable{
    .len = neutralArgsLen,
    .at = neutralArgsAt,
    .next = neutralArgsNext,
};

const neutral_positions_vtable = model.view.PositionList.VTable{
    .len = neutralPositionsLen,
    .at = neutralPositionsAt,
    .next = neutralPositionsNext,
};

fn neutralArgsLen(ctx: model.view.Args.Ctx) model.view.ProjectError!usize {
    var cursor: usize = 0;
    var total: usize = 0;
    while (cursor < ctx.bytes.len) : (total += 1) {
        _ = readNeutralArgument(ctx.bytes, &cursor, 0, syntax.no_limit) catch return error.MalformedView;
    }
    return total;
}

fn neutralArgsAt(ctx: model.view.Args.Ctx, index: usize) model.view.ProjectError!model.view.Argument {
    var cursor: usize = 0;
    var current: usize = 0;
    while (cursor < ctx.bytes.len) : (current += 1) {
        const argument = readNeutralArgument(ctx.bytes, &cursor, 0, syntax.no_limit) catch return error.MalformedView;
        if (current == index) return argument;
    }
    return error.MalformedView;
}

/// Forward cursor: `cursor` is a byte offset into the list region. One
/// `readNeutralArgument` advances it past the element it returns, so a full
/// walk is a single linear pass, not the per-`at` re-scan from byte 0.
fn neutralArgsNext(ctx: model.view.Args.Ctx, cursor: *u64) model.view.ProjectError!?model.view.Argument {
    var c: usize = @intCast(cursor.*);
    if (c >= ctx.bytes.len) return null;
    const argument = readNeutralArgument(ctx.bytes, &c, 0, syntax.no_limit) catch return error.MalformedView;
    cursor.* = @intCast(c);
    return argument;
}

fn neutralPositionsLen(ctx: model.view.PositionList.Ctx) model.view.ProjectError!usize {
    var cursor: usize = 0;
    var total: usize = 0;
    while (cursor < ctx.bytes.len) : (total += 1) {
        _ = syntax.readPositiveInt(ctx.bytes, &cursor) catch return error.MalformedView;
    }
    return total;
}

fn neutralPositionsAt(ctx: model.view.PositionList.Ctx, index: usize) model.view.ProjectError!u64 {
    var cursor: usize = 0;
    var current: usize = 0;
    while (cursor < ctx.bytes.len) : (current += 1) {
        const value = syntax.readPositiveInt(ctx.bytes, &cursor) catch return error.MalformedView;
        if (current == index) return value;
    }
    return error.MalformedView;
}

fn neutralPositionsNext(ctx: model.view.PositionList.Ctx, cursor: *u64) model.view.ProjectError!?u64 {
    var c: usize = @intCast(cursor.*);
    if (c >= ctx.bytes.len) return null;
    const value = syntax.readPositiveInt(ctx.bytes, &c) catch return error.MalformedView;
    cursor.* = @intCast(c);
    return value;
}

pub fn neutralArgs(list_body: []const u8) model.view.Args {
    return model.view.Args.fromBacking(.{ .bytes = list_body }, &neutral_args_vtable);
}

pub fn neutralPositions(list_body: []const u8) model.view.PositionList {
    return model.view.PositionList.fromBacking(.{ .bytes = list_body }, &neutral_positions_vtable);
}

pub fn neutralReference(reference: ReferenceView) model.view.Reference {
    return switch (reference) {
        .near => |near| .{ .near = near },
        .far => |far| .{ .far = far },
        // Syrup's `desc:answer` carries no path operand (single-hop only), so a
        // decoded promise target always has the empty path.
        .promise => |promise| .{ .promise = .{ .answer_position = promise.answer_position } },
        .sturdy => |sturdy| .{ .sturdy = .{
            .peer = sturdy.peer,
            .swissnum = sturdy.swissnum,
        } },
    };
}

/// Project one borrowed full-fidelity `model.view.Argument` and advance
/// `cursor` past it. Nested `list` / `set` / `tagged` arms project lazily as
/// backed `model.view.Args` over their byte sub-region.
fn readNeutralArgument(bytes: []const u8, cursor: *usize, depth: usize, limit: usize) Error!model.view.Argument {
    if (depth > syntax.max_decode_nesting) return Error.MalformedFrame;
    // A frame built of many small elements crosses the cap one element at a
    // time; refuse as soon as the walk passes it instead of after a full decode.
    if (cursor.* > limit) return Error.FrameTooLarge;
    if (cursor.* >= bytes.len) return Error.Incomplete;
    return switch (bytes[cursor.*]) {
        '0'...'9' => blk: {
            const marker_index = cursor.* + syntax.countDigits(bytes[cursor.*..]);
            if (marker_index >= bytes.len) return Error.Incomplete;
            break :blk switch (bytes[marker_index]) {
                ':' => .{ .bytes = try syntax.readBytesLimited(bytes, cursor, limit) },
                '"' => .{ .string = try syntax.readStringLimited(bytes, cursor, limit) },
                '\'' => .{ .symbol = try syntax.readSymbolLimited(bytes, cursor, limit) },
                '+', '-' => try syntax.readIntegerArgument(bytes, cursor),
                else => Error.UnsupportedArgument,
            };
        },
        't', 'f' => .{ .boolean = try syntax.readBool(bytes, cursor) },
        'D' => .{ .float64 = try syntax.readFloat64(bytes, cursor) },
        '[' => .{ .list = neutralArgs(try sliceArgumentListNeutral(bytes, cursor, depth + 1, limit)) },
        '#' => .{ .set = neutralArgs(try sliceSetNeutral(bytes, cursor, depth + 1, limit)) },
        '{' => .{ .@"struct" = neutralStructEntries(try sliceStructNeutral(bytes, cursor, depth + 1, limit)) },
        '<' => try readNeutralRecord(bytes, cursor, depth, limit),
        else => Error.UnsupportedArgument,
    };
}

/// Decode one Syrup `<label …>` record after seeing `'<'`. Reads the label once,
/// then dispatches by label length (hot known tags share a bucket) before a
/// single equality check — no multi-probe `startsWith` cascade over the same
/// bytes for handoff / reference / ordinary records.
fn readNeutralRecord(bytes: []const u8, cursor: *usize, depth: usize, limit: usize) Error!model.view.Argument {
    const record_start = cursor.*;
    try syntax.readByte(bytes, cursor, '<');
    const tag = try syntax.readSymbolLimited(bytes, cursor, limit);

    switch (tag.len) {
        "kw".len => if (std.mem.eql(u8, tag, "kw")) {
            const name = try syntax.readSymbolLimited(bytes, cursor, limit);
            try syntax.readByte(bytes, cursor, '>');
            return .{ .keyword = name };
        },
        "void".len => if (std.mem.eql(u8, tag, "void")) {
            try syntax.readByte(bytes, cursor, '>');
            return .{ .void = {} };
        },
        "error".len => if (std.mem.eql(u8, tag, "error")) {
            const message = try syntax.readStringLimited(bytes, cursor, limit);
            try syntax.readByte(bytes, cursor, '>');
            return .{ .@"error" = .{ .message = message } };
        },
        // user-record / desc:export / desc:answer share length 11.
        "desc:export".len => {
            if (std.mem.eql(u8, tag, "desc:export")) {
                return .{ .reference = neutralReference(try finishReference(.desc_export, bytes, cursor)) };
            }
            if (std.mem.eql(u8, tag, "desc:answer")) {
                return .{ .reference = neutralReference(try finishReference(.desc_answer, bytes, cursor)) };
            }
            if (std.mem.eql(u8, tag, "user-record")) {
                const record_tag = try syntax.readSymbolLimited(bytes, cursor, limit);
                const value_body = try sliceArgumentListNeutral(bytes, cursor, depth + 1, limit);
                try syntax.readByte(bytes, cursor, '>');
                return .{ .tagged = .{ .tag = record_tag, .value = neutralArgs(value_body) } };
            }
        },
        "ocapn-sturdyref".len => if (std.mem.eql(u8, tag, "ocapn-sturdyref")) {
            const peer = try locators.readPeerLocatorView(bytes, cursor, limit);
            const swissnum = try syntax.readBytesLimited(bytes, cursor, limit);
            try syntax.readByte(bytes, cursor, '>');
            return .{ .reference = .{ .sturdy = .{
                .peer = peer,
                .swissnum = swissnum,
            } } };
        },
        "desc:sig-envelope".len => if (std.mem.eql(u8, tag, "desc:sig-envelope")) {
            return .{ .handoff = try handoff.finishSignedHandoff(bytes, cursor, limit, record_start) };
        },
        "desc:import-object".len => if (std.mem.eql(u8, tag, "desc:import-object")) {
            return .{ .reference = neutralReference(try finishReference(.desc_import_object, bytes, cursor)) };
        },
        "desc:import-promise".len => if (std.mem.eql(u8, tag, "desc:import-promise")) {
            return .{ .reference = neutralReference(try finishReference(.desc_import_promise, bytes, cursor)) };
        },
        else => {},
    }

    // A record label glowcap does not model is a foreign record — a
    // Goblins exception such as `<exn:fail:mystery>` riding a break
    // payload — projected as Tagged: the label is the tag, the fields
    // the value, exactly the shape `engine.events.breakReasonFromPayload`
    // reads a reason from. Decode-side leniency only (glowcap's own
    // Tagged spells `<user-record …>` on encode); whether a tagged
    // value is admissible where it lands stays the session's verdict.
    const fields = try sliceRecordFieldsNeutral(bytes, cursor, depth + 1, limit);
    try syntax.readByte(bytes, cursor, '>');
    return .{ .tagged = .{ .tag = tag, .value = neutralArgs(fields) } };
}

/// Slice a foreign record's field run: zero or more values up to the closing
/// `>`, which stays for the caller to consume. Width and depth ride the same
/// bounds as every collection walk.
fn sliceRecordFieldsNeutral(bytes: []const u8, cursor: *usize, depth: usize, limit: usize) Error![]const u8 {
    const body_start = cursor.*;
    var elements: usize = 0;
    while (cursor.* < bytes.len and bytes[cursor.*] != '>') {
        elements += 1;
        if (elements > syntax.max_collection_elements) return Error.MalformedFrame;
        _ = try readNeutralArgument(bytes, cursor, depth, limit);
    }
    if (cursor.* >= bytes.len) return Error.Incomplete;
    return bytes[body_start..cursor.*];
}

/// Slice one delimited sequence body (between `open` and `close`) using the
/// full-fidelity walker, advancing `cursor` past the closing delimiter. The
/// list and set slicers share this one walk and differ only in their
/// delimiters. `depth` is the nesting level entered (bounded by
/// `syntax.max_decode_nesting`); width is bounded by `syntax.max_collection_elements`.
fn sliceSequenceNeutral(
    bytes: []const u8,
    cursor: *usize,
    depth: usize,
    limit: usize,
    comptime open: u8,
    comptime close: u8,
) Error![]const u8 {
    try syntax.readByte(bytes, cursor, open);
    const body_start = cursor.*;
    var elements: usize = 0;
    while (cursor.* < bytes.len and bytes[cursor.*] != close) {
        elements += 1;
        if (elements > syntax.max_collection_elements) return Error.MalformedFrame;
        _ = try readNeutralArgument(bytes, cursor, depth, limit);
    }
    if (cursor.* >= bytes.len) return Error.Incomplete;
    const body = bytes[body_start..cursor.*];
    cursor.* += 1;
    return body;
}

/// Slice a `[ … ]` argument list body, advancing `cursor` past the closing `]`.
pub fn sliceArgumentListNeutral(bytes: []const u8, cursor: *usize, depth: usize, limit: usize) Error![]const u8 {
    return sliceSequenceNeutral(bytes, cursor, depth, limit, '[', ']');
}

/// Slice a `# … $` set body, advancing `cursor` past the closing `$`. Unlike an
/// argument list, a set is unordered and its elements are unique, so the wire
/// form is canonical only in strictly-ascending encoded-element order — the same
/// rule `sliceStructNeutral` enforces on keys, and the encode-side partner of
/// `writeCanonicalSet`, which sorts elements by their encoding. Syrup encodings
/// are self-delimiting and therefore prefix-free, so a non-ascending element is a
/// non-canonical spelling and an equal element is a duplicate; both are refused
/// `MalformedFrame` here rather than admitted as a second spelling of one set.
fn sliceSetNeutral(bytes: []const u8, cursor: *usize, depth: usize, limit: usize) Error![]const u8 {
    try syntax.readByte(bytes, cursor, '#');
    const body_start = cursor.*;
    var previous_element: ?[]const u8 = null;
    var elements: usize = 0;
    while (cursor.* < bytes.len and bytes[cursor.*] != '$') {
        elements += 1;
        if (elements > syntax.max_collection_elements) return Error.MalformedFrame;
        const element_start = cursor.*;
        _ = try readNeutralArgument(bytes, cursor, depth, limit);
        const element = bytes[element_start..cursor.*];
        if (previous_element) |previous| {
            if (!codec_order.byteSliceBefore(previous, element)) return Error.MalformedFrame;
        }
        previous_element = element;
    }
    if (cursor.* >= bytes.len) return Error.Incomplete;
    const body = bytes[body_start..cursor.*];
    cursor.* += 1;
    return body;
}

/// Slice a `{ … }` dictionary body (between the braces) into the bytes the lazy
/// struct backing walks, advancing `cursor` past the closing `}`. The walk
/// enforces the OCapN Struct grammar at the codec boundary (Model.md § Struct):
/// every key must be a String, and no key may repeat. A non-String key fails when
/// the key read demands the `"` marker. Canonical Syrup orders dictionary
/// entries by the fully-encoded key, lowest octets first (the upstream
/// draft-specification's Sorting Algorithm), and every encoder this decoder
/// faces — the upstream Racket encoder Goblins and the fixture corpus use, the
/// conformance suite's Python encoder, and this codec's own `writeStruct` —
/// emits that order. So each key's encoded span need only compare against the
/// previous one: a non-ascending key is a non-canonical wire spelling of the
/// message, refused like a non-canonical length digit, and a duplicate key
/// (ADR-0046) is never strictly ascending, so the same O(1) comparison refuses
/// it without re-walking the prior entries.
fn sliceStructNeutral(bytes: []const u8, cursor: *usize, depth: usize, limit: usize) Error![]const u8 {
    if (depth > syntax.max_decode_nesting) return Error.MalformedFrame;
    try syntax.readByte(bytes, cursor, '{');
    const body_start = cursor.*;
    var previous_key_encoded: ?[]const u8 = null;
    var entries: usize = 0;
    while (cursor.* < bytes.len and bytes[cursor.*] != '}') {
        entries += 1;
        if (entries > syntax.max_collection_elements) return Error.MalformedFrame;
        const key_start = cursor.*;
        _ = try syntax.readStringLimited(bytes, cursor, limit);
        const key_encoded = bytes[key_start..cursor.*];
        if (previous_key_encoded) |previous| {
            if (!codec_order.byteSliceBefore(previous, key_encoded)) return Error.MalformedFrame;
        }
        previous_key_encoded = key_encoded;
        _ = try readNeutralArgument(bytes, cursor, depth, limit);
    }
    if (cursor.* >= bytes.len) return Error.Incomplete;
    const body = bytes[body_start..cursor.*];
    cursor.* += 1;
    return body;
}

const neutral_struct_vtable = model.view.StructEntries.VTable{
    .len = neutralStructLen,
    .at = neutralStructAt,
    .next = neutralStructNext,
};

fn neutralStructLen(ctx: model.view.StructEntries.Ctx) model.view.ProjectError!usize {
    var cursor: usize = 0;
    var total: usize = 0;
    while (cursor < ctx.bytes.len) : (total += 1) {
        _ = readStructEntry(ctx.bytes, &cursor) catch return error.MalformedView;
    }
    return total;
}

fn neutralStructAt(ctx: model.view.StructEntries.Ctx, index: usize) model.view.ProjectError!model.view.StructEntry {
    var cursor: usize = 0;
    var current: usize = 0;
    while (cursor < ctx.bytes.len) : (current += 1) {
        const entry = readStructEntry(ctx.bytes, &cursor) catch return error.MalformedView;
        if (current == index) return entry;
    }
    return error.MalformedView;
}

fn neutralStructNext(ctx: model.view.StructEntries.Ctx, cursor: *u64) model.view.ProjectError!?model.view.StructEntry {
    var c: usize = @intCast(cursor.*);
    if (c >= ctx.bytes.len) return null;
    const entry = readStructEntry(ctx.bytes, &c) catch return error.MalformedView;
    cursor.* = @intCast(c);
    return entry;
}

/// Read one (String key, Value) pair from a struct body and advance `cursor`. The
/// body was validated at slice time, so a read failure here is `MalformedView`.
fn readStructEntry(bytes: []const u8, cursor: *usize) Error!model.view.StructEntry {
    const key = try syntax.readStringLimited(bytes, cursor, syntax.no_limit);
    const value = try readNeutralArgument(bytes, cursor, 0, syntax.no_limit);
    return .{ .key = key, .value = value };
}

fn neutralStructEntries(struct_body: []const u8) model.view.StructEntries {
    return model.view.StructEntries.fromBacking(.{ .bytes = struct_body }, &neutral_struct_vtable);
}

pub fn readNeutralResolution(bytes: []const u8, cursor: *usize, limit: usize) Error!model.view.Resolution {
    try syntax.readByte(bytes, cursor, '<');
    const tag = try syntax.readSymbolLimited(bytes, cursor, limit);
    if (std.mem.eql(u8, tag, "resolve:fulfill")) {
        const argument = try readNeutralArgument(bytes, cursor, 0, limit);
        try syntax.readByte(bytes, cursor, '>');
        return .{ .fulfill = argument };
    }
    if (std.mem.eql(u8, tag, "resolve:break")) {
        const err = try readError(bytes, cursor, limit);
        try syntax.readByte(bytes, cursor, '>');
        return .{ .@"break" = .{ .message = err.message } };
    }
    return Error.MalformedFrame;
}

/// Decode a payload/target-position descriptor into a reference in the
/// **receiver's** perspective (ADR-0010 perspective flip, matching Goblins's
/// `incoming-post-unmarshall!`). The flip is a fixed wire-tag
/// relabel — no table lookup, so the codec still owns no authority:
///
/// - `<desc:export N>` — the sender names *our* export — lifts to `.near`.
/// - `<desc:import-object N>` / `<desc:import-promise N>` — the sender names one
///   of *its* exports for us to import — lift to `.far`, preserving the
///   object/promise kind.
/// - `<desc:answer N>` lifts to `.promise`.
///
/// The encoder is the mirror: it writes `near` as `desc:import-object` and `far`
/// as `desc:export`, so a reference sent and echoed back swaps arms — that swap *is* the
/// perspective change, not a round-trip bug.
pub fn readReference(bytes: []const u8, cursor: *usize, limit: usize) Error!ReferenceView {
    try syntax.readByte(bytes, cursor, '<');
    const tag = try syntax.readSymbolLimited(bytes, cursor, limit);
    return switch (tag.len) {
        "desc:export".len => if (std.mem.eql(u8, tag, "desc:export"))
            finishReference(.desc_export, bytes, cursor)
        else if (std.mem.eql(u8, tag, "desc:answer"))
            finishReference(.desc_answer, bytes, cursor)
        else
            Error.UnsupportedReference,
        "desc:import-object".len => if (std.mem.eql(u8, tag, "desc:import-object"))
            finishReference(.desc_import_object, bytes, cursor)
        else
            Error.UnsupportedReference,
        "desc:import-promise".len => if (std.mem.eql(u8, tag, "desc:import-promise"))
            finishReference(.desc_import_promise, bytes, cursor)
        else
            Error.UnsupportedReference,
        else => Error.UnsupportedReference,
    };
}

const ReferenceWire = enum { desc_export, desc_import_object, desc_import_promise, desc_answer };

/// Finish a desc:* reference record whose opening `<` and label are already
/// consumed: one positive integer position, then `>`.
fn finishReference(comptime kind: ReferenceWire, bytes: []const u8, cursor: *usize) Error!ReferenceView {
    const position = try syntax.readPositiveInt(bytes, cursor);
    try syntax.readByte(bytes, cursor, '>');
    return switch (kind) {
        .desc_export => .{ .near = .{ .export_position = model.ExportPosition.from(position), .kind = .object } },
        .desc_import_object => .{ .far = .{ .import_position = model.ImportPosition.from(position), .kind = .object } },
        .desc_import_promise => .{ .far = .{ .import_position = model.ImportPosition.from(position), .kind = .promise } },
        .desc_answer => .{ .promise = .{ .answer_position = model.AnswerPosition.from(position) } },
    };
}

pub fn readOptionalReference(bytes: []const u8, cursor: *usize, limit: usize) Error!?ReferenceView {
    if (cursor.* < bytes.len and bytes[cursor.*] == 'f') {
        cursor.* += 1;
        return null;
    }
    return try readReference(bytes, cursor, limit);
}

fn readError(bytes: []const u8, cursor: *usize, limit: usize) Error!model.BreakReason {
    try syntax.readByte(bytes, cursor, '<');
    const tag = try syntax.readSymbolLimited(bytes, cursor, limit);
    if (!std.mem.eql(u8, tag, "error")) {
        return Error.MalformedFrame;
    }
    const message = try syntax.readStringLimited(bytes, cursor, limit);
    try syntax.readByte(bytes, cursor, '>');
    return .{ .message = message };
}

pub const decodeSignedHandoffGiveOwned = handoff.decodeSignedHandoffGiveOwned;
