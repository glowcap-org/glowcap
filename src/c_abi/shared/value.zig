//! Fixed-layout OCapN values and model projections at the C waist.

const std = @import("std");
const model = @import("model");
const engine = @import("engine");
const result = @import("result.zig");
const last_error = @import("last_error.zig");

const GLOWCAP_ERR_NULL_POINTER = result.GLOWCAP_ERR_NULL_POINTER;
const GLOWCAP_ERR_INVALID_ARGUMENT = result.GLOWCAP_ERR_INVALID_ARGUMENT;
const GLOWCAP_ERR_SESSION = result.GLOWCAP_ERR_SESSION;
const GLOWCAP_ERR_CODEC = result.GLOWCAP_ERR_CODEC;
const GLOWCAP_ERR_INTERNAL = result.GLOWCAP_ERR_INTERNAL;
const GLOWCAP_ERR_UNSUPPORTED_VALUE = result.GLOWCAP_ERR_UNSUPPORTED_VALUE;
const setLastError = last_error.set;

// ── Typed OCapN value vocabulary ─────────────────────────────────────────────
//
// The fixed-layout reference/argument structs and Host marshalling traversal
// live in this leaf so every archive and binding shares one layout. The ocapn root
// (`src/c_abi/ocapn/mod.zig`) re-exports the names so `tools/gen/header/ocapn.zig`'s
// reflection emits them into `glowcap_ocapn.h`; the transport archives include
// that one header on the C side.

pub const GLOWCAP_ARG_INTEGER: u32 = 0;
pub const GLOWCAP_ARG_FLOAT64: u32 = 1;
pub const GLOWCAP_ARG_BOOLEAN: u32 = 2;
pub const GLOWCAP_ARG_BYTES: u32 = 3;
pub const GLOWCAP_ARG_STRING: u32 = 4;
pub const GLOWCAP_ARG_SYMBOL: u32 = 5;
pub const GLOWCAP_ARG_VOID: u32 = 6;
pub const GLOWCAP_ARG_REFERENCE: u32 = 7;
pub const GLOWCAP_ARG_LIST: u32 = 8;
/// A `set` reuses `items`. A `tagged` reuses `bytes` (the tag) and `items` (the
/// value list). A `keyword` reuses `bytes`.
pub const GLOWCAP_ARG_SET: u32 = 9;
pub const GLOWCAP_ARG_TAGGED: u32 = 10;
pub const GLOWCAP_ARG_KEYWORD: u32 = 11;
/// An arbitrary-precision OCapN Integer outside `int64_t`: `bytes`/`bytes_len`
/// carry the canonical decimal magnitude (ASCII digits, no leading zero) and
/// `boolean` carries the sign (1 = negative). A magnitude that fits `int64_t`
/// belongs in `GLOWCAP_ARG_INTEGER` and is refused here.
pub const GLOWCAP_ARG_BIG_INTEGER: u32 = 12;
/// An OCapN Struct. `items` is an even-length sequence of alternating
/// `_STRING` keys and values. Keys must be unique. The alternating tree keeps
/// the C waist recursive without adding a second mutually-recursive ABI type.
pub const GLOWCAP_ARG_STRUCT: u32 = 13;
/// An OCapN Error value. `bytes`/`bytes_len` carry its message. This is a
/// fulfilled value. `GLOWCAP_RESOLUTION_BREAK` remains the rejected outcome.
pub const GLOWCAP_ARG_ERROR: u32 = 14;
/// A list of integers lent as one leaf (ADR-0247): `bytes` points at the
/// first `int64_t` in host byte order, 8-aligned, and `bytes_len` is the
/// byte length, a multiple of 8. It means the same value as a `_LIST` of
/// `_INTEGER` elements and encodes to the same bytes. A received list of
/// integers arrives as a `_LIST`.
pub const GLOWCAP_ARG_INTEGERS: u32 = 15;

