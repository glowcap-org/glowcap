//! The glowcap exporter half of `glowcap_pair_gift_driver.zig`, as its own
//! process.
//!
//! It is a separate process for the same reason every Goblins peer in this
//! tree is: the peers talk over a real socket, and the run's outcome cannot
//! depend on how two runtimes in one process interleave.
//!
//! Publishes a greeter, prints `EXPORTER LISTENING <host:port>`, and
//! serves until killed. It prefers `glowcap-next` over Cap'n Proto, which it
//! gets on the gifter's dial and does not get on the Goblins redeem, the
//! split the driver asserts.

const std = @import("std");
const glowcap = @import("glowcap");
const harness = @import("interop_harness");

const driver = glowcap.driver;
const model = glowcap.ocapn.model;

const host_addr = "127.0.0.1";
const frame_cap: usize = 1 << 16;
pub const greeter_swiss = "glowcapPairGreeterSwiss001";
pub const listening_prefix = "EXPORTER LISTENING ";

const opts: driver.SessionOptions = .{
    .frame_cap = frame_cap,
    .codec = .capnp,
    .captp_version = .next,
    .handshake = .{ .ms = 20_000 },
    .settle = .{ .ms = 20_000 },
};

/// Answers with the name it was called with, so the driver can tell a reply
/// from this actor apart from a reply from anything the gifter stood in with.
const Greeter = struct {
    pub fn handle(_: *Greeter, ht: *driver.HostTurn, verb: []const u8, args: driver.Args) !driver.Value {
        // A plain Goblins `(<- greeter "name")` arrives with an empty verb and
        // the caller's name as the one argument.
        _ = verb;
        if ((try args.len()) != 1) return error.BadInvocation;
        return .{ .string = try std.fmt.allocPrint(
            ht.turn.arena,
            "Hello {s}, I'm the glowcap exporter reached across the profile split!",
            .{try args.string(0)},
        ) };
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var server = try driver.listen(allocator, io, .{ .symbols = &.{.tcp} }, model.transport.tcp, .{ .designator = host_addr ++ ":0" }, .ephemeral, opts);
    defer server.deinit();
    // Host-wide, because a give names a capability the redeeming connection
    // has never seen: the name has to exist before that connection opens.
    try server.publish(greeter_swiss, Greeter, .{});
    var designator_buf: [64]u8 = undefined;
    // Both announce lines go to stderr so the driver reads one stream.
    std.debug.print(listening_prefix ++ "{s}\n", .{try server.localDesignator(&designator_buf)});

    // Serve until the driver kills us; it owns the run's lifetime.
    var sessions: [8]*driver.Session = undefined;
    var count: usize = 0;
    defer for (sessions[0..count]) |session| session.deinit();
    while (true) {
        if (count < sessions.len and try server.waitAcceptable(10)) {
            const session = try server.accept();
            sessions[count] = session;
            count += 1;
            // Report each session's settled profile, so the driver asserts
            // what this process negotiated rather than what it asked for.
            const state = &session.hs.served.port.peer.session_state;
            std.debug.print("EXPORTER SESSION codec={s} captp={s}\n", .{
                @tagName(state.codec),
                @tagName(state.captp_version),
            });
        }
        // best-effort: a step error belongs to that one session, and the loop keeps serving the others.
        for (sessions[0..count]) |session| _ = session.stepReadable(10) catch {};
    }
}
