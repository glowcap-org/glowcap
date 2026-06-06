//! Header parity — proves the hand-written `include/pancake.h` agrees with the
//! Zig `c_abi` source it mirrors, so the two cannot silently drift. The header
//! keeps its prose (it is the C consumer's contract document); this test is the
//! compiler-checked guarantee that its layouts and constants match the source.
//!
//! `@cImport` translates `pancake.h`; every assertion compares a C declaration
//! against the Zig `extern struct` / constant it is supposed to equal.

const std = @import("std");
const pancake = @import("pancake");

const cabi = pancake.c_abi;
const c = @cImport({
    @cInclude("pancake.h");
});

/// Every field of the Zig struct sits at the same offset in the C struct, and
/// the structs are the same total size.
fn expectLayoutParity(comptime C: type, comptime Z: type) !void {
    try std.testing.expectEqual(@sizeOf(C), @sizeOf(Z));
    try std.testing.expectEqual(@alignOf(C), @alignOf(Z));
    inline for (@typeInfo(Z).@"struct".fields) |field| {
        try std.testing.expectEqual(@offsetOf(C, field.name), @offsetOf(Z, field.name));
    }
}

fn expectConst(c_value: anytype, zig_value: anytype) !void {
    try std.testing.expectEqual(@as(i64, @intCast(c_value)), @as(i64, @intCast(zig_value)));
}

fn isFunction(comptime value: anytype) bool {
    return @typeInfo(@TypeOf(value)) == .@"fn";
}

test "every exported C ABI function is declared in the header" {
    // A `pancake_*` function added to the Zig source but forgotten in the header
    // (or removed from one side only) fails to compile here.
    inline for (@typeInfo(cabi).@"struct".decls) |decl| {
        if (comptime std.mem.startsWith(u8, decl.name, "pancake_")) {
            if (comptime isFunction(@field(cabi, decl.name))) {
                if (!@hasDecl(c, decl.name)) {
                    @compileError("exported function missing from pancake.h: " ++ decl.name);
                }
            }
        }
    }
}

test "C header struct layouts match the Zig c_abi source" {
    try expectLayoutParity(c.PancakeFrame, cabi.PancakeFrame);
    try expectLayoutParity(c.PancakeManagedFrame, cabi.PancakeManagedFrame);
    try expectLayoutParity(c.PancakeEvent, cabi.PancakeEvent);
    try expectLayoutParity(c.PancakeAllocator, cabi.PancakeAllocator);
    try expectLayoutParity(c.PancakeReference, cabi.PancakeReference);
    try expectLayoutParity(c.PancakeArgument, cabi.PancakeArgument);
    try expectLayoutParity(c.PancakeDeliver, cabi.PancakeDeliver);
    try expectLayoutParity(c.PancakeResolve, cabi.PancakeResolve);
}

test "C header return codes match the Zig c_abi source" {
    try expectConst(c.PANCAKE_OK, cabi.PANCAKE_OK);
    try expectConst(c.PANCAKE_ERR_NULL_POINTER, cabi.PANCAKE_ERR_NULL_POINTER);
    try expectConst(c.PANCAKE_ERR_INVALID_HANDLE, cabi.PANCAKE_ERR_INVALID_HANDLE);
    try expectConst(c.PANCAKE_ERR_INVALID_ARGUMENT, cabi.PANCAKE_ERR_INVALID_ARGUMENT);
    try expectConst(c.PANCAKE_ERR_SESSION, cabi.PANCAKE_ERR_SESSION);
    try expectConst(c.PANCAKE_ERR_CODEC, cabi.PANCAKE_ERR_CODEC);
    try expectConst(c.PANCAKE_ERR_INTERNAL, cabi.PANCAKE_ERR_INTERNAL);
    try expectConst(c.PANCAKE_ERR_WOULD_BLOCK, cabi.PANCAKE_ERR_WOULD_BLOCK);
    try expectConst(c.PANCAKE_ERR_CLOSED, cabi.PANCAKE_ERR_CLOSED);
    try expectConst(c.PANCAKE_ERR_IO, cabi.PANCAKE_ERR_IO);
    try expectConst(c.PANCAKE_ERR_MALFORMED, cabi.PANCAKE_ERR_MALFORMED);
    try expectConst(c.PANCAKE_ERR_FRAME_TOO_LARGE, cabi.PANCAKE_ERR_FRAME_TOO_LARGE);
    try expectConst(c.PANCAKE_ERR_WRONG_EVENT, cabi.PANCAKE_ERR_WRONG_EVENT);
    try expectConst(c.PANCAKE_ERR_UNSUPPORTED_VALUE, cabi.PANCAKE_ERR_UNSUPPORTED_VALUE);
}

