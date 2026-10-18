//! The onion archive's last-error text for each lifecycle failure. The C
//! result is the shared netlayer table's (`c.netlayerFailureCode`), so this
//! file owns only the words an embedder reads back.

const net = @import("net");
const c = @import("c_abi_shared");

pub fn dial(err: net.netlayer.DialError) i32 {
    return describe("connect", err, switch (err) {
        error.InvalidAddress => "connect: not a well-formed version 3 onion service id, or an unusable socks endpoint",
        error.ConnectionRefused => "connect: nothing is listening at the configured tor socks endpoint",
        error.NetworkUnreachable => "connect: tor could not reach that onion service",
        error.TimedOut => "connect: timed out reaching tor",
        else => null,
    });
}

pub fn listen(err: anyerror) i32 {
    return describe("listen", err, switch (err) {
        error.InvalidAddress => "listen: no control endpoint configured, so this netlayer can dial but not host",
        error.BindFailed => "listen: tor refused the service, or the local forward endpoint could not be bound",
        else => null,
    });
}

pub fn accept(err: net.netlayer.AcceptError) i32 {
    return describe("accept", err, switch (err) {
        error.ConnectionLost => "accept: onion listener closed",
        error.SocketConfigurationFailed => "accept: transport socket configuration failed",
        error.WakeNudgeFailed => "accept: onion listener wake failed",
        error.WakeDrainFailed => "accept: onion listener wake drain failed",
        else => null,
    });
}

/// Record `message`, or the classification by name when the verb has no
/// words for it, and return the shared code.
fn describe(comptime verb: []const u8, err: anyerror, message: ?[]const u8) i32 {
    if (message) |text|
        c.setLastError("{s}", .{text})
    else
        c.setLastError(verb ++ ": onion " ++ verb ++ " failed: {s}", .{@errorName(err)});
    return c.netlayerFailureCode(err);
}
