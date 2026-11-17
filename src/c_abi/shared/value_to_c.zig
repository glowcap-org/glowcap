//! Encode OCapN values onto the C argument layout, over a Host value tree or a
//! wire frame's borrowed views.

const std = @import("std");
const model = @import("model");
const c_values = @import("value.zig");

const GlowcapArgument = c_values.GlowcapArgument;
const GlowcapReference = c_values.GlowcapReference;
const MarshalError = c_values.MarshalError;
const zero_argument = c_values.zero_argument;
const GLOWCAP_ARG_INTEGER = c_values.GLOWCAP_ARG_INTEGER;
const GLOWCAP_ARG_FLOAT64 = c_values.GLOWCAP_ARG_FLOAT64;
const GLOWCAP_ARG_BOOLEAN = c_values.GLOWCAP_ARG_BOOLEAN;
const GLOWCAP_ARG_BYTES = c_values.GLOWCAP_ARG_BYTES;
const GLOWCAP_ARG_STRING = c_values.GLOWCAP_ARG_STRING;
const GLOWCAP_ARG_SYMBOL = c_values.GLOWCAP_ARG_SYMBOL;
const GLOWCAP_ARG_VOID = c_values.GLOWCAP_ARG_VOID;
const GLOWCAP_ARG_REFERENCE = c_values.GLOWCAP_ARG_REFERENCE;
const GLOWCAP_ARG_LIST = c_values.GLOWCAP_ARG_LIST;
const GLOWCAP_ARG_SET = c_values.GLOWCAP_ARG_SET;
const GLOWCAP_ARG_TAGGED = c_values.GLOWCAP_ARG_TAGGED;
const GLOWCAP_ARG_KEYWORD = c_values.GLOWCAP_ARG_KEYWORD;
const GLOWCAP_ARG_BIG_INTEGER = c_values.GLOWCAP_ARG_BIG_INTEGER;
const GLOWCAP_ARG_STRUCT = c_values.GLOWCAP_ARG_STRUCT;
const GLOWCAP_ARG_ERROR = c_values.GLOWCAP_ARG_ERROR;
const GLOWCAP_ARG_INTEGERS = c_values.GLOWCAP_ARG_INTEGERS;

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
    return valueToCWith(model.Argument, RefError, ref_ctx, ref_to_c, arena, arg);
}

pub fn argsToCWith(
    comptime RefError: type,
    ref_ctx: anytype,
    comptime ref_to_c: anytype,
    arena: std.mem.Allocator,
    args: []const model.Argument,
) (MarshalError || RefError)![]GlowcapArgument {
    return valuesToCWith(model.Argument, RefError, ref_ctx, ref_to_c, arena, args);
}

/// The refusals reading a wire frame's views adds to the walk below. A value
/// tree built in memory has none.
pub const ViewError = model.view.ProjectError || error{NestingTooDeep};

fn ReadError(comptime Input: type) type {
    return if (Input == model.view.Argument) ViewError else error{};
}

/// Encode the Host's opaque-capability value, the mirror of `valuesFromCWith`.
/// `Value` carries the data arms above, a `capability` arm the callback
/// projects, and an `integers` run that leaves as one `_INTEGERS` value with
/// its words lent where they lie (ADR-0064).
///
/// The argument-kind switch is one body, and the container readers are two, one
/// per input. The arms whose C form depends on `Input` are
/// resolved at compile time below them, and an arm neither names stops the
/// build at this boundary, which must decide how (or whether) the typed
/// surface carries it, instead of degrading silently to the opaque-frame
/// fallback.
///
/// `Input` is also `model.view.Argument`, a wire frame's borrowed tree. Its
/// containers are read through their fallible cursors, element by element, so
/// a list backed by an integer run leaves as one `_INTEGER` per word, and
/// nesting past `model.max_value_depth` refuses with `NestingTooDeep`. A view
/// that does not project refuses with `MalformedView`. A tree built in memory
/// has no fallible cursor whose count could disagree with its elements, so it
/// has no `MalformedView`, and this walk does not bound its depth.
pub fn valueToCWith(
    comptime Input: type,
    comptime RefError: type,
    ref_ctx: anytype,
    comptime ref_to_c: anytype,
    arena: std.mem.Allocator,
    value: Input,
) (MarshalError || RefError || ReadError(Input))!GlowcapArgument {
    return walkToC(Input, RefError, ref_ctx, ref_to_c, arena, value, 0);
}

