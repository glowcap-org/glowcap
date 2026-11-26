//! A one-partner `listen` reports how its one session ended: the argv front
//! exits with a failed session's code, and the MCP front names its cause in
//! `listener_stopped`. Those partners send a frame past the listener's cap.
//! A client that exits before dialing still joins its listening fixture.

const std = @import("std");
const glowcap = @import("glowcap");
const Runtime = @import("runtime_fixture.zig").Runtime;
const cli = @import("cli");
const listen_fixture = @import("listen_fixture.zig");

const Ctx = cli.ctx.Ctx;
const makeCtx = listen_fixture.makeCtx;
const ListenArgs = listen_fixture.ListenArgs;
const runListen = listen_fixture.runListen;
const waitListenLocator = listen_fixture.waitListenLocator;

test "a one-shot listen exits with its partner's session failure" {
    const gpa = std.testing.allocator;
    var runtime: Runtime = undefined;
    runtime.init(gpa);
    defer runtime.deinit();
    const io = runtime.io();

    cli.signals.resetForTest();
    defer cli.signals.resetForTest();

    var host_capture: std.ArrayList(u8) = .empty;
    defer host_capture.deinit(gpa);
    var host = makeCtx(io, gpa, &runtime.environ, 31);
    defer host.deinit();
    host.sink = .{ .buffer = &host_capture };

    var listen_parsed = cli.cmd_types.Parsed{ .gpa = gpa };
    defer listen_parsed.deinit();
    try listen_parsed.setString("publish", "greeter");
    try listen_parsed.setString("bind", "127.0.0.1:0");

    var listen_args = ListenArgs{ .ctx = &host, .parsed = &listen_parsed };
    var host_future = try io.concurrent(runListen, .{&listen_args});
    defer listen_fixture.stopAndJoin(&host_future, io);
    const uri = try waitListenLocator(&host);

    var client = makeCtx(io, gpa, &runtime.environ, 32);
    defer client.deinit();
    try tellPastFrameCap(&client, uri);

    try std.testing.expectEqual(cli.exit_codes.protocol_abort, try host_future.await(io));
    try std.testing.expect(std.mem.find(u8, host_capture.items, "listen session: FrameTooLarge") != null);
}

test "a one-partner MCP listen reports its partner's session failure" {
    const gpa = std.testing.allocator;
    var runtime: Runtime = undefined;
    runtime.init(gpa);
    defer runtime.deinit();
    const io = runtime.io();

    var host_capture: std.ArrayList(u8) = .empty;
    defer host_capture.deinit(gpa);
    var host = makeCtx(io, gpa, &runtime.environ, 33);
    defer host.deinit();
    host.front = .mcp;
    host.sink = .{ .buffer = &host_capture };

    var listen_parsed = cli.cmd_types.Parsed{ .gpa = gpa };
    defer listen_parsed.deinit();
    try listen_parsed.setString("publish", "greeter");
    try listen_parsed.setString("bind", "127.0.0.1:0");
    try std.testing.expectEqual(cli.exit_codes.ok, try cli.ocapn.cmdListen(&host, &listen_parsed));

    var client = makeCtx(io, gpa, &runtime.environ, 34);
    defer client.deinit();
    try tellPastFrameCap(&client, host.publishedLocator().?);

    // The accept thread reads the oversized frame on its own cadence, so wait
    // for the stop it records rather than racing it.
    const listener = host.background_listener.?;
    var waited: usize = 0;
    while (listener.stop_reason.load(.acquire) == null) : (waited += 1) {
        if (waited > 200) return error.ListenerNeverRecordedItsStop;
        try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .real);
    }
    try std.testing.expectEqualStrings("FrameTooLarge", std.mem.span(listener.stop_reason.load(.acquire).?));
}

/// Dial `uri` admitting frames twice the default cap, then tell its `greeter`
/// one argument past the listener's cap, so the listener's session refuses
/// this partner with `FrameTooLarge`.
fn tellPastFrameCap(client: *Ctx, uri: []const u8) !void {
    var opts = cli.ocapn.sessionOpts();
    const cap = opts.frame_cap;
    opts.frame_cap = cap * 2;
    opts.wire_buffer_bytes = @max(opts.wire_buffer_bytes, cap * 2);
    const session = try cli.ocapn.dialUriWithOpts(client, uri, opts);
    defer session.deinit();
    const greeter = try session.fetch("greeter");
    const oversized = try client.gpa.alloc(u8, cap + 1);
    defer client.gpa.free(oversized);
    @memset(oversized, 'x');
    try session.tell(greeter, "greet", &.{.{ .string = oversized }});
}

test "a foreground listener releases its port when the client fixture exits early" {
    const gpa = std.testing.allocator;
    var runtime: Runtime = undefined;
    runtime.init(gpa);
    defer runtime.deinit();
    const io = runtime.io();
    cli.signals.resetForTest();
    defer cli.signals.resetForTest();

    var capture: std.ArrayList(u8) = .empty;
    defer capture.deinit(gpa);
    var host = makeCtx(io, gpa, &runtime.environ, 34);
    defer host.deinit();
    host.sink = .{ .buffer = &capture };
    var parsed: cli.cmd_types.Parsed = .{ .gpa = gpa };
    defer parsed.deinit();
    try parsed.setString("bind", "127.0.0.1:0");
    var args: ListenArgs = .{ .ctx = &host, .parsed = &parsed };
    try std.testing.expectError(error.ClientSetupFailed, leaveBeforeDial(&args));

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const peer = try glowcap.ocapn.model.uri.parsePeer(arena.allocator(), host.publishedLocator().?);
    const tcp = glowcap.net.tcp;
    var rebound = try tcp.Listener.bind(io, try tcp.parseDesignator(peer.designator));
    defer rebound.deinit();
}

fn leaveBeforeDial(args: *ListenArgs) !void {
    const io = args.ctx.io;
    var future = try io.concurrent(runListen, .{args});
    defer listen_fixture.stopAndJoin(&future, io);
    _ = try waitListenLocator(args.ctx);
    return error.ClientSetupFailed;
}
