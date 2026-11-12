//! Standalone host for the accountability-on-glowcap application.
//!
//! Listens on 127.0.0.1 over encrypted Noise TCP, an ephemeral port by
//! default or the one named by `--port=N`. It prints its port and locator so
//! a caller in another language can connect, then serves one connection:
//! publishes the Affordance under the name "affordance", processes
//! invocations, and exits when the caller leaves.
//!
//! The cross-language demo script starts this, reads the locator, and points
//! its Deno or Python caller at it. The caller fetches the Affordance
//! by name.

const std = @import("std");
const glowcap = @import("glowcap");

const identity = @import("identity.zig");
const accountable = @import("accountable.zig");
const affordance = @import("affordance.zig");
const sealed = @import("demo_sealed");

/// Finite budgets for the accept below: a stranger who connects and then
/// stays silent holds this server's accept for ten seconds, not for as long
/// as it likes.
const session_opts: driver.SessionOptions = .{
    .frame_cap = frame_cap,
    .handshake = .{ .ms = 10_000 },
    .settle = .{ .ms = 10_000 },
};

const driver = glowcap.driver;

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

    var server = try sealed.listen(allocator, io, bind_port, session_opts);
    defer server.deinit();
    var locator_buf: [sealed.locator_buf_len]u8 = undefined;
    const announced = try sealed.announce(server, &locator_buf);

    // The orchestrator parses this line to learn the port and the locator.
    std.debug.print("ACCOUNTABILITY-HOST-LISTENING {d} {s}\n", .{ announced.port, announced.locator });

    var served: usize = 0;

    // The host and its callers in other languages (Deno, Python) establish a
    // real OCapN session: the accept completes the Noise handshake and the
    // keyed `op:start-session` exchange.
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
