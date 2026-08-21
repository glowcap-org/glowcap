//! C ABI output-buffer contract for OCapN URI formatting.

const model = @import("model");

const c = @import("../mod.zig");

const PANCAKE_OK = c.PANCAKE_OK;
const PANCAKE_ERR_NULL_POINTER = c.PANCAKE_ERR_NULL_POINTER;
const PANCAKE_ERR_INVALID_ARGUMENT = c.PANCAKE_ERR_INVALID_ARGUMENT;
const PANCAKE_ERR_INTERNAL = c.PANCAKE_ERR_INTERNAL;
const PANCAKE_ERR_BUFFER_TOO_SMALL = c.PANCAKE_ERR_BUFFER_TOO_SMALL;

fn writeErrToCode(err: model.uri.Error) i32 {
    return switch (err) {
        error.OutOfMemory => blk: {
            c.setLastError("uri format: OutOfMemory", .{});
            break :blk PANCAKE_ERR_INTERNAL;
        },
        else => blk: {
            c.setLastError("uri format: {s}", .{@errorName(err)});
            break :blk PANCAKE_ERR_INVALID_ARGUMENT;
        },
    };
}

pub fn peer(locator: model.PeerLocator, out: ?[*]u8, cap: usize, out_len: ?*usize) i32 {
    const l = out_len orelse return PANCAKE_ERR_NULL_POINTER;
    const dest = out orelse {
        if (cap == 0) {
            const len = model.uri.measurePeer(locator) catch |err| return writeErrToCode(err);
            l.* = len;
            return if (len == 0) PANCAKE_OK else PANCAKE_ERR_BUFFER_TOO_SMALL;
        }
        c.setLastError("uri format: out is null with nonzero capacity", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };
    const result = model.uri.writePeerBounded(locator, dest[0..cap]) catch |err| return writeErrToCode(err);
    l.* = result.len;
    return if (result.complete) PANCAKE_OK else PANCAKE_ERR_BUFFER_TOO_SMALL;
}

pub fn sturdyref(
    profile: model.CaptpVersion,
    value: model.SturdyRef,
    out: ?[*]u8,
    cap: usize,
    out_len: ?*usize,
) i32 {
    const l = out_len orelse return PANCAKE_ERR_NULL_POINTER;
    const dest = out orelse {
        if (cap == 0) {
            const len = model.uri.measureSturdyrefForProfile(profile, value) catch |err| return writeErrToCode(err);
            l.* = len;
            return if (len == 0) PANCAKE_OK else PANCAKE_ERR_BUFFER_TOO_SMALL;
        }
        c.setLastError("uri format: out is null with nonzero capacity", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };
    const result = model.uri.writeSturdyrefForProfileBounded(profile, value, dest[0..cap]) catch |err| return writeErrToCode(err);
    l.* = result.len;
    return if (result.complete) PANCAKE_OK else PANCAKE_ERR_BUFFER_TOO_SMALL;
}