fn walkToC(
    comptime Input: type,
    comptime RefError: type,
    ref_ctx: anytype,
    comptime ref_to_c: anytype,
    arena: std.mem.Allocator,
    value: Input,
    depth: usize,
) (MarshalError || RefError || ReadError(Input))!GlowcapArgument {
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
            setItems(&c_arg, try childrenToC(Input, RefError, ref_ctx, ref_to_c, arena, items, try itemsDepth(Input, depth)));
        },
        .set => |items| {
            c_arg.kind = GLOWCAP_ARG_SET;
            setItems(&c_arg, try childrenToC(Input, RefError, ref_ctx, ref_to_c, arena, items, try itemsDepth(Input, depth)));
        },
        .tagged => |tagged| {
            c_arg = leafToC(GLOWCAP_ARG_TAGGED, tagged.tag);
            setItems(&c_arg, try childrenToC(Input, RefError, ref_ctx, ref_to_c, arena, tagged.value, try itemsDepth(Input, depth)));
        },
        .big_integer => |big| {
            c_arg = leafToC(GLOWCAP_ARG_BIG_INTEGER, big.digits);
            c_arg.boolean = @intFromBool(big.negative);
        },
        .@"struct" => |entries| {
            c_arg.kind = GLOWCAP_ARG_STRUCT;
            setItems(&c_arg, try entriesToC(Input, RefError, ref_ctx, ref_to_c, arena, entries, try itemsDepth(Input, depth)));
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

/// The depth of the items of a container at `depth`. A view comes from a
/// frame and refuses at the model's ceiling (`model.mayHoldItems`), where the
/// lift does. A Host value passed the Host's own walks already.
inline fn itemsDepth(comptime Input: type, depth: usize) ReadError(Input)!usize {
    if (comptime Input == model.view.Argument) {
        if (!model.mayHoldItems(depth)) return error.NestingTooDeep;
    }
    return depth + 1;
}

/// One container's children, one `GlowcapArgument` array in `arena`. `items`
/// is a slice of `Input`, or the views' `Args` when `Input` is the view. The
/// two bodies stay apart because a view's count and its cursor fail separately
/// and must agree, which a slice cannot do.
fn childrenToC(
    comptime Input: type,
    comptime RefError: type,
    ref_ctx: anytype,
    comptime ref_to_c: anytype,
    arena: std.mem.Allocator,
    items: anytype,
    depth: usize,
) (MarshalError || RefError || ReadError(Input))![]GlowcapArgument {
    if (comptime Input != model.view.Argument) {
        const out = try arena.alloc(GlowcapArgument, items.len);
        for (items, out) |item, *slot| slot.* = try walkToC(Input, RefError, ref_ctx, ref_to_c, arena, item, depth);
        return out;
    }
    const out = try arena.alloc(GlowcapArgument, try items.len());
    var filled: usize = 0;
    var it = items.iterator();
    while (try it.nextRef()) |item| : (filled += 1) {
        if (filled >= out.len) return error.MalformedView;
        out[filled] = try walkToC(Input, RefError, ref_ctx, ref_to_c, arena, item.*, depth);
    }
    if (filled != out.len) return error.MalformedView;
    return out;
}

/// A struct's alternating key and value slots, one `GlowcapArgument` array in
/// `arena`. The keys are lent where they lie.
fn entriesToC(
    comptime Input: type,
    comptime RefError: type,
    ref_ctx: anytype,
    comptime ref_to_c: anytype,
    arena: std.mem.Allocator,
    entries: anytype,
    depth: usize,
) (MarshalError || RefError || ReadError(Input))![]GlowcapArgument {
    if (comptime Input != model.view.Argument) {
        const arr = try arena.alloc(GlowcapArgument, entries.len * 2);
        for (entries, 0..) |entry, i| {
            arr[i * 2] = leafToC(GLOWCAP_ARG_STRING, entry.key);
            arr[i * 2 + 1] = try walkToC(Input, RefError, ref_ctx, ref_to_c, arena, entry.value, depth);
        }
        return arr;
    }
    const arr = try arena.alloc(GlowcapArgument, (try entries.len()) * 2);
    var filled: usize = 0;
    var it = entries.iterator();
    while (try it.nextRef()) |entry| : (filled += 2) {
        if (filled >= arr.len) return error.MalformedView;
        arr[filled] = leafToC(GLOWCAP_ARG_STRING, entry.key);
        arr[filled + 1] = try walkToC(Input, RefError, ref_ctx, ref_to_c, arena, entry.value, depth);
    }
    if (filled != arr.len) return error.MalformedView;
    return arr;
}

/// `valueToCWith` over a top-level argument list: one `GlowcapArgument` array
/// in `arena`.
pub fn valuesToCWith(
    comptime Input: type,
    comptime RefError: type,
    ref_ctx: anytype,
    comptime ref_to_c: anytype,
    arena: std.mem.Allocator,
    values: []const Input,
) (MarshalError || RefError || ReadError(Input))![]GlowcapArgument {
    return childrenToC(Input, RefError, ref_ctx, ref_to_c, arena, values, 0);
}

/// A view that names a reference or a handoff has no C form here.
fn refuseReference(_: void, _: anytype) error{UnsupportedValue}!GlowcapReference {
    return error.UnsupportedValue;
}

/// `valuesToCWith` over a wire frame's views, read where they lie: one
/// `GlowcapArgument` array per container in `arena`, every leaf lent from the
/// frame, and a run of integers read as one `GLOWCAP_ARG_INTEGER` per word. A
/// view that names a reference or a handoff refuses with `UnsupportedValue`,
/// nesting past `model.max_value_depth` with `NestingTooDeep`, and a view that
/// does not project with `MalformedView`.
pub fn viewsToC(arena: std.mem.Allocator, args: model.view.Args) (MarshalError || ViewError)![]GlowcapArgument {
    return childrenToC(model.view.Argument, error{UnsupportedValue}, {}, refuseReference, arena, args, 0);
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
