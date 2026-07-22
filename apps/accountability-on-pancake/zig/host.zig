//! Standalone host for the accountability-on-pancake application.
//!
//! Listens on 127.0.0.1, an ephemeral port by default or the one named by
//! `--port=N`. It prints the port so a foreign caller can connect, then serves
//! one connection: publishes the Affordance under the name "affordance",
//! processes invocations, and exits when the caller leaves.
//!
//! The cross-seam demo script starts this, reads the port, and points
//! its Deno or Python caller at it; the caller fetches the Affordance
//! by name.

const std = @import("std");
const pancake = @import("pancake");

const identity = @import("identity.zig");
const accountable = @import("accountable.zig");
const affordance = @import("affordance.zig");

const engine = pancake.ocapn.engine;
const driver = pancake.driver;
const tcp = pancake.net.tcp;
const ip = std.Io.net;

const AFFORDANCE_NAME = affordance.AFFORDANCE_NAME;
const frame_cap = affordance.frame_cap;
const data_root = affordance.data_root;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var host_id = try identity.Identity.incept(allocator, io);
    defer host_id.deinit();

    var store = try accountable.Store.init(allocator, io, &host_id, data_root ++ "/host");
    defer store.deinit();

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // program name
    var bind_port: u16 = 0;
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--port=")) {
            bind_port = std.fmt.parseInt(u16, arg["--port=".len..], 10) catch {
                std.debug.print("accountability-host: --port must be an integer in 1..65535\n", .{});
                return error.BadPort;
            };
        } else {
            std.debug.print("accountability-host: unknown argument '{s}'\n", .{arg});
            return error.BadArgument;
        }
    }

    var listener = try tcp.Listener.bind(io, .{ .ip4 = ip.Ip4Address.loopback(bind_port) });
    defer listener.deinit();
    const address = listener.localAddress();
    const port: u16 = switch (address) {
        .ip4 => |a| a.port,
        .ip6 => |a| a.port,
    };

    // The orchestrator parses this line to learn the port.
    std.debug.print("ACCOUNTABILITY-HOST-LISTENING {d}\n", .{port});

    var served: usize = 0;

    // The host and its foreign callers (Deno, Python) establish a real OCapN
    // session: a negotiating peer that completes the keyed `op:start-session`
    // handshake, the same exchange the application surface and a live Goblins
    // peer require.
    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    var vat = try driver.acceptTcp(allocator, &peer, &listener, read_buf, write_buf);
    defer vat.deinit();

    _ = try vat.publish(AFFORDANCE_NAME, affordance.Affordance, .{
        .store = &store,
        .served = &served,
    });

    try vat.serve();

    std.debug.print("ACCOUNTABILITY-HOST-SERVED {d}\n", .{served});
}
