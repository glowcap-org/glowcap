//! Structured logging for the pancake CLI.
//!
//! Default destination is stderr. The CapTP lab TUI installs a process divert
//! for the whole alt-screen lifetime so *every* `info`/`err` (including
//! callers that only have `std.Io`) lands in the transcript — never beside
//! the cursor.
const std = @import("std");

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

/// Write raw bytes through divert when active; otherwise stderr.
pub fn writeMsg(io: std.Io, msg: []const u8) void {
    if (divert) |d| {
        d.writeFn(d.ptr, msg);
        return;
    }
    std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
}

pub fn info(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "pancake: " ++ fmt ++ "\n", args) catch return;
    writeMsg(io, msg);
}

pub fn err(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "pancake: error: " ++ fmt ++ "\n", args) catch return;
    writeMsg(io, msg);
}