pub const GLOWCAP_RESOLUTION_FULFILL: u32 = 0;
pub const GLOWCAP_RESOLUTION_BREAK: u32 = 1;
/// The answer fulfilled to a three-party handoff (ADR-0009/ADR-0100): the
/// resolution carries a `desc:handoff-give` the recipient must redeem against
/// the named exporter rather than an immediate value. `GlowcapResolve.handoff`
/// carries the verbatim give and the exporter's dialable locator.
pub const GLOWCAP_RESOLUTION_HANDOFF: u32 = 2;

/// An opaque capability identity owned by one `GlowcapHost`. The integer has no
/// wire meaning and cannot be combined with a caller-selected session. Equal
/// ids name the same Host capability. The C issuer keeps ids distinct across
/// Hosts and never reuses a retired id.
pub const GlowcapReference = extern struct {
    id: u64,
};

/// A passable argument value. `kind` selects which field is live. `bytes`/
/// `bytes_len` carry `_BYTES`/`_STRING`/`_SYMBOL`/`_KEYWORD`/`_ERROR`. `items`/
/// `items_len` carry a `_LIST`'s or `_SET`'s elements. A `_TAGGED` uses both:
/// the tag in `bytes`/`bytes_len` and the value list in `items`/`items_len`.
/// A `_BIG_INTEGER` carries the canonical decimal magnitude in `bytes`/
/// `bytes_len` (ASCII digits, no leading zero) and the sign in `boolean`
/// (1 = negative). A magnitude that fits `int64_t` belongs in `_INTEGER` and
/// is refused here. An `_ERROR` is a fulfilled OCapN Error value whose bytes
/// are its message. It is distinct from a rejected resolution. A `_STRUCT`
/// carries alternating `_STRING` key/value
/// children in `items`. Its count is therefore always even. An `_INTEGERS`
/// carries `int64_t` words behind `bytes`/`bytes_len`. On a projected
/// (received) value the pointers alias the
/// owning arena and are valid until the matching `*_release`.
pub const GlowcapArgument = extern struct {
    kind: u32,
    boolean: u32,
    integer: i64,
    float64: f64,
    bytes: ?[*]const u8,
    bytes_len: usize,
    reference: GlowcapReference,
    items: ?[*]const GlowcapArgument,
    items_len: usize,
};

pub const zero_reference: GlowcapReference = .{ .id = 0 };
pub const zero_argument: GlowcapArgument = .{
    .kind = GLOWCAP_ARG_VOID,
    .boolean = 0,
    .integer = 0,
    .float64 = 0,
    .bytes = null,
    .bytes_len = 0,
    .reference = zero_reference,
    .items = null,
    .items_len = 0,
};

/// `InvalidArgument` is this leaf's own refusal of a caller-supplied
/// discriminant outside its family. It always arrives with a last-error message
/// naming the offending value, so a mapper above must not stamp the bare error
/// name over it. The other members are a shape the marshal cannot carry
/// (`UnsupportedValue`), a missing pointer, and allocation failure.
pub const MarshalError = error{ UnsupportedValue, InvalidArgument, NullPointer, OutOfMemory };

/// Classify an inbound-dispatch error into a C ABI return code. Derived from the
/// single error taxonomy (`engine.abort_projection.classify`) so the C codes
/// cannot drift from the abort projection. It is defined once here so no two
/// archives can disagree on the same error: codec/decode malformations report
/// `CODEC`, session state-machine refusals (a partner protocol violation, a
/// resource cap, an already-closed session) report `SESSION`, and host-internal
/// failures (allocation, …) report `INTERNAL`.
pub fn feedErrorToCode(err: anyerror) i32 {
    return switch (engine.abort_projection.classify(err).domain) {
        .codec => GLOWCAP_ERR_CODEC,
        .session => GLOWCAP_ERR_SESSION,
        .foreign => GLOWCAP_ERR_INTERNAL,
    };
}

pub fn marshalErrorToCode(err: MarshalError) i32 {
    setLastError("C argument: {s}", .{@errorName(err)});
    return switch (err) {
        error.UnsupportedValue => GLOWCAP_ERR_UNSUPPORTED_VALUE,
        error.InvalidArgument => GLOWCAP_ERR_INVALID_ARGUMENT,
        error.NullPointer => GLOWCAP_ERR_NULL_POINTER,
        error.OutOfMemory => GLOWCAP_ERR_INTERNAL,
    };
}

