//! Fixed-layout OCapN values and model projections at the C waist.

const std = @import("std");
const model = @import("model");
const engine = @import("engine");
const result = @import("result.zig");
const last_error = @import("last_error.zig");

const PANCAKE_ERR_NULL_POINTER = result.PANCAKE_ERR_NULL_POINTER;
const PANCAKE_ERR_INVALID_ARGUMENT = result.PANCAKE_ERR_INVALID_ARGUMENT;
const PANCAKE_ERR_SESSION = result.PANCAKE_ERR_SESSION;
const PANCAKE_ERR_CODEC = result.PANCAKE_ERR_CODEC;
const PANCAKE_ERR_INTERNAL = result.PANCAKE_ERR_INTERNAL;
const PANCAKE_ERR_UNSUPPORTED_VALUE = result.PANCAKE_ERR_UNSUPPORTED_VALUE;
const setLastError = last_error.set;

// ── Typed OCapN value vocabulary ─────────────────────────────────────────────
//
// The fixed-layout reference/argument structs and Host marshalling traversal
// live in this leaf so every archive and binding shares one layout. The ocapn root
// (`src/c_abi/ocapn/mod.zig`) re-exports the names so `tools/gen/header/ocapn.zig`'s
// reflection emits them into `pancake_ocapn.h`; the transport archives include
// that one header on the C side.

pub const PANCAKE_ARG_INTEGER: u32 = 0;
pub const PANCAKE_ARG_FLOAT64: u32 = 1;
pub const PANCAKE_ARG_BOOLEAN: u32 = 2;
pub const PANCAKE_ARG_BYTES: u32 = 3;
pub const PANCAKE_ARG_STRING: u32 = 4;
pub const PANCAKE_ARG_SYMBOL: u32 = 5;
pub const PANCAKE_ARG_VOID: u32 = 6;
pub const PANCAKE_ARG_REFERENCE: u32 = 7;
pub const PANCAKE_ARG_LIST: u32 = 8;
/// A `set` reuses `items`; a `tagged` reuses `bytes` (the tag) and `items` (the
/// value list); a `keyword` reuses `bytes`.
pub const PANCAKE_ARG_SET: u32 = 9;
pub const PANCAKE_ARG_TAGGED: u32 = 10;
pub const PANCAKE_ARG_KEYWORD: u32 = 11;
/// An arbitrary-precision OCapN Integer outside `int64_t`: `bytes`/`bytes_len`
/// carry the canonical decimal magnitude (ASCII digits, no leading zero) and
/// `boolean` carries the sign (1 = negative). A magnitude that fits `int64_t`
/// belongs in `PANCAKE_ARG_INTEGER` and is refused here.
pub const PANCAKE_ARG_BIG_INTEGER: u32 = 12;
/// An OCapN Struct. `items` is an even-length sequence of alternating
/// `_STRING` keys and values. Keys must be unique. The alternating tree keeps
/// the C waist recursive without adding a second mutually-recursive ABI type.
pub const PANCAKE_ARG_STRUCT: u32 = 13;
/// An OCapN Error value. `bytes`/`bytes_len` carry its message. This is a
/// fulfilled value; `PANCAKE_RESOLUTION_BREAK` remains the rejected outcome.
pub const PANCAKE_ARG_ERROR: u32 = 14;

pub const PANCAKE_RESOLUTION_FULFILL: u32 = 0;
pub const PANCAKE_RESOLUTION_BREAK: u32 = 1;
/// The answer fulfilled to a three-party handoff (ADR-0009/ADR-0100): the
/// resolution carries a `desc:handoff-give` the recipient must redeem against
/// the named exporter rather than an immediate value. `PancakeResolve.handoff`
/// carries the verbatim give and the exporter's dialable locator.
pub const PANCAKE_RESOLUTION_HANDOFF: u32 = 2;

/// An opaque capability identity owned by one `PancakeHost`. The integer has no
/// wire meaning and cannot be combined with a caller-selected session. Equal
/// ids name the same Host capability; the C issuer keeps ids distinct across
/// Hosts and never reuses a retired id.
pub const PancakeReference = extern struct {
    id: u64,
};

/// A passable argument value. `kind` selects which field is live. `bytes`/
/// `bytes_len` carry `_BYTES`/`_STRING`/`_SYMBOL`/`_KEYWORD`/`_ERROR`; `items`/
/// `items_len` carry a `_LIST`'s or `_SET`'s elements. A `_TAGGED` uses both:
/// the tag in `bytes`/`bytes_len` and the value list in `items`/`items_len`.
/// A `_BIG_INTEGER` carries the canonical decimal magnitude in `bytes`/
/// `bytes_len` (ASCII digits, no leading zero) and the sign in `boolean`
/// (1 = negative); a magnitude that fits `int64_t` belongs in `_INTEGER` and
/// is refused here. An `_ERROR` is a fulfilled OCapN Error value whose bytes
/// are its message; it is distinct from a rejected resolution. A `_STRUCT`
/// carries alternating `_STRING` key/value
/// children in `items`; its count is therefore always even. On a projected
/// (received) value the pointers alias the
/// owning arena and are valid until the matching `*_release`.
pub const PancakeArgument = extern struct {
    kind: u32,
    boolean: u32,
    integer: i64,
    float64: f64,
    bytes: ?[*]const u8,
    bytes_len: usize,
    reference: PancakeReference,
    items: ?[*]const PancakeArgument,
    items_len: usize,
};

