//! Borrowed codec-neutral Passable projection over Syrup bytes.
//!
//! Argument, reference, collection, and resolution views share one bounded
//! walker. Signed handoff envelopes live in `values/handoff.zig`. Vtable
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
};

// ── Codec-neutral view projection ────────────────────────────────────────────
//
// `decodeBody` projects the borrowed codec-neutral `model.view.Body` over the
// frame's bytes, the single message shape the engine dispatches on. The
// unbounded sequences (`Args`, `PositionList`) are reached through inline
// vtable backings whose `Ctx.bytes` borrow the list region, and `at` re-walks the
// Syrup bytes lazily. Argument projection is full fidelity, every arm the
// encoder emits decodes back. The backings re-walk a region that already
// framed successfully.

/// The lazy sequence verbs over one sliced collection body, for every
/// element reader the decoder has: `len` is the count the slicing walk
/// stored in `w2`, so it is a read rather than a second walk of the subtree,
/// `at` re-walks the region from byte 0, and `next` reads the element at the
/// byte-offset cursor and advances it past that element, so a full walk is
/// one linear pass.
fn NeutralSequence(
    comptime Sequence: type,
    comptime Elem: type,
    comptime readElement: fn ([]const u8, *usize) Error!Elem,
) type {
    return struct {
        const vtable = Sequence.VTable{ .len = len, .at = at, .next = next, .tail = tail };

        fn len(ctx: Sequence.Ctx) model.view.ProjectError!usize {
            return @intCast(ctx.w2);
        }

        fn at(ctx: Sequence.Ctx, index: usize) model.view.ProjectError!Elem {
            var cursor: usize = 0;
            var current: usize = 0;
            while (cursor < ctx.bytes.len) : (current += 1) {
                const element = readElement(ctx.bytes, &cursor) catch return error.MalformedView;
                if (current == index) return element;
            }
            return error.MalformedView;
        }

        fn next(ctx: Sequence.Ctx, cursor: *u64, out: *Elem) model.view.ProjectError!bool {
            var c: usize = @intCast(cursor.*);
            if (c >= ctx.bytes.len) return false;
            out.* = readElement(ctx.bytes, &c) catch return error.MalformedView;
            cursor.* = @intCast(c);
            return true;
        }

        /// Scan past `skip` elements once and keep the bytes after them.
        fn tail(ctx: Sequence.Ctx, skip: usize) model.view.ProjectError!Sequence.Ctx {
            if (skip > ctx.w2) return error.MalformedView;
            var cursor: usize = 0;
            for (0..skip) |_| _ = readElement(ctx.bytes, &cursor) catch return error.MalformedView;
            return .{ .bytes = ctx.bytes[cursor..], .w2 = ctx.w2 - skip };
        }

        fn over(sliced: syntax.Sliced) Sequence {
            return Sequence.fromBacking(.{ .bytes = sliced.body, .w2 = sliced.elements }, &vtable);
        }
    };
}

fn readArgumentElement(bytes: []const u8, cursor: *usize) Error!model.view.Argument {
    return readNeutralArgument(null, bytes, cursor, 0);
}

const neutral_args = NeutralSequence(model.view.Args, model.view.Argument, readArgumentElement);
const neutral_positions = NeutralSequence(model.view.PositionList, u64, syntax.readPositiveInt);
const neutral_struct = NeutralSequence(model.view.StructEntries, model.view.StructEntry, readStructEntry);

pub fn neutralArgs(sliced: syntax.Sliced) model.view.Args {
    return neutral_args.over(sliced);
}

pub fn neutralPositions(sliced: syntax.Sliced) model.view.PositionList {
    return neutral_positions.over(sliced);
}

fn neutralStructEntries(sliced: syntax.Sliced) model.view.StructEntries {
    return neutral_struct.over(sliced);
}

pub fn neutralReference(reference: ReferenceView) model.view.Reference {
    return switch (reference) {
        .near => |near| .{ .near = near },
        .far => |far| .{ .far = far },
        // Syrup's `desc:answer` carries no path operand (single-hop only), so a
        // decoded promise target always has the empty path.
        .promise => |promise| .{ .promise = .{ .answer_position = promise.answer_position } },
    };
}