/// `GlowcapLastAbort.domain`: which layer classified the failure. Codec is a
/// decode/encode malformation, session is a state-machine refusal, foreign is
/// a host-internal failure (allocation, …).
pub const GLOWCAP_ABORT_DOMAIN_CODEC: u32 = 0;
pub const GLOWCAP_ABORT_DOMAIN_SESSION: u32 = 1;
pub const GLOWCAP_ABORT_DOMAIN_FOREIGN: u32 = 2;

/// The typed cause of a peer's most recent local dispatch failure, projected
/// to C, the ABI counterpart of `engine.Peer.lastAbort`. `domain` is a
/// `GLOWCAP_ABORT_DOMAIN_*` value. When `has_kind` is nonzero, `kind_name`
/// is the wire name of the projected `op:abort` kind (e.g. "MalformedFrame").
/// When zero, the failure projected no abort (a closed session, an allocation
/// failure). All byte views are process-static. Read them and never free them.
/// Declared in this leaf so the ocapn peer family and the byte-fed driver
/// family (`glowcap_host_session_last_abort`) share it by layout.
pub const GlowcapLastAbort = extern struct {
    domain: u32,
    has_kind: u32,
    kind_name: ?[*]const u8,
    kind_name_len: usize,
    message: ?[*]const u8,
    message_len: usize,
    error_name: ?[*]const u8,
    error_name_len: usize,
    abort_delivery_error_name: ?[*]const u8,
    abort_delivery_error_name_len: usize,
    /// Process-static name of the first cleanup or consequence failure.
    secondary_error_name: ?[*]const u8,
    /// Length of `secondary_error_name`.
    secondary_error_name_len: usize,
    /// Secondary failures observed. 255 means 255 or more.
    secondary_error_count: u32,
};

/// Project an `engine.AbortInfo` into the C `GlowcapLastAbort`. Every view
/// written is process-static.
pub fn lastAbortToC(info: engine.AbortInfo) GlowcapLastAbort {
    const abort_delivery_error_name = if (info.abort_delivery_error) |err| @errorName(err) else null;
    const secondary_error_name = if (info.secondary_error) |err| @errorName(err) else null;
    return .{
        .domain = switch (info.domain) {
            .codec => GLOWCAP_ABORT_DOMAIN_CODEC,
            .session => GLOWCAP_ABORT_DOMAIN_SESSION,
            .foreign => GLOWCAP_ABORT_DOMAIN_FOREIGN,
        },
        .has_kind = if (info.kind != null) 1 else 0,
        .kind_name = if (info.kind) |k| k.wireName().ptr else null,
        .kind_name_len = if (info.kind) |k| k.wireName().len else 0,
        .message = info.message.ptr,
        .message_len = info.message.len,
        .error_name = info.error_name.ptr,
        .error_name_len = info.error_name.len,
        .abort_delivery_error_name = if (abort_delivery_error_name) |name| name.ptr else null,
        .abort_delivery_error_name_len = if (abort_delivery_error_name) |name| name.len else 0,
        .secondary_error_name = if (secondary_error_name) |name| name.ptr else null,
        .secondary_error_name_len = if (secondary_error_name) |name| name.len else 0,
        .secondary_error_count = @intCast(info.secondary_error_count),
    };
}

/// A borrowed view of `len` items at `ptr`. An empty view needs no pointer,
/// and a null pointer under a nonzero length is refused.
pub fn itemsFromC(comptime T: type, ptr: ?[*]const T, len: usize) error{NullPointer}![]const T {
    if (len == 0) return &.{};
    return (ptr orelse return error.NullPointer)[0..len];
}

pub fn sliceFromC(ptr: ?[*]const u8, len: usize) error{NullPointer}![]const u8 {
    return itemsFromC(u8, ptr, len);
}

/// Depth bound on a host-supplied argument tree. A foreign caller could nest
/// `GlowcapArgument` lists/sets/tagged values arbitrarily deep and overflow the
/// Zig stack inside `argumentFromCWith`, exactly as an untrusted wire frame could in
/// the codec. Derived from the session's default `max_nesting_depth`, so the
/// marshal boundary and the codec refuse at the same depth by construction.
pub const max_marshal_depth: usize = (engine.SessionLimits{}).max_nesting_depth;

