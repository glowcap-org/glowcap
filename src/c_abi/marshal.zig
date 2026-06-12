//! Typed C ABI value marshalling helpers.
//!
//! The exported `peer.zig` functions stay in the peer facade. This module owns
//! conversion between fixed-layout C structs and codec-neutral model values, plus
//! the per-event projection arena lifecycle.

const std = @import("std");

const model = @import("model");

const c = @import("mod.zig");

const PancakeReference = c.PancakeReference;
const PancakeArgument = c.PancakeArgument;

const PANCAKE_ERR_NULL_POINTER = c.PANCAKE_ERR_NULL_POINTER;
const PANCAKE_ERR_INTERNAL = c.PANCAKE_ERR_INTERNAL;
const PANCAKE_ERR_UNSUPPORTED_VALUE = c.PANCAKE_ERR_UNSUPPORTED_VALUE;

pub const zero_reference: PancakeReference = .{ .kind = c.PANCAKE_REF_BROKEN, .sub_kind = 0, .id = 0 };
pub const zero_argument: PancakeArgument = .{
    .kind = c.PANCAKE_ARG_VOID,
    .boolean = 0,
    .integer = 0,
    .float64 = 0,
    .bytes = null,
    .bytes_len = 0,
    .reference = zero_reference,
    .items = null,
    .items_len = 0,
};

pub const MarshalError = error{ UnsupportedValue, NullPointer, OutOfMemory };

pub fn marshalErrorToCode(err: MarshalError) i32 {
    return switch (err) {
        error.UnsupportedValue => PANCAKE_ERR_UNSUPPORTED_VALUE,
        error.NullPointer => PANCAKE_ERR_NULL_POINTER,
        error.OutOfMemory => PANCAKE_ERR_INTERNAL,
    };
}

pub fn sliceFromC(ptr: ?[*]const u8, len: usize) MarshalError![]const u8 {
    if (len == 0) return &.{};
    const p = ptr orelse return error.NullPointer;
    return p[0..len];
}

pub fn referenceFromC(c_ref: PancakeReference) MarshalError!model.Reference {
    const promise_sub = c_ref.sub_kind == c.PANCAKE_REF_SUB_PROMISE;
    return switch (c_ref.kind) {
        c.PANCAKE_REF_NEAR => .{ .near = .{ .export_position = c_ref.id, .kind = if (promise_sub) .promise else .object } },
        c.PANCAKE_REF_FAR => .{ .far = .{ .import_position = c_ref.id, .kind = if (promise_sub) .promise else .object } },
        c.PANCAKE_REF_PROMISE => .{ .promise = .{ .answer_position = c_ref.id } },
        else => error.UnsupportedValue,
    };
}

/// Depth bound on a host-supplied argument tree. A foreign caller could nest
/// `PancakeArgument` lists/sets/tagged values arbitrarily deep and overflow the
/// native stack inside `argumentFromC`, exactly as a hostile wire frame could in
/// the codec. The value mirrors the session's default `max_nesting_depth` (64).
pub const max_marshal_depth: usize = 64;

pub fn argumentFromC(arena: std.mem.Allocator, c_arg: PancakeArgument, depth: usize) MarshalError!model.Argument {
    if (depth > max_marshal_depth) return error.UnsupportedValue;
    const next = depth + 1;
    return switch (c_arg.kind) {
        c.PANCAKE_ARG_INTEGER => .{ .integer = c_arg.integer },
        c.PANCAKE_ARG_FLOAT64 => .{ .float64 = c_arg.float64 },
        c.PANCAKE_ARG_BOOLEAN => .{ .boolean = c_arg.boolean != 0 },
        c.PANCAKE_ARG_BYTES => .{ .bytes = try sliceFromC(c_arg.bytes, c_arg.bytes_len) },
        c.PANCAKE_ARG_STRING => .{ .string = try sliceFromC(c_arg.bytes, c_arg.bytes_len) },
        c.PANCAKE_ARG_SYMBOL => .{ .symbol = try sliceFromC(c_arg.bytes, c_arg.bytes_len) },
        c.PANCAKE_ARG_VOID => .{ .void = {} },
        c.PANCAKE_ARG_REFERENCE => .{ .reference = try referenceFromC(c_arg.reference) },
        c.PANCAKE_ARG_LIST => .{ .list = try argsFromC(arena, c_arg.items, c_arg.items_len, next) },
        c.PANCAKE_ARG_SET => .{ .set = try argsFromC(arena, c_arg.items, c_arg.items_len, next) },
        c.PANCAKE_ARG_TAGGED => .{ .tagged = .{
            .tag = try sliceFromC(c_arg.bytes, c_arg.bytes_len),
            .value = try argsFromC(arena, c_arg.items, c_arg.items_len, next),
        } },
        c.PANCAKE_ARG_KEYWORD => .{ .keyword = try sliceFromC(c_arg.bytes, c_arg.bytes_len) },
        c.PANCAKE_ARG_BIG_INTEGER => blk: {
            const big = model.BigInteger{
                .negative = c_arg.boolean != 0,
                .digits = try sliceFromC(c_arg.bytes, c_arg.bytes_len),
            };
            // Fail closed at the boundary, like the codecs: leading zeros,
            // non-digits, or a magnitude that belongs in PANCAKE_ARG_INTEGER.
            if (!big.isCanonical()) break :blk error.UnsupportedValue;
            break :blk .{ .big_integer = big };
        },
        else => error.UnsupportedValue,
    };
}

