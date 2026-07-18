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

/// Resolve a CapTP dial target. An `http(s)://…/locator` bootstrap is fetched
/// and its first line taken as the `ocapn://` URI (the rooms web UI serves it);
/// an `ocapn://` URI or bare designator passes through. Returns an owned string.
pub fn resolveLocator(io: Io, gpa: Allocator, locator: []const u8) ![]u8 {
    const is_http = std.mem.startsWith(u8, locator, "http://") or std.mem.startsWith(u8, locator, "https://");
    if (!is_http) return gpa.dupe(u8, locator);

    var client = std.http.Client{ .allocator = gpa, .io = io };
    defer client.deinit();
    var body = std.Io.Writer.Allocating.init(gpa);
    defer body.deinit();
    const result = client.fetch(.{ .location = .{ .url = locator }, .response_writer = &body.writer }) catch {
        return error.BootstrapFailed;
    };
    if (result.status != .ok) return error.BootstrapFailed;
    const text = body.writer.buffered();
    var lines = std.mem.splitScalar(u8, text, '\n');
    const first = std.mem.trim(u8, lines.next() orelse "", " \t\r\n");
    if (first.len == 0) return error.BootstrapEmpty;
    return gpa.dupe(u8, first);
}

/// Agent-facing JSON and usage text go to stdout; diagnostics use `log` (stderr).
pub fn emitStdout(io: Io, bytes: []const u8) void {
    Io.File.stdout().writeStreamingAll(io, bytes) catch {};
}

pub fn emitStdoutFmt(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [16384]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    emitStdout(io, msg);
}
