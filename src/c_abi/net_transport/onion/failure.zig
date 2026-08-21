//! Stable C result projection for onion lifecycle failures.

const net = @import("net");
const c = @import("c_abi_shared");

pub fn providerDial(err: net.netlayer.DialError) i32 {
    return switch (err) {
        error.InvalidAddress => c.PANCAKE_ERR_INVALID_ARGUMENT,
        else => c.PANCAKE_ERR_IO,
    };
}

pub fn providerListen(err: anyerror) i32 {
    return switch (err) {
        error.InvalidAddress, error.InvalidOptions => c.PANCAKE_ERR_INVALID_ARGUMENT,
        error.OutOfMemory => c.PANCAKE_ERR_INTERNAL,
        else => c.PANCAKE_ERR_IO,
    };
}

pub fn dial(err: net.netlayer.DialError) i32 {
    return switch (err) {
        error.InvalidAddress => result(c.PANCAKE_ERR_INVALID_ARGUMENT, "connect: not a well-formed version 3 onion service id, or an unusable socks endpoint"),
        error.ConnectionRefused => result(c.PANCAKE_ERR_IO, "connect: nothing is listening at the configured tor socks endpoint"),
        error.NetworkUnreachable => result(c.PANCAKE_ERR_IO, "connect: tor could not reach that onion service"),
        error.TimedOut => result(c.PANCAKE_ERR_IO, "connect: timed out reaching tor"),
        error.OutOfMemory => c.PANCAKE_ERR_INTERNAL,
        else => blk: {
            c.setLastError("connect: onion dial failed: {s}", .{@errorName(err)});
            break :blk c.PANCAKE_ERR_IO;
        },
    };
}

pub fn listen(err: anyerror) i32 {
    return switch (err) {
        error.InvalidAddress => result(c.PANCAKE_ERR_INVALID_ARGUMENT, "listen: no control endpoint configured, so this netlayer can dial but not host"),
        error.InvalidOptions => c.PANCAKE_ERR_INVALID_ARGUMENT,
        error.BindFailed => result(c.PANCAKE_ERR_IO, "listen: tor refused the service, or the local forward endpoint could not be bound"),
        error.OutOfMemory => c.PANCAKE_ERR_INTERNAL,
        else => blk: {
            c.setLastError("listen: onion listener failed: {s}", .{@errorName(err)});
            break :blk c.PANCAKE_ERR_IO;
        },
    };
}

pub fn accept(err: net.netlayer.AcceptError) i32 {
    return switch (err) {
        error.ConnectionLost => result(c.PANCAKE_ERR_IO, "accept: onion listener closed"),
        error.SocketConfigurationFailed => result(c.PANCAKE_ERR_IO, "accept: transport socket configuration failed"),
        error.WakeNudgeFailed => result(c.PANCAKE_ERR_IO, "accept: onion listener wake failed"),
        error.WakeDrainFailed => result(c.PANCAKE_ERR_IO, "accept: onion listener wake drain failed"),
        error.OutOfMemory => c.PANCAKE_ERR_INTERNAL,
    };
}

fn result(code: i32, message: []const u8) i32 {
    c.setLastError("{s}", .{message});
    return code;
}