/// One recursive C-value decoder parameterized only by the reference leaf.
/// The Host supplies opaque-id lift/lower policy without cloning the
/// pass-by-copy value algebra.
pub fn argumentFromCWith(
    comptime RefError: type,
    ref_ctx: anytype,
    comptime ref_from_c: anytype,
    arena: std.mem.Allocator,
    c_arg: GlowcapArgument,
    depth: usize,
    comptime own_bytes: bool,
) (MarshalError || RefError)!model.Argument {
    return valueFromCImpl(model.Argument, .reference, RefError, ref_ctx, ref_from_c, arena, c_arg, depth, own_bytes);
}

const ReferenceField = enum { reference, capability };

/// The one conversion recursion behind both marshal lifetimes and both
/// application value forms. `Output` is either `model.Argument` or the
/// Host's isomorphic opaque-capability value. `own_bytes` and the
/// reference field are comptime, so every projection remains straight-line.
fn valueFromCImpl(
    comptime Output: type,
    comptime reference_field: ReferenceField,
    comptime RefError: type,
    ref_ctx: anytype,
    comptime ref_from_c: anytype,
    arena: std.mem.Allocator,
    c_arg: GlowcapArgument,
    depth: usize,
    comptime own_bytes: bool,
) (MarshalError || RefError)!Output {
    if (depth > max_marshal_depth) return error.UnsupportedValue;
    const next = depth + 1;
    return switch (c_arg.kind) {
        GLOWCAP_ARG_INTEGER => .{ .integer = c_arg.integer },
        GLOWCAP_ARG_FLOAT64 => .{ .float64 = c_arg.float64 },
        GLOWCAP_ARG_BOOLEAN => .{ .boolean = c_arg.boolean != 0 },
        GLOWCAP_ARG_BYTES => .{ .bytes = try leafFromC(arena, c_arg, own_bytes) },
        GLOWCAP_ARG_STRING => .{ .string = try leafFromC(arena, c_arg, own_bytes) },
        GLOWCAP_ARG_SYMBOL => .{ .symbol = try leafFromC(arena, c_arg, own_bytes) },
        GLOWCAP_ARG_ERROR => .{ .@"error" = .{ .message = try leafFromC(arena, c_arg, own_bytes) } },
        GLOWCAP_ARG_VOID => .{ .void = {} },
        GLOWCAP_ARG_REFERENCE => switch (reference_field) {
            .reference => .{ .reference = try ref_from_c(ref_ctx, c_arg.reference) },
            .capability => .{ .capability = try ref_from_c(ref_ctx, c_arg.reference) },
        },
        GLOWCAP_ARG_LIST => .{ .list = try valuesFromCImpl(Output, reference_field, RefError, ref_ctx, ref_from_c, arena, c_arg.items, c_arg.items_len, next, own_bytes) },
        GLOWCAP_ARG_SET => .{ .set = try valuesFromCImpl(Output, reference_field, RefError, ref_ctx, ref_from_c, arena, c_arg.items, c_arg.items_len, next, own_bytes) },
        GLOWCAP_ARG_TAGGED => .{ .tagged = .{
            .tag = try leafFromC(arena, c_arg, own_bytes),
            .value = try valuesFromCImpl(Output, reference_field, RefError, ref_ctx, ref_from_c, arena, c_arg.items, c_arg.items_len, next, own_bytes),
        } },
        GLOWCAP_ARG_KEYWORD => .{ .keyword = try leafFromC(arena, c_arg, own_bytes) },
        GLOWCAP_ARG_BIG_INTEGER => blk: {
            const big = model.BigInteger{
                .negative = c_arg.boolean != 0,
                .digits = try leafFromC(arena, c_arg, own_bytes),
            };
            // Fail closed at the boundary, like the codecs: leading zeros,
            // non-digits, or a magnitude that belongs in GLOWCAP_ARG_INTEGER.
            if (!big.isCanonical()) break :blk error.UnsupportedValue;
            break :blk .{ .big_integer = big };
        },
        GLOWCAP_ARG_INTEGERS => blk: {
            if (c_arg.bytes_len != 0 and depth == max_marshal_depth) return error.UnsupportedValue;
            const words = try integersFromC(arena, c_arg, own_bytes);
            if (comptime @hasField(Output, "integers")) break :blk .{ .integers = words };
            // The model has no run arm: the words become the list they mean.
            const items = try arena.alloc(Output, words.len);
            for (words, items) |word, *item| item.* = .{ .integer = word };
            break :blk .{ .list = items };
        },
        GLOWCAP_ARG_STRUCT => .{ .@"struct" = try structFromCImpl(
            Output,
            reference_field,
            RefError,
            ref_ctx,
            ref_from_c,
            arena,
            c_arg.items,
            c_arg.items_len,
            next,
            own_bytes,
        ) },
        else => error.UnsupportedValue,
    };
}

