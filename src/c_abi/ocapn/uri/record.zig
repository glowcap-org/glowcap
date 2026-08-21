//! Signed-handoff locator-record projection for the C ABI.
//!
//! URI parsing and formatting live in the parent facade. This leaf owns the
//! narrower C crossing that turns a borrowed locator view into owned
//! `<ocapn-peer>` record bytes for handoff signatures.

const engine = @import("engine");
const model = @import("model");

const c = @import("../mod.zig");
const shared = @import("c_abi_shared");
const ctx = @import("../context.zig");

const PANCAKE_OK = c.PANCAKE_OK;
const PANCAKE_ERR_NULL_POINTER = c.PANCAKE_ERR_NULL_POINTER;
const PANCAKE_ERR_INVALID_ARGUMENT = c.PANCAKE_ERR_INVALID_ARGUMENT;
const PANCAKE_ERR_INTERNAL = c.PANCAKE_ERR_INTERNAL;

fn recordErrToCode(err: anyerror) i32 {
    return switch (err) {
        error.NullPointer => PANCAKE_ERR_NULL_POINTER,
        error.OutOfMemory => blk: {
            c.setLastError("locator record encode: OutOfMemory", .{});
            break :blk PANCAKE_ERR_INTERNAL;
        },
        else => blk: {
            c.setLastError("locator record encode: {s}", .{@errorName(err)});
            break :blk PANCAKE_ERR_INVALID_ARGUMENT;
        },
    };
}

/// Encode the verbatim `<ocapn-peer>` record embedded in a signed handoff
/// locator. The result is owned and must be released with
/// `pancake_locator_record_bytes_release`.
pub export fn pancake_locator_record_encode(
    locator: ?*const shared.PancakeLocatorView,
    out: ?*?[*]u8,
    out_len: ?*usize,
) i32 {
    shared.lastErrorClear();
    const out_slot = out orelse return PANCAKE_ERR_NULL_POINTER;
    const out_len_slot = out_len orelse return PANCAKE_ERR_NULL_POINTER;
    const view = locator orelse return PANCAKE_ERR_NULL_POINTER;
    var hint_stack: [shared.locator_adapter.inline_hint_capacity]model.HintEntry = undefined;
    var borrowed = shared.locator_adapter.BorrowedLocator.init(
        ctx.library_allocator,
        view,
        &hint_stack,
    ) catch |err| return recordErrToCode(err);
    defer borrowed.deinit(ctx.library_allocator);

    const bytes = engine.encodePeerLocatorRecord(ctx.library_allocator, borrowed.value) catch |err| switch (err) {
        error.OutOfMemory => return recordErrToCode(err),
        else => {
            c.setLastError("locator record encode: {s}", .{@errorName(err)});
            return c.PANCAKE_ERR_CODEC;
        },
    };
    out_slot.* = bytes.ptr;
    out_len_slot.* = bytes.len;
    return PANCAKE_OK;
}

/// Release bytes returned by `pancake_locator_record_encode`. NULL is a no-op.
pub export fn pancake_locator_record_bytes_release(bytes: ?[*]u8, len: usize) void {
    const ptr = bytes orelse return;
    ctx.library_allocator.free(ptr[0..len]);
}