/// Project a `<ocapn-sturdyref …>` whose field region the decoder sliced
/// structurally: one peer locator and one swissnum, nothing else.
fn projectSturdyRef(ctx: model.view.LazySturdyRef.Ctx) model.view.ProjectError!model.view.SturdyRef {
    var cursor: usize = 0;
    const peer = locators.readPeerLocatorView(ctx.bytes, &cursor) catch return error.MalformedView;
    const swissnum = syntax.readBytes(ctx.bytes, &cursor) catch return error.MalformedView;
    if (cursor != ctx.bytes.len) return error.MalformedView;
    return .{ .peer = peer, .swissnum = swissnum };
}

/// Project one borrowed full-fidelity `model.view.Argument` and advance
/// `cursor` past it. With `slab`, each list, set, and tagged value met on
/// the way is parsed once into views the slab lends (`readElements`). With
/// none, they project lazily as backed `model.view.Args` over their byte
/// sub-region, the extent-only read every backed sequence uses when a
/// consumer walks it.
pub fn readNeutralArgument(slab: ?*model.view.ValueSlab, bytes: []const u8, cursor: *usize, depth: usize) Error!model.view.Argument {
    // The nesting cap is held where a collection is entered (`depth` is
    // already checked for this level, and each nested slicer checks its own
    // on entry), so no element pays a second compare here.
    if (cursor.* >= bytes.len) return Error.MalformedFrame;
    return switch (bytes[cursor.*]) {
        '0'...'9' => blk: {
            // The digits are scanned once here to find the marker, and the
            // leaf reader the marker chooses takes the run instead of
            // scanning it again.
            const run = syntax.scanDecimal(bytes[cursor.*..]);
            const marker_index = cursor.* + run.len;
            if (marker_index >= bytes.len) return Error.MalformedFrame;
            break :blk switch (bytes[marker_index]) {
                ':' => .{ .bytes = try syntax.readLeafScanned(bytes, cursor, run, ':') },
                '"' => .{ .string = try syntax.readLeafScanned(bytes, cursor, run, '"') },
                '\'' => .{ .symbol = try syntax.readLeafScanned(bytes, cursor, run, '\'') },
                '+', '-' => try syntax.readIntegerArgumentScanned(bytes, cursor, run),
                else => Error.UnsupportedArgument,
            };
        },
        't', 'f' => .{ .boolean = try syntax.readBool(bytes, cursor) },
        'D' => .{ .float64 = try syntax.readFloat64(bytes, cursor) },
        '[' => .{ .list = try readDelimited(slab, bytes, cursor, depth + 1, '[', ']', false) },
        '#' => .{ .set = try readDelimited(slab, bytes, cursor, depth + 1, '#', '$', true) },
        '{' => .{ .@"struct" = try readStruct(slab, bytes, cursor, depth + 1) },
        '<' => try readNeutralRecord(slab, bytes, cursor, depth),
        else => Error.UnsupportedArgument,
    };
}

/// Decode one Syrup `<label …>` record after seeing `'<'`. Reads the label once,
/// then dispatches by label length (hot known tags share a bucket) before a
/// single equality check, no multi-probe `startsWith` cascade over the same
/// bytes for handoff / reference / ordinary records.
fn readNeutralRecord(slab: ?*model.view.ValueSlab, bytes: []const u8, cursor: *usize, depth: usize) Error!model.view.Argument {
    const record_start = cursor.*;
    try syntax.readByte(bytes, cursor, '<');
    const tag = try syntax.readLabel(bytes, cursor);

    switch (tag.len) {
        "kw".len => if (std.mem.eql(u8, tag, "kw")) {
            const name = try syntax.readSymbol(bytes, cursor);
            try syntax.readByte(bytes, cursor, '>');
            return .{ .keyword = name };
        },
        "void".len => if (std.mem.eql(u8, tag, "void")) {
            try syntax.readByte(bytes, cursor, '>');
            return .{ .void = {} };
        },
        "error".len => if (std.mem.eql(u8, tag, "error")) {
            const message = try syntax.readString(bytes, cursor);
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
                const record_tag = try syntax.readSymbol(bytes, cursor);
                const value = try readDelimited(slab, bytes, cursor, depth + 1, '[', ']', false);
                try syntax.readByte(bytes, cursor, '>');
                return .{ .tagged = .{ .tag = record_tag, .value = value } };
            }
        },
        // The two wide, rare records are framed here and parsed on read
        // (`model.view.Lazy`). The structural walk bounds them like any
        // foreign record; the typed projector refuses what it cannot read.
        "ocapn-sturdyref".len => if (std.mem.eql(u8, tag, "ocapn-sturdyref")) {
            const fields = try sliceRecordFieldsNeutral(bytes, cursor, depth + 1);
            try syntax.readByte(bytes, cursor, '>');
            return .{ .reference = .{ .sturdy = .fromBacking(.{ .bytes = fields.body }, projectSturdyRef) } };
        },
        "desc:sig-envelope".len => if (std.mem.eql(u8, tag, "desc:sig-envelope")) {
            _ = try sliceRecordFieldsNeutral(bytes, cursor, depth + 1);
            try syntax.readByte(bytes, cursor, '>');
            return .{ .handoff = .fromBacking(.{ .bytes = bytes[record_start..cursor.*] }, handoff.projectSignedHandoff) };
        },
        "desc:import-object".len => if (std.mem.eql(u8, tag, "desc:import-object")) {
            return .{ .reference = neutralReference(try finishReference(.desc_import_object, bytes, cursor)) };
        },
        "desc:import-promise".len => if (std.mem.eql(u8, tag, "desc:import-promise")) {
            return .{ .reference = neutralReference(try finishReference(.desc_import_promise, bytes, cursor)) };
        },
        else => {},
    }

    // A record label glowcap does not model is a foreign record, a
    // Goblins exception such as `<exn:fail:mystery>` riding a break
    // payload, projected as Tagged: the label is the tag, the fields
    // the value, exactly the shape `engine.events.breakReasonFromPayload`
    // reads a reason from. Decode-side leniency only (glowcap's own
    // Tagged spells `<user-record …>` on encode); whether a tagged
    // value is admissible where it lands stays the session's verdict. The
    // label becomes data here, so it passes the symbol check the matched
    // labels above did not need.
    if (!syntax.symbolBytesValid(tag)) return Error.MalformedFrame;
    const value = try readElements(slab, bytes, cursor, depth + 1, '>', false);
    cursor.* += 1;
    return .{ .tagged = .{ .tag = tag, .value = value } };
}