/// The `int64_t` words behind an `_INTEGERS` value, 8-aligned and a whole
/// number of words, or the value is refused before anything is queued.
fn integersFromC(arena: std.mem.Allocator, c_arg: GlowcapArgument, comptime own_bytes: bool) MarshalError![]const i64 {
    const bytes = try sliceFromC(c_arg.bytes, c_arg.bytes_len);
    if (bytes.len % model.run_word_bytes != 0) return error.UnsupportedValue;
    if (bytes.len == 0) return &.{};
    if (!std.mem.isAligned(@intFromPtr(bytes.ptr), 8)) return error.UnsupportedValue;
    const aligned: []align(@alignOf(i64)) const u8 = @alignCast(bytes);
    const words = std.mem.bytesAsSlice(i64, aligned);
    return if (own_bytes) try arena.dupe(i64, words) else words;
}

fn structFromCImpl(
    comptime Output: type,
    comptime reference_field: ReferenceField,
    comptime RefError: type,
    ref_ctx: anytype,
    comptime ref_from_c: anytype,
    arena: std.mem.Allocator,
    items: ?[*]const GlowcapArgument,
    len: usize,
    depth: usize,
    comptime own_bytes: bool,
) (MarshalError || RefError)![]const std.meta.Child(@FieldType(Output, "struct")) {
    if (len % 2 != 0) return error.UnsupportedValue;
    if (len == 0) return &.{};
    const p = items orelse return error.NullPointer;
    const Entry = std.meta.Child(@FieldType(Output, "struct"));
    const out = try arena.alloc(Entry, len / 2);
    for (out, 0..) |*entry, i| {
        const key_arg = p[i * 2];
        if (key_arg.kind != GLOWCAP_ARG_STRING) return error.UnsupportedValue;
        const key = try leafFromC(arena, key_arg, own_bytes);
        for (out[0..i]) |prior| {
            if (std.mem.eql(u8, prior.key, key)) return error.UnsupportedValue;
        }
        entry.* = .{
            .key = key,
            .value = try valueFromCImpl(
                Output,
                reference_field,
                RefError,
                ref_ctx,
                ref_from_c,
                arena,
                p[i * 2 + 1],
                depth,
                own_bytes,
            ),
        };
    }
    return out;
}

/// A leaf's byte slice: borrowed from the C argument, or duped into `arena`
/// when the caller asked for owned bytes.
fn leafFromC(arena: std.mem.Allocator, c_arg: GlowcapArgument, comptime own_bytes: bool) MarshalError![]const u8 {
    const borrowed = try sliceFromC(c_arg.bytes, c_arg.bytes_len);
    return if (own_bytes) try arena.dupe(u8, borrowed) else borrowed;
}

pub fn argsFromCWith(
    comptime RefError: type,
    ref_ctx: anytype,
    comptime ref_from_c: anytype,
    arena: std.mem.Allocator,
    items: ?[*]const GlowcapArgument,
    len: usize,
    depth: usize,
    comptime own_bytes: bool,
) (MarshalError || RefError)![]const model.Argument {
    return valuesFromCImpl(model.Argument, .reference, RefError, ref_ctx, ref_from_c, arena, items, len, depth, own_bytes);
}

