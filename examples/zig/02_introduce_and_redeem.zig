//! Chapter 02 — an introduction: the capability pattern pancake exists for.
//!
//! Chapter 01 held one connection. This chapter holds several, because that is
//! where object-capability networking earns its keep: a directory you already
//! trust *introduces* you to a service it knows, and after the introduction
//! you talk to the service directly — the directory drops out of the path, and
//! no name, address book, or ambient registry was ever consulted. On the wire
//! this is OCapN's three-party handoff; in the API it is three small things:
//!
//!   1. `driver.Host` — the multi-connection tier (ADR-0068). One host holds
//!      one identity, and every connection it dials or accepts shares it, so a
//!      gift addressed to "the peer I met on this session" stays redeemable on
//!      the fresh connection the redeem opens.
//!   2. The `.give` outcome — a `call` whose answer is an introduction settles
//!      as `Settled.give`, carrying the signed gift envelope and the address
//!      of the peer that really hosts the capability.
//!   3. `Host.redeem` — one blocking call that dials that peer, withdraws the
//!      gift, and hands back an ordinary reference. Sends to it route to the
//!      right connection by themselves.
//!
//! The gifter needs no handoff code at all: its introducer actor simply
//! *returns* the foreign capability it holds, and the host turns that reply
//! into a signed gift because the reply crosses connections. Three hosts run
//! here in one process over real loopback sockets: a widget service (the
//! exporter), a directory that knows it (the gifter), and a client that only
//! knows the directory (the recipient).

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const actors = pancake.actors;
const driver = pancake.driver;
const tcp = pancake.net.tcp;

const frame_cap = 4096;

/// The service being introduced. It never learns about the directory's
/// clients; whoever holds a reference can poke it, and nobody else can.
const Widget = struct {
    pub fn handle(self: *Widget, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "poke")) return error.NoSuchMethod;
        return .{ .string = "poked — directly, the directory is out of the path" };
    }
};

/// The directory's introducer: it holds a capability it fetched from the
/// widget service and answers `introduce` by returning it. That return is the
/// whole gifter side — the host sees the reply name a capability homed on
/// another connection and originates the signed gift itself.
const Introducer = struct {
    widget: actors.Ref,
    pub fn handle(self: *Introducer, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "introduce")) return error.NoSuchMethod;
        return .{ .reference = .{ .far = self.widget.far } };
    }
};

/// One bound address, published by the task that owns the listener and read
/// by the task that dials it.
const Addr = struct {
    buf: [64]u8 = undefined,
    len: std.atomic.Value(usize) = .init(0),

    fn publish(self: *Addr, designator: []const u8) void {
        @memcpy(self.buf[0..designator.len], designator);
        self.len.store(designator.len, .release);
    }
    fn wait(self: *Addr, io: std.Io) []const u8 {
        while (true) {
            const n = self.len.load(.acquire);
            if (n != 0) return self.buf[0..n];
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(2), .real) catch {};
        }
    }
};

const Shared = struct {
    widget_addr: Addr = .{},
    directory_addr: Addr = .{},
    directory_ready: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
};

/// The widget service: publish the widget on each accepted connection and
/// serve. It will accept two partners — the directory (which fetches the
/// widget to hold it) and, later, the client the directory introduced (whose
/// gift withdrawal and direct call both arrive here). Serving two connections
/// from one thread is a round-robin of bounded steps; a withdrawal that beats
/// its gift deposit simply parks until the deposit lands (ADR-0056).
fn widgetService(allocator: std.mem.Allocator, shared: *Shared) anyerror!void {
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var resident = tcp.Resident{ .io = io };
    var host = try driver.Host.init(allocator, io, &.{resident.netlayer()}, .{ .frame_cap = frame_cap });
    defer host.deinit();
    var server = try host.listen(resident.netlayer(), .{ .designator = "127.0.0.1:0" });
    defer server.close();
    var addr_buf: [64]u8 = undefined;
    shared.widget_addr.publish(server.localDesignator(&addr_buf));

    const to_directory = try server.accept();
    _ = try to_directory.publish("widget", Widget, .{});
    while (!shared.directory_ready.load(.acquire)) {
        _ = try to_directory.stepReadable(10);
    }
    const to_client = try server.accept();
    _ = try to_client.publish("widget", Widget, .{});
    while (!shared.done.load(.acquire)) {
        _ = try to_directory.stepReadable(5);
        _ = try to_client.stepReadable(5);
    }
}

/// The directory: fetch the widget (the host records where it lives), publish
/// an introducer that returns it, and serve. Origination happens inside
/// `stepReadable`'s serving, in the host's interceptor — there is no gifter
/// verb to call.
fn directory(allocator: std.mem.Allocator, shared: *Shared) anyerror!void {
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var resident = tcp.Resident{ .io = io };
    var host = try driver.Host.init(allocator, io, &.{resident.netlayer()}, .{ .frame_cap = frame_cap });
    defer host.deinit();

    const to_widget = try host.dial(tcp.at(shared.widget_addr.wait(io)));
    const widget = try to_widget.fetch("widget");

    var server = try host.listen(resident.netlayer(), .{ .designator = "127.0.0.1:0" });
    defer server.close();
    var addr_buf: [64]u8 = undefined;
    shared.directory_addr.publish(server.localDesignator(&addr_buf));
    shared.directory_ready.store(true, .release);

    const to_client = try server.accept();
    _ = try to_client.publish("introducer", Introducer, .{ .widget = widget });
    while (!shared.done.load(.acquire)) {
        _ = try to_client.stepReadable(5);
        _ = try to_widget.stepReadable(5);
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var shared = Shared{};
    var widget_task = try io.concurrent(widgetService, .{ allocator, &shared });
    var directory_task = try io.concurrent(directory, .{ allocator, &shared });
    defer {
        shared.done.store(true, .release);
        _ = widget_task.await(io) catch {};
        _ = directory_task.await(io) catch {};
    }

    // The client knows only the directory. It has never heard of the widget
    // service — no address, no name, nothing.
    var resident = tcp.Resident{ .io = io };
    var host = try driver.Host.init(allocator, io, &.{resident.netlayer()}, .{ .frame_cap = frame_cap });
    defer host.deinit();
    const to_directory = try host.dial(tcp.at(shared.directory_addr.wait(io)));
    const introducer = try to_directory.fetch("introducer");

    // Ask for an introduction. The answer is not a value and not a broken
    // promise: it is the third outcome, a gift to redeem.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const settled = try to_directory.call(introducer, .{ .verb = "introduce", .args = &.{} }, arena.allocator());
    const give = switch (settled) {
        .give => |g| g,
        .fulfilled, .broken => return error.ExpectedAnIntroduction,
    };
    std.debug.print("02: introduced to a capability hosted at {s}\n", .{give.exporter_locator_uri});

    // Redeem it: the host dials the widget service, withdraws the gift under
    // its own identity, and returns an ordinary reference.
    const widget = try host.redeem(to_directory, give);

    // Call it. The send routes to the widget service's connection by itself —
    // the directory is no longer in the path.
    switch (try to_directory.call(widget, .{ .verb = "poke", .args = &.{} }, arena.allocator())) {
        .fulfilled => |arg| std.debug.print("02: {s}\n", .{arg.string}),
        .broken => |reason| {
            std.debug.print("02: poke broke: {s}\n", .{reason});
            return error.PokeBroke;
        },
        .give => return error.ExpectedAValue,
    }
}