pub fn argsFromC(arena: std.mem.Allocator, items: ?[*]const PancakeArgument, len: usize, depth: usize) MarshalError![]const model.Argument {
    if (len == 0) return &.{};
    const p = items orelse return error.NullPointer;
    const out = try arena.alloc(model.Argument, len);
    for (0..len) |i| out[i] = try argumentFromC(arena, p[i], depth);
    return out;
}

pub fn referenceToC(reference: model.Reference) PancakeReference {
    return switch (reference) {
        .near => |near| .{ .kind = c.PANCAKE_REF_NEAR, .sub_kind = if (near.kind == .promise) c.PANCAKE_REF_SUB_PROMISE else c.PANCAKE_REF_SUB_OBJECT, .id = near.export_position },
        .far => |far| .{ .kind = c.PANCAKE_REF_FAR, .sub_kind = if (far.kind == .promise) c.PANCAKE_REF_SUB_PROMISE else c.PANCAKE_REF_SUB_OBJECT, .id = far.import_position },
        .promise => |promise| .{ .kind = c.PANCAKE_REF_PROMISE, .sub_kind = 0, .id = promise.answer_position },
        .sturdy => .{ .kind = c.PANCAKE_REF_STURDY, .sub_kind = 0, .id = 0 },
        .broken => .{ .kind = c.PANCAKE_REF_BROKEN, .sub_kind = 0, .id = 0 },
    };
}

pub fn argumentToC(arena: std.mem.Allocator, arg: model.Argument) MarshalError!PancakeArgument {
    var c_arg = zero_argument;
    switch (arg) {
        .integer => |v| {
            c_arg.kind = c.PANCAKE_ARG_INTEGER;
            c_arg.integer = v;
        },
        .float64 => |v| {
            c_arg.kind = c.PANCAKE_ARG_FLOAT64;
            c_arg.float64 = v;
        },
        .boolean => |v| {
            c_arg.kind = c.PANCAKE_ARG_BOOLEAN;
            c_arg.boolean = if (v) 1 else 0;
        },
        .bytes => |b| {
            c_arg.kind = c.PANCAKE_ARG_BYTES;
            c_arg.bytes = b.ptr;
            c_arg.bytes_len = b.len;
        },
        .string => |b| {
            c_arg.kind = c.PANCAKE_ARG_STRING;
            c_arg.bytes = b.ptr;
            c_arg.bytes_len = b.len;
        },
        .symbol => |b| {
            c_arg.kind = c.PANCAKE_ARG_SYMBOL;
            c_arg.bytes = b.ptr;
            c_arg.bytes_len = b.len;
        },
        .void => c_arg.kind = c.PANCAKE_ARG_VOID,
        .reference => |r| {
            c_arg.kind = c.PANCAKE_ARG_REFERENCE;
            c_arg.reference = referenceToC(r);
        },
        .list => |items| {
            c_arg.kind = c.PANCAKE_ARG_LIST;
            const arr = try argsToC(arena, items);
            c_arg.items = arr.ptr;
            c_arg.items_len = arr.len;
        },
        .set => |items| {
            c_arg.kind = c.PANCAKE_ARG_SET;
            const arr = try argsToC(arena, items);
            c_arg.items = arr.ptr;
            c_arg.items_len = arr.len;
        },
        .tagged => |tagged| {
            c_arg.kind = c.PANCAKE_ARG_TAGGED;
            c_arg.bytes = tagged.tag.ptr;
            c_arg.bytes_len = tagged.tag.len;
            const arr = try argsToC(arena, tagged.value);
            c_arg.items = arr.ptr;
            c_arg.items_len = arr.len;
        },
        .keyword => |keyword| {
            c_arg.kind = c.PANCAKE_ARG_KEYWORD;
            c_arg.bytes = keyword.ptr;
            c_arg.bytes_len = keyword.len;
        },
        .big_integer => |big| {
            c_arg.kind = c.PANCAKE_ARG_BIG_INTEGER;
            c_arg.boolean = if (big.negative) 1 else 0;
            c_arg.bytes = big.digits.ptr;
            c_arg.bytes_len = big.digits.len;
        },
        else => return error.UnsupportedValue,
    }
    return c_arg;
}

pub fn argsToC(arena: std.mem.Allocator, args: []const model.Argument) MarshalError![]PancakeArgument {
    const out = try arena.alloc(PancakeArgument, args.len);
    for (args, 0..) |arg, i| out[i] = try argumentToC(arena, arg);
    return out;
}

/// Allocate a heap-pinned arena (child = the peer's allocator) to own a received
/// projection. `pancake_*_free` deinits and destroys it through that same child.
pub fn newProjectionArena(alloc: std.mem.Allocator) ?*std.heap.ArenaAllocator {
    const arena = alloc.create(std.heap.ArenaAllocator) catch return null;
    arena.* = std.heap.ArenaAllocator.init(alloc);
    return arena;
}

pub fn freeProjectionArena(owner: ?*anyopaque) void {
    const arena: *std.heap.ArenaAllocator = @ptrCast(@alignCast(owner orelse return));
    const child = arena.child_allocator;
    arena.deinit();
    child.destroy(arena);
}
