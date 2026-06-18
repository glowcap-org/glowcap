//! `driver.LoopDialer` end to end: the completion loop as the client fan-out
//! surface above `net`, paired with the existing blocking host API.

const std = @import("std");
const builtin = @import("builtin");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const actors = pancake.actors;
const driver = pancake.driver;
const tcp = pancake.net.tcp;

const ip = std.Io.net;

const frame_cap = 4096;
const client_count = 6;

const Greeter = struct {
    pub fn handle(self: *Greeter, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        if (!std.mem.eql(u8, msg.verb, "greet")) return error.NoSuchMethod;
        if (msg.args.len != 1) return error.BadInvocation;
        const who = switch (msg.args[0]) {
            .string => |s| s,
            else => return error.BadInvocation,
        };
        return .{ .string = try std.fmt.allocPrint(turn.arena, "hello {s} from the dialer", .{who}) };
    }
};

const ServeState = struct {
    delivers: usize = 0,

    fn countDeliver(ctx: ?*anyopaque, _: *driver.ConnectedVat, event: *engine.Event) anyerror!bool {
        const self: *ServeState = @ptrCast(@alignCast(ctx.?));
        if (event.kind() == .deliver) self.delivers += 1;
        return false;
    }
};

fn serveOne(listener: *tcp.Listener, allocator: std.mem.Allocator) anyerror!void {
    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    var cv = try driver.acceptTcp(allocator, &peer, listener, read_buf, write_buf);
    defer cv.deinit();
    _ = try cv.publish("greeter", Greeter, .{});

    var state = ServeState{};
    cv.serve_options = .{ .hook_ctx = &state, .before_serve = ServeState.countDeliver };
    while (state.delivers < 2) {
        const progress = try cv.step();
        if (progress == .closed) return error.ConnectionClosed;
    }
    try cv.flush();
}

const ServerCtx = struct {
    listener: *tcp.Listener,
    allocator: std.mem.Allocator,
    err: ?anyerror = null,
};

fn serveMany(ctx: *ServerCtx) void {
    for (0..client_count) |_| {
        serveOne(ctx.listener, ctx.allocator) catch |err| {
            if (ctx.err == null) ctx.err = err;
            return;
        };
    }
}

const Shared = struct {
    allocator: std.mem.Allocator,
    replies: usize = 0,
    err: ?anyerror = null,
};

const Flow = struct {
    client: *driver.LoopDialer.Client,
    shared: *Shared,

    fn onFetch(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *Flow = @ptrCast(@alignCast(ctx.?));
        const greeter = switch (resolution) {
            .fulfilled => |arg| switch (arg) {
                .reference => |reference| switch (reference) {
                    .far => |far| far,
                    else => {
                        self.shared.err = error.FetchFailed;
                        return;
                    },
                },
                else => {
                    self.shared.err = error.FetchFailed;
                    return;
                },
            },
            .broken => {
                self.shared.err = error.FetchFailed;
                return;
            },
        };
        const promise = self.client.send(.{ .far = greeter }, .{
            .verb = "greet",
            .args = &.{.{ .string = "pancake" }},
        }) catch |err| {
            self.shared.err = err;
            return;
        };
        self.client.on(promise, .{ .ctx = self, .func = Flow.onReply }) catch |err| {
            self.shared.err = err;
            return;
        };
    }

    fn onReply(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *Flow = @ptrCast(@alignCast(ctx.?));
        defer self.shared.allocator.destroy(self);
        switch (resolution) {
            .fulfilled => |arg| {
                if (arg == .string and std.mem.eql(u8, arg.string, "hello pancake from the dialer")) {
                    self.shared.replies += 1;
                } else {
                    self.shared.err = error.BadReply;
                }
            },
            .broken => self.shared.err = error.CallBroke,
        }
    }
};

fn startClient(ctx: ?*anyopaque, client: *driver.LoopDialer.Client) anyerror!void {
    const shared: *Shared = @ptrCast(@alignCast(ctx.?));
    const flow = try shared.allocator.create(Flow);
    flow.* = .{ .client = client, .shared = shared };
    errdefer shared.allocator.destroy(flow);
    try client.fetch("greeter", .{ .ctx = flow, .func = Flow.onFetch });
}

fn runDialer(dialer: *driver.LoopDialer, until_closed: usize, out_err: *?anyerror) void {
    dialer.run(.{ .after_closed = until_closed }) catch |err| {
        out_err.* = err;
    };
}

test "driver.LoopDialer: dialed clients fetch and call through the completion loop" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var listener = try tcp.Listener.bind(io, try ip.IpAddress.parse("127.0.0.1", 0));
    defer listener.deinit();
    const address = listener.localAddress();

    var server_ctx = ServerCtx{ .listener = &listener, .allocator = allocator };
    const server_thread = try std.Thread.spawn(.{}, serveMany, .{&server_ctx});

    var shared = Shared{ .allocator = allocator };
    var dialer = try driver.LoopDialer.init(io, allocator, .{
        .frame_cap = frame_cap,
        .max_conns = 16,
        .on_open = startClient,
        .on_open_ctx = &shared,
    });
    defer dialer.deinit();

    for (0..client_count) |_| _ = try dialer.dialTcp(address);

    var dialer_err: ?anyerror = null;
    const dialer_thread = try std.Thread.spawn(.{}, runDialer, .{ &dialer, @as(usize, client_count), &dialer_err });
    dialer_thread.join();
    server_thread.join();

    if (server_ctx.err) |err| return err;
    if (dialer_err) |err| return err;
    if (shared.err) |err| return err;
    try std.testing.expectEqual(@as(usize, client_count), shared.replies);
}

/// Journal of `LoopDialer.Options.on_close` firings. A refused dial is
/// observable only here: `dialTcp` returns before the connect resolves, so
/// the close hook with `opened == false` is the dialer's failure surface.
const CloseState = struct {
    closes: usize = 0,
    opened_closes: usize = 0,
    client_was_null: bool = false,

    fn onClose(ctx: ?*anyopaque, client: ?*driver.LoopDialer.Client, opened: bool) void {
        const self: *CloseState = @ptrCast(@alignCast(ctx.?));
        self.closes += 1;
        if (opened) self.opened_closes += 1;
        if (client == null) self.client_was_null = true;
    }
};

test "driver.LoopDialer: a refused dial fires on_close with opened == false and no client" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Bind and immediately tear down a listener so the port is known-refusing.
    var listener = try tcp.Listener.bind(io, try ip.IpAddress.parse("127.0.0.1", 0));
    const address = listener.localAddress();
    listener.deinit();

    var state = CloseState{};
    var dialer = try driver.LoopDialer.init(io, allocator, .{
        .frame_cap = frame_cap,
        .max_conns = 1,
        .on_close = CloseState.onClose,
        .on_close_ctx = &state,
    });
    defer dialer.deinit();

    const slot: driver.LoopDialer.Slot = try dialer.dialTcp(address);
    _ = slot; // valid only until the close below recycles it
    try dialer.run(.{ .after_closed = 1 });

    // The refused dial surfaced exactly once, never opened, and carried no
    // client surface (no vat was ever built for it).
    try std.testing.expectEqual(@as(usize, 1), state.closes);
    try std.testing.expectEqual(@as(usize, 0), state.opened_closes);
    try std.testing.expect(state.client_was_null);
}