/// Decode the same C value algebra into the Host's opaque-capability
/// value without first manufacturing wire references. `Value` must carry the
/// data arms accepted above plus a `capability` arm of the callback's payload.
pub fn valuesFromCWith(
    comptime Value: type,
    comptime RefError: type,
    ref_ctx: anytype,
    comptime ref_from_c: anytype,
    arena: std.mem.Allocator,
    items: ?[*]const GlowcapArgument,
    len: usize,
    depth: usize,
    comptime own_bytes: bool,
) (MarshalError || RefError)![]const Value {
    return valuesFromCImpl(Value, .capability, RefError, ref_ctx, ref_from_c, arena, items, len, depth, own_bytes);
}

fn valuesFromCImpl(
    comptime Output: type,
    comptime reference_field: ReferenceField,
    comptime RefError: type,
    ref_ctx: anytype,
    comptime ref_from_c: anytype,
    arena: std.mem.Allocator,
    items: ?[*]const GlowcapArgument,
    len: usize,
    depth: usize,
    comptime own_bytes: bool,
) (MarshalError || RefError)![]const Output {
    if (len == 0) return &.{};
    const p = items orelse return error.NullPointer;
    const out = try arena.alloc(Output, len);
    for (0..len) |i| out[i] = try valueFromCImpl(Output, reference_field, RefError, ref_ctx, ref_from_c, arena, p[i], depth, own_bytes);
    return out;
}

/// One recursive C-value encoder parameterized only by the reference leaf,
/// the mirror of `argumentFromCWith`: the archive supplies the reference
/// projection without cloning the pass-by-copy value algebra. Children land
/// in `arena`, and byte leaves are lent where they lie.
pub fn argumentToCWith(
    comptime RefError: type,
    ref_ctx: anytype,
    comptime ref_to_c: anytype,
    arena: std.mem.Allocator,
    arg: model.Argument,
) (MarshalError || RefError)!GlowcapArgument {
    return valueToCImpl(model.Argument, RefError, ref_ctx, ref_to_c, arena, arg);
}

pub fn argsToCWith(
    comptime RefError: type,
    ref_ctx: anytype,
    comptime ref_to_c: anytype,
    arena: std.mem.Allocator,
    args: []const model.Argument,
) (MarshalError || RefError)![]GlowcapArgument {
    return valuesToCImpl(model.Argument, RefError, ref_ctx, ref_to_c, arena, args);
}

/// Encode the Host's opaque-capability value, the mirror of `valuesFromCWith`.
/// `Value` carries the data arms above, a `capability` arm the callback
/// projects, and an `integers` run that leaves as one `_INTEGERS` value with
/// its words lent where they lie (ADR-0247).
pub fn valueToCWith(
    comptime Value: type,
    comptime RefError: type,
    ref_ctx: anytype,
    comptime ref_to_c: anytype,
    arena: std.mem.Allocator,
    value: Value,
) (MarshalError || RefError)!GlowcapArgument {
    return valueToCImpl(Value, RefError, ref_ctx, ref_to_c, arena, value);
}

pub fn valuesToCWith(
    comptime Value: type,
    comptime RefError: type,
    ref_ctx: anytype,
    comptime ref_to_c: anytype,
    arena: std.mem.Allocator,
    values: []const Value,
) (MarshalError || RefError)![]GlowcapArgument {
    return valuesToCImpl(Value, RefError, ref_ctx, ref_to_c, arena, values);
}

