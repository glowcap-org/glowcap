//! Shared constants and stdout emit for `pancake app rooms-peer`.
const std = @import("std");
const pancake = @import("pancake");
const iroh = @import("iroh");

pub const Io = std.Io;
pub const Allocator = std.mem.Allocator;
pub const model = pancake.ocapn.model;
pub const actors = pancake.actors;
pub const driver = pancake.driver;
pub const net = pancake.net;

pub const Host = driver.core.Host;
pub const HostSession = driver.core.HostSession;
pub const IrohLoop = net.completion.Loop(iroh.Backend, iroh.DialResolver);
pub const IrohBridge = driver.Bridge(IrohLoop);

pub const frame_cap: usize = 1 << 16;
pub const timer_ms: u64 = 150;
pub const redial_cooldown_wakes: u32 = 13;
pub const dial_timeout_ms: u64 = 4000;
pub const file_cap = Io.Limit.limited(1 << 24);
pub const default_locator = "http://pancake-rooms:8000/locator";
pub const reply_placeholder = "YOUR REPLY HERE";
pub const replied_cap: usize = 1200;

/// Agent-facing JSON and usage text go to stdout; diagnostics use `log` (stderr).
pub fn emitStdout(io: Io, bytes: []const u8) void {
    Io.File.stdout().writeStreamingAll(io, bytes) catch {};
}

pub fn emitStdoutFmt(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [16384]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    emitStdout(io, msg);
}
