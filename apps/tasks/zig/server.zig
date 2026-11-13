//! The Tasks server: one shared board, saved in Loam, served over OCapN.
//!
//! Run: `glowcap-tasks-server --data=DIR [--port=N] [--transport=tcp]`. The
//! directory holds the board's SQLite store and must exist. The server listens
//! on encrypted Noise TCP and prints
//! `TASKS-SERVER-LISTENING <port> <name> <locator>` on stdout. A client dials
//! the locator and fetches the board by that name. Stop it and start it again
//! on the same directory, and the same name reaches the same board with every
//! task still on it, at the locator the new run prints.
//!
//! `--transport=tcp` listens in the clear instead, for a peer that speaks only
//! plain TCP, such as a Goblins vat.
const std = @import("std");
const glowcap = @import("glowcap");
/// The board's storage on Loam's default disk engine. The board test opens
/// the same.
pub const Storage = @import("storage.zig").Storage(@import("glowcap_loam_sqlite").Sqlite);
const sealed = @import("demo_sealed");
const driver = glowcap.driver;

/// A client that connects and then says nothing holds a slot for ten seconds.
pub const session_opts: driver.SessionOptions = .{ .frame_cap = 1 << 16, .handshake = .{ .ms = 10_000 }, .settle = .{ .ms = 10_000 } };
/// Connected clients beyond this wait until one leaves.
const max_sessions = 64;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    var port: u16 = 0;
    var data: ?[:0]const u8 = null;
    var cleartext = false;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--port=")) {
            port = std.fmt.parseInt(u16, arg["--port=".len..], 10) catch return usage("--port takes a number from 0 to 65535");
        } else if (std.mem.startsWith(u8, arg, "--data=")) {
            data = arg["--data=".len.. :0];
        } else if (std.mem.eql(u8, arg, "--transport=tcp")) {
            cleartext = true;
        } else if (std.mem.eql(u8, arg, "--transport=noise-tcp")) {
            cleartext = false;
        } else return usage("unknown argument");
    }
    const path = data orelse return usage("--data=DIR names the board's directory");
    if (path.len == 0) return usage("--data=DIR names the board's directory");

    const server = if (cleartext) try listenCleartext(allocator, io, port) else try sealed.listen(allocator, io, port, session_opts);
    defer server.deinit();

    var storage: Storage = undefined;
    try storage.open(allocator, io, server.runtime.core, path);
    defer storage.close() catch |err| std.debug.print("tasks-server: closing the store failed: {s}\n", .{@errorName(err)});

    var locator_buf: [sealed.locator_buf_len]u8 = undefined;
    const announced = try sealed.announce(server, &locator_buf);
    // The demo reads this line on stdout for the port, the board's name, and
    // the locator.
    var line_buf: [128 + sealed.locator_buf_len]u8 = undefined;
    try std.Io.File.stdout().writeStreamingAll(io, try std.mem.print(&line_buf, "TASKS-SERVER-LISTENING {d} {s} {s}\n", .{ announced.port, storage.name.slice(), announced.locator }));

    try serve(server, &storage, null);
}

/// Accept clients and run their calls and the board's storage work until
/// `stop` turns true, or forever without one. Waiting to accept steps the
/// whole runtime, so every connected client's calls run inside it.
pub fn serve(server: *driver.Server, storage: *Storage, stop: ?*const std.atomic.Value(bool)) !void {
    var sessions: [max_sessions]*driver.Session = undefined;
    var open: usize = 0;
    defer for (sessions[0..open]) |session| session.deinit();
    while (if (stop) |flag| !flag.load(.acquire) else true) {
        const wait: i32 = if (storage.attached.hasPendingWork()) 0 else 10;
        if (open == max_sessions) {
            _ = try server.runtime.stepAny(wait);
        } else if (try server.waitAcceptable(wait)) {
            // A client that fails to connect costs only its own session.
            if (admit(server)) |session| {
                sessions[open] = session;
                open += 1;
            }
        }
        try storage.pump();
        var kept: usize = 0;
        for (sessions[0..open]) |session| {
            if (session.closeOutcome() == .pending) {
                sessions[kept] = session;
                kept += 1;
            } else session.deinit();
        }
        open = kept;
    }
}

/// Listen on loopback in the clear, for a peer that speaks only plain TCP.
fn listenCleartext(allocator: std.mem.Allocator, io: std.Io, port: u16) !*driver.Server {
    var bind_buf: [glowcap.net.tcp.designator_buf_len]u8 = undefined;
    const bind = try std.mem.print(&bind_buf, "127.0.0.1:{d}", .{port});
    return driver.listen(allocator, io, .{ .symbols = &.{.tcp} }, glowcap.ocapn.model.transport.tcp, .{ .designator = bind }, .ephemeral, session_opts);
}

fn admit(server: *driver.Server) ?*driver.Session {
    const session = server.accept() catch |err| {
        std.debug.print("tasks-server: a client failed to connect: {s}\n", .{@errorName(err)});
        return null;
    };
    session.attend() catch |err| {
        std.debug.print("tasks-server: a client failed to connect: {s}\n", .{@errorName(err)});
        session.deinit();
        return null;
    };
    return session;
}

fn usage(reason: []const u8) error{InvalidArguments} {
    std.debug.print("tasks-server: {s}\nusage: glowcap-tasks-server --data=DIR [--port=N] [--transport=tcp]\n", .{reason});
    return error.InvalidArguments;
}
