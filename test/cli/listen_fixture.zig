//! The one-shot listener the in-process CapTP cases drive: a host context
//! with a fixed identity seed, `cmdListen` run on a concurrent future, and a
//! bounded wait for the locator it publishes.

const std = @import("std");
const cli = @import("cli");
const glowcap = @import("glowcap");

const Ctx = cli.ctx.Ctx;

fn testSecret(seed: u8) glowcap.foundation.crypto.SecretKey {
    return glowcap.foundation.crypto.SecretKey.fromSeed(@as([32]u8, @splat(seed)));
}

pub fn makeCtx(io: std.Io, gpa: std.mem.Allocator, environ: *const std.process.Environ.Map, seed: u8) Ctx {
    return .{
        .io = io,
        .gpa = gpa,
        .environ = environ,
        .front = .argv,
        .json = .json,
        .secret = testSecret(seed),
    };
}

pub const ListenArgs = struct {
    ctx: *Ctx,
    parsed: *cli.cmd_types.Parsed,
};

pub fn runListen(args: *ListenArgs) !u8 {
    return cli.ocapn.cmdListen(args.ctx, args.parsed);
}

pub fn waitListenLocator(host: *Ctx, host_future: anytype, io: std.Io) ![]const u8 {
    var spins: usize = 0;
    while (true) : (spins += 1) {
        if (host.publishedLocator()) |loc| return loc;
        if (spins > 50_000) {
            cli.signals.requestStop();
            // tolerant: the host's own error is replaced by the timeout error returned next, which names the failure.
            _ = host_future.await(io) catch {};
            return error.ListenLocatorTimeout;
        }
        std.Thread.yield() catch {};
    }
}
