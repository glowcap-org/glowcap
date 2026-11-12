//! The echo actor the resident proofs publish, and the loop that serves it.
//! `ping` answers with the reply a proof names, so the call that comes back
//! proves which server answered over the transport under test.

const std = @import("std");
const wait = @import("../../support/wait.zig");
const glowcap = @import("glowcap");
const driver = glowcap.driver;

/// `Echo` answers `ping` with `reply`. `serve` accepts one session, publishes
/// the actor as `echo`, and steps the session until `done` is set or the peer
/// hangs up.
pub fn EchoServer(comptime reply: []const u8) type {
    return struct {
        pub const Echo = struct {
            pub fn handle(_: *Echo, ht: *driver.HostTurn, selector: ?[]const u8, args: driver.Args) !driver.Value {
                defer ht.releaseArguments(args);
                const verb = selector orelse return error.NoSuchMethod;
                if (!std.mem.eql(u8, verb, "ping")) return error.NoSuchMethod;
                return .{ .string = reply };
            }
        };

        pub fn serve(server: *driver.Server, done: *std.atomic.Value(bool)) anyerror!void {
            if (!try wait.acceptableUnlessStopped(server, done)) return;
            var session = try server.accept();
            defer session.deinit();
            _ = try session.publish("echo", Echo, .{});
            while (!done.load(.acquire)) {
                _ = session.stepReadable(20) catch |err| switch (err) {
                    error.ConnectionClosed, error.ProtocolAbort => break,
                    else => |e| return e,
                };
            }
        }
    };
}
