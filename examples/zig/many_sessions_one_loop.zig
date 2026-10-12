//! Many sessions on one thread, with a handoff crossing them.
//!
//! Chapter 02 shows one client receiving an introduction. This program
//! serves sixteen clients at once from one directory thread, through the same
//! application surface: a `driver.Server` accepts every client on its one
//! runtime, and each client's `call` settles as the introduced widget. Each
//! client then calls the widget directly, on a session its own runtime dialed
//! to the widget host while the call was in flight.
//!
//! Three roles in one process: the widget host (exporter), the directory
//! (gifter), and the clients (recipients). The widget host and the directory
//! each serve from one thread. Each client runs its own `driver.Session`.
//!
//! Run: `zig build examples` (it also runs under `zig build check`).

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const driver = glowcap.driver;

const clients = 16;

const opts: driver.SessionOptions = .{
    .frame_cap = 4096,
    .handshake = .{ .ms = 15_000 },
    .settle = .{ .ms = 15_000 },
};

const Widget = struct {
    pub fn handle(_: *Widget, _: *driver.HostTurn, verb: []const u8, _: []const driver.Value) !driver.Value {
        if (!std.mem.eql(u8, verb, "poke")) return error.NoSuchMethod;
        return .{ .string = "poked: directly, the directory is out of the path" };
    }
};

const Directory = struct {
    widget: driver.Capability,

    pub fn handle(self: *Directory, _: *driver.HostTurn, verb: []const u8, _: []const driver.Value) !driver.Value {
        if (!std.mem.eql(u8, verb, "lookup")) return error.NoSuchMethod;
        return .{ .capability = self.widget };
    }
};

/// Every session either host accepts: each client dials the directory and
/// redeems at the widget host, which also serves the directory's own session.
const max_sessions = clients + 1;

/// Serve every session `server` accepts from this one thread until `done`.
fn serveAll(server: *driver.Server, done: *std.atomic.Value(bool)) anyerror!void {
    var sessions: [max_sessions]*driver.Session = undefined;
    var accepted: usize = 0;
    defer for (sessions[0..accepted]) |session| session.deinit();
    while (!done.load(.acquire)) {
        if (accepted < max_sessions and try server.waitAcceptable(0)) {
            sessions[accepted] = try server.accept();
            accepted += 1;
            // An accepted session dispatches nothing until its owner attends.
            try sessions[accepted - 1].attend();
            continue;
        }
        _ = try server.runtime.stepAny(10);
    }
}

/// The directory: fetch the widget from its host over this Server's own
/// runtime, publish a directory that hands it out, then serve every client.
/// One runtime holds the widget session and every client session, so the
/// introduction it answers with names a session it owns.
fn serveDirectory(
    directory: *driver.Server,
    widget_locator: model.PeerLocator,
    ready: *std.atomic.Value(bool),
    done: *std.atomic.Value(bool),
) anyerror!void {
    defer ready.store(true, .release);
    const to_widget = try directory.runtime.connectLocator(widget_locator, .inherit);
    const widget_view = try driver.Session.adopt(directory.runtime, to_widget);
    defer widget_view.deinit();
    const widget = try widget_view.fetch("widget");
    try directory.publish("directory", Directory, .{ .widget = widget });
    ready.store(true, .release);
    try serveAll(directory, done);
}

/// One client: ask the directory for the widget, then poke it directly.
fn client(io: std.Io, allocator: std.mem.Allocator, directory_locator: model.PeerLocator) anyerror!void {
    const session = try driver.connect(allocator, io, .{ .symbols = &.{.tcp} }, directory_locator, .ephemeral, opts);
    defer session.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const directory = try session.fetch("directory");
    // The answer is an introduction to the widget host. By the time this call
    // returns, this client has dialed that host, proved its identity, and
    // withdrawn the widget.
    const widget = switch (try session.call(directory, "lookup", &.{}, arena.allocator())) {
        .fulfilled => |value| if (value == .capability) value.capability else return error.NoIntroduction,
        .broken => return error.NoIntroduction,
    };
    switch (try session.call(widget, "poke", &.{}, arena.allocator())) {
        .fulfilled => |value| if (value != .string) return error.WidgetRefused,
        .broken => return error.WidgetRefused,
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var done = std.atomic.Value(bool).init(false);

    var widget_host = try driver.listen(allocator, io, .{ .symbols = &.{.tcp} }, model.transport.tcp, .{ .designator = "127.0.0.1:0" }, .ephemeral, opts);
    defer widget_host.deinit();
    try widget_host.publish("widget", Widget, .{});
    const widget_locator = try model.clonePeerLocator(allocator, try widget_host.advertisedLocator());
    defer model.freePeerLocator(allocator, widget_locator);

    var directory_host = try driver.listen(allocator, io, .{ .symbols = &.{.tcp} }, model.transport.tcp, .{ .designator = "127.0.0.1:0" }, .ephemeral, opts);
    defer directory_host.deinit();
    const directory_locator = try model.clonePeerLocator(allocator, try directory_host.advertisedLocator());
    defer model.freePeerLocator(allocator, directory_locator);

    var directory_ready = std.atomic.Value(bool).init(false);
    var widget_future = try io.concurrent(serveAll, .{ widget_host, &done });
    var directory_future = try io.concurrent(serveDirectory, .{ directory_host, widget_locator, &directory_ready, &done });
    var hosts_joined = false;
    defer if (!hosts_joined) {
        done.store(true, .release);
        // best-effort: unwind join only. The success path awaits with `try`,
        // so the error that got us here is the one reported.
        directory_future.await(io) catch {};
        widget_future.await(io) catch {};
    };
    while (!directory_ready.load(.acquire)) try std.Io.sleep(io, .fromMilliseconds(2), .real);

    // ── The clients, all at once. ────────────────────────────────────────────
    var futures: [clients]@TypeOf(io.concurrent(client, .{ io, allocator, directory_locator }) catch unreachable) = undefined;
    var started: usize = 0;
    var first_err: ?anyerror = null;
    while (started < clients) : (started += 1) {
        futures[started] = io.concurrent(client, .{ io, allocator, directory_locator }) catch |err| {
            first_err = err;
            break;
        };
    }
    for (futures[0..started]) |*future| future.await(io) catch |err| {
        if (first_err == null) first_err = err;
    };

    done.store(true, .release);
    hosts_joined = true;
    const directory_result = directory_future.await(io);
    const widget_result = widget_future.await(io);
    if (first_err) |err| return err;
    try directory_result;
    try widget_result;
    std.debug.print("many-sessions: {d} clients introduced to the widget by one directory thread, each poked it directly\n", .{clients});
}