/// The one encoding recursion behind both application value forms. The data
/// arms are spelled once; the arms whose C form depends on `Input` are
/// resolved at compile time below them, and an arm neither names stops the
/// build at this boundary, which must decide how (or whether) the typed
/// surface carries it, instead of degrading silently to the opaque-frame
/// fallback.
fn valueToCImpl(
    comptime Input: type,
    comptime RefError: type,
    ref_ctx: anytype,
    comptime ref_to_c: anytype,
    arena: std.mem.Allocator,
    value: Input,
) (MarshalError || RefError)!GlowcapArgument {
    var c_arg = zero_argument;
    switch (value) {
        .integer => |v| {
            c_arg.kind = GLOWCAP_ARG_INTEGER;
            c_arg.integer = v;
        },
        .float64 => |v| {
            c_arg.kind = GLOWCAP_ARG_FLOAT64;
            c_arg.float64 = v;
        },
        .boolean => |v| {
            c_arg.kind = GLOWCAP_ARG_BOOLEAN;
            c_arg.boolean = @intFromBool(v);
        },
        .bytes => |b| c_arg = leafToC(GLOWCAP_ARG_BYTES, b),
        .string => |b| c_arg = leafToC(GLOWCAP_ARG_STRING, b),
        .symbol => |b| c_arg = leafToC(GLOWCAP_ARG_SYMBOL, b),
        .keyword => |b| c_arg = leafToC(GLOWCAP_ARG_KEYWORD, b),
        .@"error" => |reason| c_arg = leafToC(GLOWCAP_ARG_ERROR, reason.message),
        .void => c_arg.kind = GLOWCAP_ARG_VOID,
        .list => |items| {
            c_arg.kind = GLOWCAP_ARG_LIST;
            setItems(&c_arg, try valuesToCImpl(Input, RefError, ref_ctx, ref_to_c, arena, items));
        },
        .set => |items| {
            c_arg.kind = GLOWCAP_ARG_SET;
            setItems(&c_arg, try valuesToCImpl(Input, RefError, ref_ctx, ref_to_c, arena, items));
        },
        .tagged => |tagged| {
            c_arg = leafToC(GLOWCAP_ARG_TAGGED, tagged.tag);
            setItems(&c_arg, try valuesToCImpl(Input, RefError, ref_ctx, ref_to_c, arena, tagged.value));
        },
        .big_integer => |big| {
            c_arg = leafToC(GLOWCAP_ARG_BIG_INTEGER, big.digits);
            c_arg.boolean = @intFromBool(big.negative);
        },
        .@"struct" => |entries| {
            c_arg.kind = GLOWCAP_ARG_STRUCT;
            const arr = try arena.alloc(GlowcapArgument, entries.len * 2);
            for (entries, 0..) |entry, i| {
                arr[i * 2] = leafToC(GLOWCAP_ARG_STRING, entry.key);
                arr[i * 2 + 1] = try valueToCImpl(Input, RefError, ref_ctx, ref_to_c, arena, entry.value);
            }
            setItems(&c_arg, arr);
        },
        inline else => |payload, tag| {
            const name = @tagName(tag);
            if (comptime std.mem.eql(u8, name, "reference") or std.mem.eql(u8, name, "capability")) {
                c_arg.kind = GLOWCAP_ARG_REFERENCE;
                c_arg.reference = try ref_to_c(ref_ctx, payload);
            } else if (comptime std.mem.eql(u8, name, "integers")) {
                c_arg = leafToC(GLOWCAP_ARG_INTEGERS, std.mem.sliceAsBytes(payload));
            } else if (comptime std.mem.eql(u8, name, "handoff")) {
                return error.UnsupportedValue;
            } else {
                @compileError("no C form for " ++ @typeName(Input) ++ "." ++ name);
            }
        },
    }
    return c_arg;
}

fn valuesToCImpl(
    comptime Input: type,
    comptime RefError: type,
    ref_ctx: anytype,
    comptime ref_to_c: anytype,
    arena: std.mem.Allocator,
    values: []const Input,
) (MarshalError || RefError)![]GlowcapArgument {
    const out = try arena.alloc(GlowcapArgument, values.len);
    for (values, out) |value, *slot| slot.* = try valueToCImpl(Input, RefError, ref_ctx, ref_to_c, arena, value);
    return out;
}

/// A value whose payload is one byte view, lent where it lies.
fn leafToC(kind: u32, bytes: []const u8) GlowcapArgument {
    var c_arg = zero_argument;
    c_arg.kind = kind;
    c_arg.bytes = bytes.ptr;
    c_arg.bytes_len = bytes.len;
    return c_arg;
}

fn setItems(c_arg: *GlowcapArgument, items: []GlowcapArgument) void {
    c_arg.items = items.ptr;
    c_arg.items_len = items.len;
}