/// Read the elements of one sequence up to `close`, which stays unread. With
/// room in `slab`, parent slots are reserved before reading their children.
/// Closing the sequence settles its views for later readers. A sequence the
/// room cannot hold drops its stack and cached children and stays wire-backed.
/// Later children stay wire-backed too, since a backed reader parses them afresh. `ordered` refuses a set whose elements are
/// out of canonical order (ADR-0001).
fn readElements(
    slab: ?*model.view.ValueSlab,
    bytes: []const u8,
    cursor: *usize,
    depth: usize,
    comptime close: u8,
    comptime ordered: bool,
) Error!model.view.Args {
    if (depth > syntax.max_decode_nesting) return Error.MalformedFrame;
    if (comptime !ordered and close == ']') {
        if (depth != 0) if (slab) |room| {
            if (readIntegerRun(room, bytes, cursor)) |words| return .fromRun(words);
        };
    }
    const body_start = cursor.*;
    var previous: ?[]const u8 = null;
    var elements: usize = 0;
    var open = model.view.ValueSlab.OpenSequence(model.view.Argument).begin(slab);
    while (cursor.* < bytes.len and bytes[cursor.*] != close) {
        elements += 1;
        if (elements > syntax.max_collection_elements) return Error.MalformedFrame;
        const slot = open.push();
        const start = cursor.*;
        const argument = try readNeutralArgument(open.room, bytes, cursor, depth);
        if (ordered) {
            const span = bytes[start..cursor.*];
            if (previous) |p| if (!codec_order.byteSliceBefore(p, span)) return Error.MalformedFrame;
            previous = span;
        }
        if (slot) |reserved| reserved.* = argument;
    }
    if (cursor.* >= bytes.len) return Error.MalformedFrame;
    if (open.settle()) |views| return .fromViews(views);
    return neutralArgs(.{ .body = bytes[body_start..cursor.*], .elements = elements });
}

/// Try a flat integer list in the frame's unused head. Every integer passes
/// the ordinary canonical reader. A mixed, oversized, empty, or malformed
/// list leaves the cursor and slab unchanged for the general reader, which
/// owns the final verdict. Speculation reads at most the head's word capacity
/// plus one failed leaf, whose bytes are bounded by the frame.
fn readIntegerRun(slab: *model.view.ValueSlab, bytes: []const u8, cursor: *usize) ?[]const u8 {
    var writer = slab.beginIntegers();
    var position = cursor.*;
    while (position < bytes.len and bytes[position] != ']') {
        if (writer.count == syntax.max_collection_elements) return null;
        const integer = syntax.readInteger(bytes, &position) catch return null;
        if (!writer.append(integer)) return null;
    }
    if (position == bytes.len) return null;
    const words = writer.finish() orelse return null;
    cursor.* = position;
    return words;
}

