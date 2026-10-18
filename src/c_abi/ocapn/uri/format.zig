//! C ABI output-buffer contract for OCapN URI formatting.

const model = @import("model");

const c = @import("../mod.zig");

const GLOWCAP_OK = c.GLOWCAP_OK;
const GLOWCAP_ERR_NULL_POINTER = c.GLOWCAP_ERR_NULL_POINTER;
const GLOWCAP_ERR_INVALID_ARGUMENT = c.GLOWCAP_ERR_INVALID_ARGUMENT;
const GLOWCAP_ERR_INTERNAL = c.GLOWCAP_ERR_INTERNAL;
const GLOWCAP_ERR_BUFFER_TOO_SMALL = c.GLOWCAP_ERR_BUFFER_TOO_SMALL;

fn writeErrToCode(err: model.uri.Error) i32 {
    return switch (err) {
        error.OutOfMemory => blk: {
            c.setLastError("uri format: OutOfMemory", .{});
            break :blk GLOWCAP_ERR_INTERNAL;
        },
        else => blk: {
            c.setLastError("uri format: {s}", .{@errorName(err)});
            break :blk GLOWCAP_ERR_INVALID_ARGUMENT;
        },
    };
}

pub fn peer(locator: model.PeerLocator, out: ?[*]u8, cap: usize, out_len: ?*usize) i32 {
    return bounded(model.uri.measurePeer, model.uri.writePeerBounded, .{locator}, out, cap, out_len);
}

pub fn sturdyref(profile: model.CaptpVersion, value: model.SturdyRef, out: ?[*]u8, cap: usize, out_len: ?*usize) i32 {
    return bounded(model.uri.measureSturdyrefForProfile, model.uri.writeSturdyrefForProfileBounded, .{ profile, value }, out, cap, out_len);
}

/// The output-buffer protocol every formatter shares. A null `out` with zero
/// capacity asks for the length; otherwise `write` fills `out[0..cap]` and
/// reports whether it fit.
fn bounded(comptime measure: anytype, comptime write: anytype, args: anytype, out: ?[*]u8, cap: usize, out_len: ?*usize) i32 {
    const l = out_len orelse return GLOWCAP_ERR_NULL_POINTER;
    const dest = out orelse {
        if (cap == 0) {
            const len = @call(.auto, measure, args) catch |err| return writeErrToCode(err);
            l.* = len;
            return if (len == 0) GLOWCAP_OK else GLOWCAP_ERR_BUFFER_TOO_SMALL;
        }
        c.setLastError("uri format: out is null with nonzero capacity", .{});
        return GLOWCAP_ERR_INVALID_ARGUMENT;
    };
    const result = @call(.auto, write, args ++ .{dest[0..cap]}) catch |err| return writeErrToCode(err);
    l.* = result.len;
    return if (result.complete) GLOWCAP_OK else GLOWCAP_ERR_BUFFER_TOO_SMALL;
}
