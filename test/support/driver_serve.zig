//! The serving half of a driver loopback test: accept one partner, publish a
//! greeter, and serve until the partner leaves. A test with extra arms around
//! the accept or the publish keeps its own body.

const glowcap = @import("glowcap");

const driver = glowcap.driver;

/// The entry point a test hands to `io.concurrent`: accept one partner on the
/// bound `server`, publish `Greeter` as "greeter", and serve. The server is
/// bound before the client dials, so there is no accept-before-bind race.
pub fn serveOnceWith(comptime Greeter: type) fn (*driver.Server) anyerror!void {
    return struct {
        fn run(server: *driver.Server) anyerror!void {
            const session = try server.accept();
            defer session.deinit();
            _ = try session.publish("greeter", Greeter, .{});
            try session.serve();
        }
    }.run;
}
