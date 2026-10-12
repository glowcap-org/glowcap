//! 02: An introduction, the capability pattern glowcap exists for.
//!
//! Chapter 01 held one session between two peers. Here there are three, and
//! the point is what you do *not* write. A directory you already talk to
//! introduces you to a service on a different machine. You call the
//! directory. The answer that comes back is the service itself, live and
//! callable. Then you call the service directly. The directory carries the
//! introduction, but sits outside the later call path. This direct introduction
//! gives it no authority to inspect or revoke your service reference.
//!
//! All three sessions use encrypted Noise TCP. Each dialer authenticates the
//! listener's key. On the wire the introduction is a three-party handoff.
//! `connect`, `fetch`, and `call` are the whole program: every `driver.Session`
//! rides a host that redeems the introduction inside the call you were already
//! waiting on. The same three verbs do the same thing in every language binding.
//!
//! What this costs to serve at scale, one thread, many connections, is
//! `many_sessions_one_loop.zig`, which performs this same handoff on the
//! completion-loop tier with the machinery visible.
//!
//! Run: `zig build examples` (it also runs under `zig build check`).

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const actors = glowcap.actors;
const driver = glowcap.driver;

const opts: driver.SessionOptions = .{
    .frame_cap = 8192,
    .handshake = driver.default_handshake_budget,
    .settle = driver.default_settle_budget,
};

/// The widget: the service the client ends up talking to directly. It never
/// learns that an introduction happened.
const Widget = struct {
    pub fn handle(self: *Widget, ht: *driver.HostTurn, verb: []const u8, args: []const driver.Value) !driver.Value {
        _ = self;
        _ = ht;
        _ = args;
        if (!std.mem.eql(u8, verb, "spin")) return error.NoSuchMethod;
        return .{ .string = "widget spun" };
    }
};

/// The directory: answers `lookup` with a capability that lives on *another*
/// peer. Returning it is the whole introduction, the host sees that the
/// capability's home is a different session and signs a give instead of a
/// plain reference. The actor writes no handoff code, and holds no wire
/// position: the capability it hands out is the same opaque value it fetched.
const Directory = struct {
    widget: driver.Capability,

    pub fn handle(self: *Directory, ht: *driver.HostTurn, verb: []const u8, args: []const driver.Value) !driver.Value {
        _ = ht;
        _ = args;
        if (!std.mem.eql(u8, verb, "lookup")) return error.NoSuchMethod;
        return .{ .capability = self.widget };
    }
};

/// The widget host. It is registered once in the Host Vat. Fetch projects it on
/// the gifter-facing Port, deposit retains that exact actor, and redemption
/// projects it on the recipient-facing Port without another name lookup.
fn serveWidget(server: *driver.Server, done: *std.atomic.Value(bool)) anyerror!void {
    try server.publish("widget", Widget, .{});

    var directory_side = try server.accept();
    defer directory_side.deinit();

    var client_side: ?*driver.Session = null;
    defer if (client_side) |s| s.deinit();

    while (!done.load(.acquire)) {
        // The redeem still has to be accepted. Lazy projection gives a
        // host-wide object a wire name only after this connection exists; it
        // does not answer the door.
        if (client_side == null and try server.waitAcceptable(20)) {
            client_side = try server.accept();
            try client_side.?.attend();
        }
        _ = try directory_side.stepReadable(20);
    }
}

/// The directory host: fetch the widget from the widget host, then publish a
/// directory that hands that capability out. One `driver.Server` holds both
/// sessions, so a capability from one can be introduced over the other, and
/// its gives name the directory's own advertised locator as their gifter.
fn serveDirectory(
    directory: *driver.Server,
    widget_locator: model.PeerLocator,
    done: *std.atomic.Value(bool),
) anyerror!void {
    const to_widget = try directory.runtime.connectLocator(widget_locator, .inherit);
    const widget_view = try driver.Session.adopt(directory.runtime, to_widget);
    defer widget_view.deinit();
    const widget = try widget_view.fetch("widget");

    const client_view = try directory.accept();
    defer client_view.deinit();
    _ = try client_view.publish("directory", Directory, .{ .widget = widget });

    while (!done.load(.acquire)) {
        _ = try client_view.stepReadable(20);
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var done = std.atomic.Value(bool).init(false);

    var widget_host = try driver.listen(allocator, io, .{ .symbols = &.{.noise_tcp} }, model.transport.noise_tcp, .{ .designator = "127.0.0.1:0" }, .{ .keyed = try driver.drawSessionSecret(io) }, opts);
    defer widget_host.deinit();
    const widget_locator = try model.clonePeerLocator(allocator, try widget_host.advertisedLocator());
    defer model.freePeerLocator(allocator, widget_locator);

    var directory_host = try driver.listen(allocator, io, .{ .symbols = &.{.noise_tcp} }, model.transport.noise_tcp, .{ .designator = "127.0.0.1:0" }, .{ .keyed = try driver.drawSessionSecret(io) }, opts);
    defer directory_host.deinit();
    const directory_locator = try model.clonePeerLocator(allocator, try directory_host.advertisedLocator());
    defer model.freePeerLocator(allocator, directory_locator);

    var widget_future = try io.concurrent(serveWidget, .{ widget_host, &done });
    var directory_future = try io.concurrent(serveDirectory, .{ directory_host, widget_locator, &done });
    var hosts_joined = false;
    defer if (!hosts_joined) {
        done.store(true, .release);
        // best-effort: unwind join only. The success path uses `try await`
        // before the print, so the error that got us here is the one reported.
        directory_future.await(io) catch {};
        widget_future.await(io) catch {};
    };

    // ── The client. This is the whole program. ───────────────────────────────
    const session = try driver.connect(
        allocator,
        io,
        .{ .symbols = &.{.noise_tcp} },
        directory_locator,
        .ephemeral,
        opts,
    );
    defer session.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const directory = try session.fetch("directory");

    // The answer is an introduction to a capability on the widget host. By the
    // time this call returns, this session has dialed that host, proved its
    // identity, and withdrawn the capability: `settled` is the widget itself.
    const settled = try session.call(directory, "lookup", &.{}, arena);
    if (settled != .fulfilled or settled.fulfilled != .capability) return error.NoIntroduction;
    const widget = settled.fulfilled.capability;

    // And it answers. This call does not touch the directory: it rides the
    // session that was dialed to the widget host during the call above.
    const spun = try session.call(widget, "spin", &.{}, arena);
    if (spun != .fulfilled or spun.fulfilled != .string) return error.WidgetRefused;
    if (!std.mem.eql(u8, spun.fulfilled.string, "widget spun")) return error.UnexpectedReply;

    done.store(true, .release);
    try directory_future.await(io);
    try widget_future.await(io);
    hosts_joined = true;
    if (directory_host.close()) |failure| return failure.cause;
    if (widget_host.close()) |failure| return failure.cause;

    std.debug.print("02: introduced to a capability on another peer, redeemed inside the call\n", .{});
}