fn readDelimited(
    slab: ?*model.view.ValueSlab,
    bytes: []const u8,
    cursor: *usize,
    depth: usize,
    comptime open: u8,
    comptime close: u8,
    comptime ordered: bool,
) Error!model.view.Args {
    try syntax.readByte(bytes, cursor, open);
    const elements = try readElements(slab, bytes, cursor, depth, close, ordered);
    cursor.* += 1;
    return elements;
}

/// Walk the elements of one collection body up to `close`, which stays for
/// the caller, under the bounds every collection walk shares: the nesting
/// level entered (`syntax.max_decode_nesting`, checked on entry so an empty
/// collection past the cap is refused like a full one) and the width
/// (`syntax.max_collection_elements`). `readElement` reads one element and
/// returns the span its canonical order is judged by, or null where order
/// is free. Syrup encodings are self-delimiting and so prefix-free, so a span
/// not strictly after the previous one is a non-canonical form or a
/// duplicate, and both are refused `MalformedFrame` rather than admitted as a
/// second form of one collection.
fn sliceElements(
    bytes: []const u8,
    cursor: *usize,
    depth: usize,
    comptime close: u8,
    comptime readElement: fn ([]const u8, *usize, usize) Error!?[]const u8,
) Error!syntax.Sliced {
    if (depth > syntax.max_decode_nesting) return Error.MalformedFrame;
    const body_start = cursor.*;
    var previous: ?[]const u8 = null;
    var elements: usize = 0;
    while (cursor.* < bytes.len and bytes[cursor.*] != close) {
        elements += 1;
        if (elements > syntax.max_collection_elements) return Error.MalformedFrame;
        if (try readElement(bytes, cursor, depth)) |span| {
            if (previous) |p| if (!codec_order.byteSliceBefore(p, span)) return Error.MalformedFrame;
            previous = span;
        }
    }
    if (cursor.* >= bytes.len) return Error.MalformedFrame;
    return .{ .body = bytes[body_start..cursor.*], .elements = elements };
}

/// An element of a list or record field run: any value, in any order.
fn freeElement(bytes: []const u8, cursor: *usize, depth: usize) Error!?[]const u8 {
    _ = try readNeutralArgument(null, bytes, cursor, depth);
    return null;
}

/// Slice a foreign record's field run: zero or more values up to the closing
/// `>`, which stays for the caller to consume.
fn sliceRecordFieldsNeutral(bytes: []const u8, cursor: *usize, depth: usize) Error!syntax.Sliced {
    return sliceElements(bytes, cursor, depth, '>', freeElement);
}

/// Read a top-level `[ … ]` argument list once, advancing `cursor` past the
/// closing `]`. Finding the list's end already parses every element, so each
/// parent slot is reserved before reading its children. Collections that fit
/// remain cached for later readers (ADR-0063). A list longer than
/// the room releases its cached children and comes back wire-backed, so the
/// slab bounds memory and never the list.
pub inline fn readArgumentList(slab: *model.view.ValueSlab, bytes: []const u8, cursor: *usize) Error!model.view.Args {
    return readDelimited(slab, bytes, cursor, 0, '[', ']', false);
}

/// Read every key and value once. Syrup orders encoded String keys, so
/// duplicate and out-of-order keys fail even when the head has no room.
fn readStruct(slab: ?*model.view.ValueSlab, bytes: []const u8, cursor: *usize, depth: usize) Error!model.view.StructEntries {
    if (depth > syntax.max_decode_nesting) return Error.MalformedFrame;
    try syntax.readByte(bytes, cursor, '{');
    const body_start = cursor.*;
    var previous: ?[]const u8 = null;
    var elements: usize = 0;
    var open = model.view.ValueSlab.OpenSequence(model.view.StructEntry).begin(slab);
    while (cursor.* < bytes.len and bytes[cursor.*] != '}') {
        elements += 1;
        if (elements > syntax.max_collection_elements) return Error.MalformedFrame;
        const start = cursor.*;
        const key = try syntax.readString(bytes, cursor);
        const span = bytes[start..cursor.*];
        if (previous) |prior| if (!codec_order.byteSliceBefore(prior, span)) return Error.MalformedFrame;
        previous = span;
        const slot = open.push();
        const value = try readNeutralArgument(open.room, bytes, cursor, depth);
        if (slot) |reserved| reserved.* = .{ .key = key, .value = value };
    }
    if (cursor.* >= bytes.len) return Error.MalformedFrame;
    const body = bytes[body_start..cursor.*];
    cursor.* += 1;
    if (open.settle()) |views| return .fromViews(views);
    return neutralStructEntries(.{ .body = body, .elements = elements });
}

