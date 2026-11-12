//! Archive-local immediate error detail for direct C calls.
//!
//! Each importing archive compiles its own thread-local slot. Structured
//! failure reports remain authoritative for retained failures. This slot
//! explains the current synchronous call and is copied before an off-thread FFI
//! call returns.

const std = @import("std");
const foundation = @import("foundation");
const result = @import("result.zig");

threadlocal var buffer: [256]u8 = undefined;
threadlocal var length: usize = 0;
/// The local cause supplied by the archive owning the failed operation.
threadlocal var cause_code: foundation.break_cause.BreakCause = .{};

const truncated_suffix = "... [truncated]";

pub fn set(comptime fmt: []const u8, args: anytype) void {
    cause_code = .{};
    // A fixed writer reports exactly how many bytes it wrote, including on
    // overflow. Publishing its whole backing buffer would expose an
    // uninitialized tail after a partner-supplied designator overflows it.
    var writer = std.Io.Writer.fixed(&buffer);
    writer.print(fmt, args) catch {
        comptime std.debug.assert(truncated_suffix.len <= buffer.len);
        const suffix_start = buffer.len - truncated_suffix.len;
        @memcpy(buffer[suffix_start..], truncated_suffix);
        length = buffer.len;
        return;
    };
    length = writer.end;
}

/// Record the operation owner's cause alongside its diagnostic.
pub fn setCause(value: foundation.break_cause.BreakCause, comptime fmt: []const u8, args: anytype) void {
    set(fmt, args);
    cause_code = value;
}

/// Retain the textual projection of the same bounded failure-chain fact used
/// by structured provider reports.
pub fn setChain(prefix: []const u8, failure: foundation.FailureChain) void {
    if (failure.secondaryName()) |secondary_name| {
        set("{s}: {s}; cleanup: {s} ({d} secondary failures)", .{
            prefix,
            failure.primaryName(),
            secondary_name,
            failure.secondary_count,
        });
    } else {
        set("{s}: {s}", .{ prefix, failure.primaryName() });
    }
}

pub fn failInternal(comptime operation: []const u8, cause: anyerror) i32 {
    set(operation ++ ": {s}", .{@errorName(cause)});
    return result.GLOWCAP_ERR_INTERNAL;
}

pub fn failIo(comptime operation: []const u8, cause: anyerror) i32 {
    set(operation ++ ": {s}", .{@errorName(cause)});
    return result.GLOWCAP_ERR_IO;
}

/// Copy the calling thread's last error, NUL-terminating when `cap > 0`, and
/// return the full message length.
pub fn read(out_buf: ?[*]u8, cap: usize) usize {
    const dest = out_buf orelse return length;
    if (cap == 0) return length;
    const copied = @min(length, cap - 1);
    @memcpy(dest[0..copied], buffer[0..copied]);
    dest[copied] = 0;
    return length;
}

/// Read the calling thread's typed cause. Zero makes no provenance claim.
pub fn readCause() foundation.break_cause.BreakCause {
    return cause_code;
}

/// Local failures with a public cause beyond the route outcomes that
/// `break_cause.namedRouteFailure` owns. Partner text never enters it.
const caused_refusals = .{
    .{ .err = error.PeerIdentityUnverified, .cause = foundation.break_cause.BreakCause.local(.identity_unverified) },
};

/// The public cause of a local refusal, or none when the error names no row.
pub fn causeFor(err: anyerror) foundation.break_cause.BreakCause {
    if (foundation.break_cause.namedRouteFailure(err)) |route| return route.cause();
    inline for (caused_refusals) |row| if (err == row.err) return row.cause;
    return .{};
}

/// Attach `value` to the diagnostic the last call recorded.
pub fn attachCause(value: foundation.break_cause.BreakCause) void {
    cause_code = value;
}

pub fn clear() void {
    length = 0;
    cause_code = .{};
}

pub fn captureCall(
    code: i32,
    out_buf: ?[*]u8,
    cap: usize,
    out_len: ?*usize,
) i32 {
    if (out_len) |destination| destination.* = read(out_buf, cap);
    return code;
}

/// A caller-buffer diagnostic is either wholly omitted or has a length slot.
pub fn optionalOutputIsValid(out_buf: ?[*]u8, cap: usize, out_len: ?*usize) bool {
    return out_len != null or (out_buf == null and cap == 0);
}