test "C header discriminants match the Zig c_abi source" {
    try expectConst(c.PANCAKE_CODEC_SYRUP, cabi.PANCAKE_CODEC_SYRUP);
    try expectConst(c.PANCAKE_CODEC_CAPNP, cabi.PANCAKE_CODEC_CAPNP);
    try expectConst(c.PANCAKE_FRAME_SHAPE_BYTE, cabi.PANCAKE_FRAME_SHAPE_BYTE);
    try expectConst(c.PANCAKE_FRAME_SHAPE_WORD, cabi.PANCAKE_FRAME_SHAPE_WORD);

    try expectConst(c.PANCAKE_EVENT_DELIVER, cabi.PANCAKE_EVENT_DELIVER);
    try expectConst(c.PANCAKE_EVENT_RESOLVE, cabi.PANCAKE_EVENT_RESOLVE);
    try expectConst(c.PANCAKE_EVENT_GC_EXPORT, cabi.PANCAKE_EVENT_GC_EXPORT);
    try expectConst(c.PANCAKE_EVENT_GC_ANSWER, cabi.PANCAKE_EVENT_GC_ANSWER);
    try expectConst(c.PANCAKE_EVENT_HANDOFF, cabi.PANCAKE_EVENT_HANDOFF);
    try expectConst(c.PANCAKE_EVENT_START_SESSION, cabi.PANCAKE_EVENT_START_SESSION);
    try expectConst(c.PANCAKE_EVENT_ABORT, cabi.PANCAKE_EVENT_ABORT);
    try expectConst(c.PANCAKE_EVENT_LISTEN, cabi.PANCAKE_EVENT_LISTEN);
    try expectConst(c.PANCAKE_EVENT_GET, cabi.PANCAKE_EVENT_GET);
    try expectConst(c.PANCAKE_EVENT_INDEX, cabi.PANCAKE_EVENT_INDEX);

    try expectConst(c.PANCAKE_REF_NEAR, cabi.PANCAKE_REF_NEAR);
    try expectConst(c.PANCAKE_REF_FAR, cabi.PANCAKE_REF_FAR);
    try expectConst(c.PANCAKE_REF_PROMISE, cabi.PANCAKE_REF_PROMISE);
    try expectConst(c.PANCAKE_REF_STURDY, cabi.PANCAKE_REF_STURDY);
    try expectConst(c.PANCAKE_REF_BROKEN, cabi.PANCAKE_REF_BROKEN);
    try expectConst(c.PANCAKE_REF_OBJECT, cabi.PANCAKE_REF_OBJECT);
    try expectConst(c.PANCAKE_REF_PROMISE_KIND, cabi.PANCAKE_REF_PROMISE_KIND);

    try expectConst(c.PANCAKE_ARG_INTEGER, cabi.PANCAKE_ARG_INTEGER);
    try expectConst(c.PANCAKE_ARG_FLOAT64, cabi.PANCAKE_ARG_FLOAT64);
    try expectConst(c.PANCAKE_ARG_BOOLEAN, cabi.PANCAKE_ARG_BOOLEAN);
    try expectConst(c.PANCAKE_ARG_BYTES, cabi.PANCAKE_ARG_BYTES);
    try expectConst(c.PANCAKE_ARG_STRING, cabi.PANCAKE_ARG_STRING);
    try expectConst(c.PANCAKE_ARG_SYMBOL, cabi.PANCAKE_ARG_SYMBOL);
    try expectConst(c.PANCAKE_ARG_VOID, cabi.PANCAKE_ARG_VOID);
    try expectConst(c.PANCAKE_ARG_REFERENCE, cabi.PANCAKE_ARG_REFERENCE);
    try expectConst(c.PANCAKE_ARG_LIST, cabi.PANCAKE_ARG_LIST);
    try expectConst(c.PANCAKE_ARG_SET, cabi.PANCAKE_ARG_SET);
    try expectConst(c.PANCAKE_ARG_TAGGED, cabi.PANCAKE_ARG_TAGGED);
    try expectConst(c.PANCAKE_ARG_KEYWORD, cabi.PANCAKE_ARG_KEYWORD);

    try expectConst(c.PANCAKE_RESOLUTION_FULFILL, cabi.PANCAKE_RESOLUTION_FULFILL);
    try expectConst(c.PANCAKE_RESOLUTION_BREAK, cabi.PANCAKE_RESOLUTION_BREAK);

    try expectConst(c.PANCAKE_VERSION_MAJOR, cabi.PANCAKE_VERSION_MAJOR);
    try expectConst(c.PANCAKE_VERSION_MINOR, cabi.PANCAKE_VERSION_MINOR);
    try expectConst(c.PANCAKE_VERSION_PATCH, cabi.PANCAKE_VERSION_PATCH);
}