/// Read one (String key, Value) pair from a struct body and advance `cursor`. The
/// body was validated at slice time, so a read failure here is `MalformedView`.
fn readStructEntry(bytes: []const u8, cursor: *usize) Error!model.view.StructEntry {
    const key = try syntax.readString(bytes, cursor);
    const value = try readNeutralArgument(null, bytes, cursor, 0);
    return .{ .key = key, .value = value };
}

pub fn readNeutralResolution(slab: *model.view.ValueSlab, bytes: []const u8, cursor: *usize) Error!model.view.Resolution {
    try syntax.readByte(bytes, cursor, '<');
    if (syntax.readKnownLabel(bytes, cursor, "resolve:fulfill")) {
        const argument = try readNeutralArgument(slab, bytes, cursor, 0);
        try syntax.readByte(bytes, cursor, '>');
        return .{ .fulfill = argument };
    }
    if (syntax.readKnownLabel(bytes, cursor, "resolve:break")) {
        const err = try readError(bytes, cursor);
        try syntax.readByte(bytes, cursor, '>');
        return .{ .@"break" = .{ .message = err.message } };
    }
    _ = try syntax.readLabel(bytes, cursor);
    return Error.MalformedFrame;
}

/// Decode a payload/target-position descriptor into a reference in the
/// **receiver's** perspective (ADR-0006 perspective flip, matching Goblins's
/// `incoming-post-unmarshall!`). The flip is a fixed wire-tag
/// relabel, no table lookup, so the codec still owns no authority:
///
/// - `<desc:export N>`, the sender names *our* export, lifts to `.near`.
/// - `<desc:import-object N>` / `<desc:import-promise N>`, the sender names one
///   of *its* exports for us to import, lift to `.far`, preserving the
///   object/promise kind.
/// - `<desc:answer N>` lifts to `.promise`.
///
/// The encoder is the mirror: it writes `near` as `desc:import-object` and `far`
/// as `desc:export`, so a reference sent and echoed back swaps arms, that swap *is* the
/// perspective change, not a round-trip bug.
pub fn readReference(bytes: []const u8, cursor: *usize) Error!ReferenceView {
    try syntax.readByte(bytes, cursor, '<');
    // Each kind has one canonical label, matched as one comparison, a
    // deliver's target first since every call carries one. A label none of
    // them matches is read in full for its verdict.
    inline for (reference_wire_order) |kind| {
        if (syntax.readKnownLabel(bytes, cursor, comptime referenceLabel(kind))) {
            return finishReference(kind, bytes, cursor);
        }
    }
    _ = try syntax.readLabel(bytes, cursor);
    return Error.UnsupportedReference;
}

const ReferenceWire = enum { desc_export, desc_import_object, desc_import_promise, desc_answer };

/// Every reference kind, the ones a call round trip carries first.
const reference_wire_order = [_]ReferenceWire{ .desc_export, .desc_import_object, .desc_answer, .desc_import_promise };

comptime {
    for (@typeInfo(ReferenceWire).@"enum".field_values) |field_value| {
        const kind: ReferenceWire = @fromBackingInt(@intCast(field_value));
        std.debug.assert(std.mem.indexOfScalar(ReferenceWire, &reference_wire_order, kind) != null);
    }
}

fn referenceLabel(comptime kind: ReferenceWire) []const u8 {
    return switch (kind) {
        .desc_export => "desc:export",
        .desc_import_object => "desc:import-object",
        .desc_import_promise => "desc:import-promise",
        .desc_answer => "desc:answer",
    };
}

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

pub fn readOptionalReference(bytes: []const u8, cursor: *usize) Error!?ReferenceView {
    if (cursor.* < bytes.len and bytes[cursor.*] == 'f') {
        cursor.* += 1;
        return null;
    }
    return try readReference(bytes, cursor);
}

fn readError(bytes: []const u8, cursor: *usize) Error!model.BreakReason {
    try syntax.readByte(bytes, cursor, '<');
    try syntax.expectSymbol(bytes, cursor, "error");
    const message = try syntax.readString(bytes, cursor);
    try syntax.readByte(bytes, cursor, '>');
    return .{ .message = message };
}

pub const decodeSignedHandoffGiveOwned = handoff.decodeSignedHandoffGiveOwned;
pub const signedGivePayload = handoff.signedGivePayload;