pub const zero_reference: PancakeReference = .{ .id = 0 };
pub const zero_argument: PancakeArgument = .{
    .kind = PANCAKE_ARG_VOID,
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
/// cannot drift from the abort projection — and defined once here so no two
/// archives can disagree on the same error: codec/decode malformations report
/// `CODEC`, session state-machine refusals (a partner protocol violation, a
/// resource cap, an already-closed session) report `SESSION`, and host-internal
/// failures (allocation, …) report `INTERNAL`.
pub fn feedErrorToCode(err: anyerror) i32 {
    return switch (engine.abort_projection.classify(err).domain) {
        .codec => PANCAKE_ERR_CODEC,
        .session => PANCAKE_ERR_SESSION,
        .foreign => PANCAKE_ERR_INTERNAL,
    };
}

pub fn marshalErrorToCode(err: MarshalError) i32 {
    setLastError("C argument: {s}", .{@errorName(err)});
    return switch (err) {
        error.UnsupportedValue => PANCAKE_ERR_UNSUPPORTED_VALUE,
        error.InvalidArgument => PANCAKE_ERR_INVALID_ARGUMENT,
        error.NullPointer => PANCAKE_ERR_NULL_POINTER,
        error.OutOfMemory => PANCAKE_ERR_INTERNAL,
    };
}

/// `PancakeLastAbort.domain`: which layer classified the failure. Codec is a
/// decode/encode malformation, session is a state-machine refusal, foreign is
/// a host-internal failure (allocation, …).
pub const PANCAKE_ABORT_DOMAIN_CODEC: u32 = 0;
pub const PANCAKE_ABORT_DOMAIN_SESSION: u32 = 1;
pub const PANCAKE_ABORT_DOMAIN_FOREIGN: u32 = 2;

/// The typed cause of a peer's most recent local dispatch failure, projected
/// to C — the ABI counterpart of `engine.Peer.lastAbort`. `domain` is a
/// `PANCAKE_ABORT_DOMAIN_*` value. When `has_kind` is nonzero, `kind_name`
/// is the wire name of the projected `op:abort` kind (e.g. "MalformedFrame");
/// when zero, the failure projected no abort (a closed session, an allocation
/// failure). All byte views are process-static — read them, never free them.
/// Declared in this leaf so the ocapn peer family and the byte-fed driver
/// family (`pancake_host_session_last_abort`) share it by layout.
pub const PancakeLastAbort = extern struct {
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
    /// Secondary failures observed; 255 means 255 or more.
    secondary_error_count: u32,
};

/// Project an `engine.AbortInfo` into the C `PancakeLastAbort`. Every view
/// written is process-static.
pub fn lastAbortToC(info: engine.AbortInfo) PancakeLastAbort {
    const abort_delivery_error_name = if (info.abort_delivery_error) |err| @errorName(err) else null;
    const secondary_error_name = if (info.secondary_error) |err| @errorName(err) else null;
    return .{
        .domain = switch (info.domain) {
            .codec => PANCAKE_ABORT_DOMAIN_CODEC,
            .session => PANCAKE_ABORT_DOMAIN_SESSION,
            .foreign => PANCAKE_ABORT_DOMAIN_FOREIGN,
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

pub fn sliceFromC(ptr: ?[*]const u8, len: usize) MarshalError![]const u8 {
    if (len == 0) return &.{};
    const p = ptr orelse return error.NullPointer;
    return p[0..len];
}

/// Depth bound on a host-supplied argument tree. A foreign caller could nest
/// `PancakeArgument` lists/sets/tagged values arbitrarily deep and overflow the
/// native stack inside `argumentFromC`, exactly as a hostile wire frame could in
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
    c_arg: PancakeArgument,
    depth: usize,
    comptime own_bytes: bool,
) (MarshalError || RefError)!model.Argument {
    return valueFromCImpl(model.Argument, .reference, RefError, ref_ctx, ref_from_c, arena, c_arg, depth, own_bytes);
}

const ReferenceField = enum { reference, capability };

/// The one conversion recursion behind both marshal lifetimes and both
/// application value spellings. `Output` is either `model.Argument` or an
/// owning tier's isomorphic opaque-capability value. `own_bytes` and the
/// reference field are comptime, so every projection remains straight-line.
fn valueFromCImpl(
    comptime Output: type,
    comptime reference_field: ReferenceField,
    comptime RefError: type,
    ref_ctx: anytype,
    comptime ref_from_c: anytype,
    arena: std.mem.Allocator,
    c_arg: PancakeArgument,
    depth: usize,
    comptime own_bytes: bool,
) (MarshalError || RefError)!Output {
    if (depth > max_marshal_depth) return error.UnsupportedValue;
    const next = depth + 1;
    return switch (c_arg.kind) {
        PANCAKE_ARG_INTEGER => .{ .integer = c_arg.integer },
        PANCAKE_ARG_FLOAT64 => .{ .float64 = c_arg.float64 },
        PANCAKE_ARG_BOOLEAN => .{ .boolean = c_arg.boolean != 0 },
        PANCAKE_ARG_BYTES => .{ .bytes = try leafFromC(arena, c_arg, own_bytes) },
        PANCAKE_ARG_STRING => .{ .string = try leafFromC(arena, c_arg, own_bytes) },
        PANCAKE_ARG_SYMBOL => .{ .symbol = try leafFromC(arena, c_arg, own_bytes) },
        PANCAKE_ARG_ERROR => .{ .@"error" = .{ .message = try leafFromC(arena, c_arg, own_bytes) } },
        PANCAKE_ARG_VOID => .{ .void = {} },
        PANCAKE_ARG_REFERENCE => switch (reference_field) {
            .reference => .{ .reference = try ref_from_c(ref_ctx, c_arg.reference) },
            .capability => .{ .capability = try ref_from_c(ref_ctx, c_arg.reference) },
        },
        PANCAKE_ARG_LIST => .{ .list = try valuesFromCImpl(Output, reference_field, RefError, ref_ctx, ref_from_c, arena, c_arg.items, c_arg.items_len, next, own_bytes) },
        PANCAKE_ARG_SET => .{ .set = try valuesFromCImpl(Output, reference_field, RefError, ref_ctx, ref_from_c, arena, c_arg.items, c_arg.items_len, next, own_bytes) },
        PANCAKE_ARG_TAGGED => .{ .tagged = .{
            .tag = try leafFromC(arena, c_arg, own_bytes),
            .value = try valuesFromCImpl(Output, reference_field, RefError, ref_ctx, ref_from_c, arena, c_arg.items, c_arg.items_len, next, own_bytes),
        } },
        PANCAKE_ARG_KEYWORD => .{ .keyword = try leafFromC(arena, c_arg, own_bytes) },
        PANCAKE_ARG_BIG_INTEGER => blk: {
            const big = model.BigInteger{
                .negative = c_arg.boolean != 0,
                .digits = try leafFromC(arena, c_arg, own_bytes),
            };
            // Fail closed at the boundary, like the codecs: leading zeros,
            // non-digits, or a magnitude that belongs in PANCAKE_ARG_INTEGER.
            if (!big.isCanonical()) break :blk error.UnsupportedValue;
            break :blk .{ .big_integer = big };
        },
        PANCAKE_ARG_STRUCT => .{ .@"struct" = try structFromCImpl(
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

fn structFromCImpl(
    comptime Output: type,
    comptime reference_field: ReferenceField,
    comptime RefError: type,
    ref_ctx: anytype,
    comptime ref_from_c: anytype,
    arena: std.mem.Allocator,
    items: ?[*]const PancakeArgument,
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
        if (key_arg.kind != PANCAKE_ARG_STRING) return error.UnsupportedValue;
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
fn leafFromC(arena: std.mem.Allocator, c_arg: PancakeArgument, comptime own_bytes: bool) MarshalError![]const u8 {
    const borrowed = try sliceFromC(c_arg.bytes, c_arg.bytes_len);
    return if (own_bytes) try arena.dupe(u8, borrowed) else borrowed;
}

pub fn argsFromCWith(
    comptime RefError: type,
    ref_ctx: anytype,
    comptime ref_from_c: anytype,
    arena: std.mem.Allocator,
    items: ?[*]const PancakeArgument,
    len: usize,
    depth: usize,
    comptime own_bytes: bool,
) (MarshalError || RefError)![]const model.Argument {
    return valuesFromCImpl(model.Argument, .reference, RefError, ref_ctx, ref_from_c, arena, items, len, depth, own_bytes);
}

/// Decode the same C value algebra into an owning tier's opaque-capability
/// value without first manufacturing wire references. `Value` must carry the
/// data arms accepted above plus a `capability` arm of the callback's payload.
pub fn valuesFromCWith(
    comptime Value: type,
    comptime RefError: type,
    ref_ctx: anytype,
    comptime ref_from_c: anytype,
    arena: std.mem.Allocator,
    items: ?[*]const PancakeArgument,
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
    items: ?[*]const PancakeArgument,
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

/// One recursive model-value encoder parameterized only by the reference leaf.
pub fn argumentToCWith(
    comptime RefError: type,
    ref_ctx: anytype,
    comptime ref_to_c: anytype,
    arena: std.mem.Allocator,
    arg: model.Argument,
) (MarshalError || RefError)!PancakeArgument {
    var c_arg = zero_argument;
    switch (arg) {
        .integer => |v| {
            c_arg.kind = PANCAKE_ARG_INTEGER;
            c_arg.integer = v;
        },
        .float64 => |v| {
            c_arg.kind = PANCAKE_ARG_FLOAT64;
            c_arg.float64 = v;
        },
        .boolean => |v| {
            c_arg.kind = PANCAKE_ARG_BOOLEAN;
            c_arg.boolean = if (v) 1 else 0;
        },
        .bytes => |b| {
            c_arg.kind = PANCAKE_ARG_BYTES;
            c_arg.bytes = b.ptr;
            c_arg.bytes_len = b.len;
        },
        .string => |b| {
            c_arg.kind = PANCAKE_ARG_STRING;
            c_arg.bytes = b.ptr;
            c_arg.bytes_len = b.len;
        },
        .symbol => |b| {
            c_arg.kind = PANCAKE_ARG_SYMBOL;
            c_arg.bytes = b.ptr;
            c_arg.bytes_len = b.len;
        },
        .@"error" => |reason| {
            c_arg.kind = PANCAKE_ARG_ERROR;
            c_arg.bytes = reason.message.ptr;
            c_arg.bytes_len = reason.message.len;
        },
        .void => c_arg.kind = PANCAKE_ARG_VOID,
        .reference => |r| {
            c_arg.kind = PANCAKE_ARG_REFERENCE;
            c_arg.reference = try ref_to_c(ref_ctx, r);
        },
        .list => |items| {
            c_arg.kind = PANCAKE_ARG_LIST;
            const arr = try argsToCWith(RefError, ref_ctx, ref_to_c, arena, items);
            c_arg.items = arr.ptr;
            c_arg.items_len = arr.len;
        },
        .set => |items| {
            c_arg.kind = PANCAKE_ARG_SET;
            const arr = try argsToCWith(RefError, ref_ctx, ref_to_c, arena, items);
            c_arg.items = arr.ptr;
            c_arg.items_len = arr.len;
        },
        .tagged => |tagged| {
            c_arg.kind = PANCAKE_ARG_TAGGED;
            c_arg.bytes = tagged.tag.ptr;
            c_arg.bytes_len = tagged.tag.len;
            const arr = try argsToCWith(RefError, ref_ctx, ref_to_c, arena, tagged.value);
            c_arg.items = arr.ptr;
            c_arg.items_len = arr.len;
        },
        .keyword => |keyword| {
            c_arg.kind = PANCAKE_ARG_KEYWORD;
            c_arg.bytes = keyword.ptr;
            c_arg.bytes_len = keyword.len;
        },
        .big_integer => |big| {
            c_arg.kind = PANCAKE_ARG_BIG_INTEGER;
            c_arg.boolean = if (big.negative) 1 else 0;
            c_arg.bytes = big.digits.ptr;
            c_arg.bytes_len = big.digits.len;
        },
        .@"struct" => |entries| {
            c_arg.kind = PANCAKE_ARG_STRUCT;
            const arr = try arena.alloc(PancakeArgument, entries.len * 2);
            for (entries, 0..) |entry, i| {
                var key = zero_argument;
                key.kind = PANCAKE_ARG_STRING;
                key.bytes = entry.key.ptr;
                key.bytes_len = entry.key.len;
                arr[i * 2] = key;
                arr[i * 2 + 1] = try argumentToCWith(RefError, ref_ctx, ref_to_c, arena, entry.value);
            }
            c_arg.items = arr.ptr;
            c_arg.items_len = arr.len;
        },
        // Exhaustive on purpose: the model arms with no C mapping are named
        // here, so a new `model.Argument` arm stops this build at the boundary
        // that must decide how (or whether) the typed surface carries it,
        // rather than degrading silently to the opaque-frame fallback.
        .handoff => return error.UnsupportedValue,
    }
    return c_arg;
}

pub fn argsToCWith(
    comptime RefError: type,
    ref_ctx: anytype,
    comptime ref_to_c: anytype,
    arena: std.mem.Allocator,
    args: []const model.Argument,
) (MarshalError || RefError)![]PancakeArgument {
    const out = try arena.alloc(PancakeArgument, args.len);
    for (args, 0..) |arg, i| out[i] = try argumentToCWith(RefError, ref_ctx, ref_to_c, arena, arg);
    return out;
}
