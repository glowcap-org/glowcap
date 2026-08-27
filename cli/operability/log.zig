//! Structured logging for the pancake CLI.
//!
//! Default destination is stderr. The CapTP lab TUI installs a process divert
//! for the whole alt-screen lifetime so *every* `info`/`err` (including
//! callers that only have `std.Io`) lands in the transcript — never beside
//! the cursor. In a test compilation the fallback is `test_capture` instead
//! of stderr: the build runner echoes any stderr a passing test step writes
//! (under its verbose-context `failed command:` label), so a green gate log
//! would read as a failure.
const std = @import("std");
const builtin = @import("builtin");

pub const Divert = struct {
    ptr: *anyopaque,
    writeFn: *const fn (ptr: *anyopaque, msg: []const u8) void,
};

var divert: ?Divert = null;

/// Install/clear the lab divert. Pass `null` to restore stderr.
pub fn setDivert(next: ?Divert) void {
    divert = next;
}

pub fn hasDivert() bool {
    return divert != null;
}

/// Write raw bytes through divert when active; otherwise stderr, except in a
/// test compilation, where the fallback is `test_capture` (see module doc).
pub fn writeMsg(io: std.Io, msg: []const u8) void {
    if (divert) |d| {
        d.writeFn(d.ptr, msg);
        return;
    }
    if (builtin.is_test) {
        test_capture.append(msg);
        return;
    }
    // best-effort: the diagnostic channel itself refused; nowhere to report.
    std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
}

/// One test-compilation capture stream. Test binaries own neither process
/// stream: the build runner echoes stderr from passing steps, and the test
/// protocol (`--listen=-`) owns stdout, so in a test build every CLI stream
/// write lands in a capture instead. Instantiate with a distinct tag; each
/// tag owns independent storage, which is what keeps the stdout/stderr
/// split assertable. A case asserting on a stream calls `reset()` first,
/// drives the path, then reads `captured()`. Overflow truncates: a capture
/// is evidence for assertions, not a transcript.
pub fn TestCapture(comptime tag: @TypeOf(.enum_literal)) type {
    return struct {
        /// Which stream this capture is. Load-bearing even with no reader: a
        /// returned struct that never mentions `tag` is the same type for every
        /// tag, and one type is one `storage`, so the stdout and diagnostics
        /// captures would silently share bytes. Naming the tag here is what
        /// makes each instantiation its own type with its own storage.
        pub const stream_tag = tag;

        var storage: [64 << 10]u8 = undefined;
        var len: usize = 0;

        pub fn append(msg: []const u8) void {
            const take = @min(storage.len - len, msg.len);
            @memcpy(storage[len..][0..take], msg[0..take]);
            len += take;
        }

        pub fn captured() []const u8 {
            return storage[0..len];
        }

        pub fn reset() void {
            len = 0;
        }
    };
}

/// The diagnostics stream's capture: with no divert installed, `writeMsg`
/// appends here instead of the process stderr. The product-stdout twin is
/// `argv.test_stdout_capture`.
pub const test_capture = if (builtin.is_test) TestCapture(.diagnostics) else struct {};

/// Format into `buf`, truncating visibly on overflow. A diagnostic must
/// never vanish: dropping the line on `NoSpaceLeft` silences exactly the
/// message that was trying to explain a failure. The truncated form keeps
/// what fit and ends with a marked newline.
pub fn renderBounded(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.print(fmt, args) catch {
        const mark = " [truncated]\n";
        @memcpy(buf[buf.len - mark.len ..], mark);
        return buf;
    };
    return w.buffered();
}

pub fn info(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    writeMsg(io, renderBounded(&buf, "pancake: " ++ fmt ++ "\n", args));
}

pub fn err(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    writeMsg(io, renderBounded(&buf, "pancake: error: " ++ fmt ++ "\n", args));
}
