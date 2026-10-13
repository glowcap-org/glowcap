//! Standalone host for the accountability-on-glowcap application.
//!
//! Listens on 127.0.0.1, an ephemeral port by default or the one named by
//! `--port=N`. It prints the port so a foreign caller can connect, then serves
//! one connection: publishes the Affordance under the name "affordance",
//! processes invocations, and exits when the caller leaves.
//!
//! The cross-seam demo script starts this, reads the port, and points
//! its Deno or Python caller at it. The caller fetches the Affordance
//! by name.

const std = @import("std");
const glowcap = @import("glowcap");

const identity = @import("identity.zig");
const accountable = @import("accountable.zig");
const affordance = @import("affordance.zig");

/// Finite budgets for the accept below: a stranger who connects and then
/// stays silent holds this server's accept for ten seconds, not for as long
/// as it likes.
const session_opts: driver.SessionOptions = .{
    .frame_cap = frame_cap,
    .handshake = .{ .ms = 10_000 },
    .settle = .{ .ms = 10_000 },
};

const model = glowcap.ocapn.model;
const driver = glowcap.driver;
const tcp = glowcap.net.tcp;

const AFFORDANCE_NAME = affordance.AFFORDANCE_NAME;
const frame_cap = affordance.frame_cap;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const data_root = affordance.dataRoot(init);
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var host_id = try identity.Identity.incept(allocator, io);
    defer host_id.deinit();

    const host_data_dir = try std.fmt.allocPrint(allocator, "{s}/host", .{data_root});
    defer allocator.free(host_data_dir);
    var store = try accountable.Store.init(allocator, io, &host_id, host_data_dir);
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

    var bind_buf: [tcp.designator_buf_len]u8 = undefined;
    const bind_designator = try std.fmt.bufPrint(&bind_buf, "127.0.0.1:{d}", .{bind_port});
    var server = try driver.listen(allocator, io, .{ .symbols = &.{.tcp} }, model.transport.tcp, .{ .designator = bind_designator }, .ephemeral, session_opts);
    defer server.deinit();
    var bound_buf: [tcp.designator_buf_len]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&bound_buf));
    const port: u16 = switch (address) {
        .ip4 => |a| a.port,
        .ip6 => |a| a.port,
    };

    // The orchestrator parses this line to learn the port.
    std.debug.print("ACCOUNTABILITY-HOST-LISTENING {d}\n", .{port});

    var served: usize = 0;

    // The host and its foreign callers (Deno, Python) establish a real OCapN
    // session: the accept completes the keyed `op:start-session` handshake,
    // the same exchange the application surface and a live Goblins peer
    // require.
    var vat = try server.accept();
    defer vat.deinit();

    _ = try vat.publish(AFFORDANCE_NAME, affordance.HostAffordance, .{
        .state = .{
            .store = &store,
            .served = &served,
        },
    });

    try vat.serve();

    std.debug.print("ACCOUNTABILITY-HOST-SERVED {d}\n", .{served});
}
