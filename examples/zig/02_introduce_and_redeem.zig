//! 02 — An introduction: the capability pattern pancake exists for.
//!
//! Chapter 01 held one session between two peers. Here there are three, and
//! the point is what you do *not* write. A directory you already talk to
//! introduces you to a service on a different machine. You call the
//! directory; the answer that comes back is the service itself, live and
//! callable. Then you call the service directly and the directory is out of
//! the path — it cannot see the traffic, and it cannot revoke by eavesdropping
//! because it was never in the middle.
//!
//! On the wire this is OCapN's three-party handoff: the directory signs a
//! `desc:handoff-give` naming the widget host, your session dials that host,
//! proves it is the peer the give named, and withdraws the gifted capability.
//! None of that appears below. `connect`, `fetch`, and `call` are the whole
//! program, because every `driver.Session` rides a host that redeems the
//! introduction inside the call you were already waiting on (ADR-0090). The
//! same three verbs do the same thing in every language binding.
//!
//! What this costs to serve at scale — one thread, many connections — is
//! `many_sessions_one_loop.zig`, which performs this same handoff on the
//! completion-loop tier with the machinery visible.
//!
//! Run: `zig build examples` (it also runs under `zig build check`).

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const actors = pancake.actors;
const driver = pancake.driver;
const net = pancake.net;
const tcp = net.tcp;

const opts: driver.SessionOptions = .{
    .frame_cap = 8192,
    .handshake = .{ .ms = 10_000 },
    .settle = .{ .ms = 10_000 },
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
/// peer. Returning it is the whole introduction — the host sees that the
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
/// the gifter-facing Port; deposit retains that exact actor, and redemption
/// projects it on the recipient-facing Port without another name lookup.
fn serveWidget(server: *driver.Server, done: *std.atomic.Value(bool)) anyerror!void {
    try server.publishGiftable("widget", Widget, .{});

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
        }
        _ = directory_side.stepReadable(20) catch break;
    }
}

/// The directory host: fetch the widget from the widget host, then publish a
/// directory that hands that capability out. One `driver.PollHost` holds both
/// sessions, which is what lets a capability from one be introduced over the
/// other.
fn serveDirectory(
    allocator: std.mem.Allocator,
    io: std.Io,
    netlayers: []const net.netlayer.Netlayer,
    widget_designator: []const u8,
    listener: net.netlayer.Listener,
    done: *std.atomic.Value(bool),
) anyerror!void {
    var designator_buf: [64]u8 = undefined;
    const bound = listener.localDesignator(&designator_buf);

    var host = try driver.PollHost.init(allocator, io, netlayers, .ephemeral, opts);
    defer host.deinit();
    // The directory is dialable, so its gives can name it as their gifter.
    try host.core.setSelfDesignator(bound);

    var widget_loc_buf: [tcp.designator_buf_len]u8 = undefined;
    const to_widget = try host.connectLocator(tcp.locator(
        &widget_loc_buf,
        try tcp.parseDesignator(widget_designator),
    ));
    var widget_view = driver.Session.view(&host, to_widget);
    const widget = try widget_view.fetch("widget");

    const accepted = try host.acceptWire(listener, listener.transportName(), bound, bound);
    var client_view = driver.Session.view(&host, accepted);
    _ = try client_view.publish("directory", Directory, .{ .widget = widget });

    while (!done.load(.acquire)) {
        _ = client_view.stepReadable(20) catch break;
    }
    host.releaseWire(accepted);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tcp_resident = tcp.Resident{ .io = io };
    var done = std.atomic.Value(bool).init(false);

    var widget_host = try driver.listen(allocator, tcp_resident.netlayer(), .{ .designator = "127.0.0.1:0" }, .ephemeral, opts);
    defer widget_host.close() catch {};
    var widget_addr_buf: [64]u8 = undefined;
    const widget_designator = try allocator.dupe(u8, try widget_host.localDesignator(&widget_addr_buf));
    defer allocator.free(widget_designator);

    const netlayers = [_]net.netlayer.Netlayer{tcp_resident.netlayer()};

    var directory_listener = try tcp_resident.netlayer().listen(allocator, .{ .designator = "127.0.0.1:0" });
    defer directory_listener.close();
    var directory_addr_buf: [64]u8 = undefined;
    const directory_designator = directory_listener.localDesignator(&directory_addr_buf);

    var widget_future = try io.concurrent(serveWidget, .{ &widget_host, &done });
    var directory_future = try io.concurrent(serveDirectory, .{ allocator, io, &netlayers, widget_designator, directory_listener, &done });
    defer {
        done.store(true, .release);
        directory_future.await(io) catch {};
        widget_future.await(io) catch {};
    }

    // ── The client. This is the whole program. ───────────────────────────────
    var dir_loc_buf: [tcp.designator_buf_len]u8 = undefined;
    const session = try driver.connect(
        allocator,
        &netlayers,
        tcp.locator(&dir_loc_buf, try tcp.parseDesignator(directory_designator)),
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

    std.debug.print("02: introduced to a capability on another peer, redeemed inside the call\n", .{});
}
