//! Eventual-send target refusal on the owning `driver.Session`: `call` /
//! `send` / `tell` admit only an _object_ capability. A promise-kind
//! capability (an unresolved import promise) must be refused with
//! `Error.UncallableTarget`, not silently coerced into an object turn:
//! pipelining rides the answer vow (`sendToAnswer`), never a promise-kind
//! target. The shapes that are not capabilities at all — a promise-kind local
//! export, a bare answer-promise — cannot even be lifted into the opaque
//! surface: the Host refuses them at the lift, so the facade has nothing to
//! gate.
//!
//! Driven over TCP loopback — the owning tier multiplexes its blocking waits
//! with poll, so it binds fd-backed transports only (ADR-0090). The positive
//! control is a genuine far object that still calls and settles. That shows
//! the gate refuses on _kind_, not by over-rejecting every capability.

const std = @import("std");
const pancake = @import("pancake");
const support_actors = @import("../support/actors.zig");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const actors = pancake.actors;
const driver = pancake.driver;
const net = pancake.net;
const tcp = net.tcp;
const ip = std.Io.net;

const frame_cap = 4096;

/// Session options for a real loopback dial. The budgets are finite on purpose:
/// an unbounded CapTP wait against a partner that goes quiet does not fail the
/// suite, it wedges the test binary, which reads as a hang rather than a bug.
const dial_opts: driver.SessionOptions = .{
    .frame_cap = frame_cap,
    .handshake = .{ .ms = 10_000 },
    .settle = .{ .ms = 10_000 },
};

/// The published actor the positive control calls.
const Greeter = support_actors.StaticReplyValueActor("greet", "hello over loopback");

/// Accept one partner over the bound listener, publish the greeter, and serve
/// until the client leaves. Mirrors the owning `Server` accept the bindings ride.
fn hostOnce(server: *driver.Server) anyerror!void {
    const session = try server.accept();
    defer session.deinit();
    _ = try session.publish("greeter", Greeter, .{});
    try session.serve();
}

test "session capability targets: promise-kind is refused, an object still calls" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tcp_resident = tcp.Resident{ .io = io };
    var server = try driver.listen(
        allocator,
        tcp_resident.netlayer(),
        .{ .designator = "127.0.0.1:0" },
        .ephemeral,
        dial_opts,
    );
    defer server.close() catch {};
    var addr_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&addr_buf));

    var host_future = try io.concurrent(hostOnce, .{&server});

    const client_result = clientAsserts(allocator, io, address);

    const host_result = host_future.await(io);
    try client_result;
    try host_result;
}

fn clientAsserts(allocator: std.mem.Allocator, io: std.Io, address: ip.IpAddress) !void {
    var tcp_resident = tcp.Resident{ .io = io };
    const netlayers = [_]net.netlayer.Netlayer{tcp_resident.netlayer()};
    var designator_buf: [net.tcp.plain.designator_buf_len]u8 = undefined;
    const client = try driver.connect(
        allocator,
        &netlayers,
        tcp.locator(&designator_buf, address),
        .ephemeral,
        dial_opts,
    );
    defer client.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Positive control: a genuine far object fetched from the partner calls
    // and settles. The gate refuses on kind, not by rejecting every capability.
    const greeter = try client.fetch("greeter");
    const settled = try client.call(greeter, "greet", &.{}, arena.allocator());
    try std.testing.expect(settled == .fulfilled and settled.fulfilled == .string);
    try std.testing.expectEqualStrings("hello over loopback", settled.fulfilled.string);

    // The promise-kind twin of the object import cannot even become a
    // capability: the import row's identity already names the object kind,
    // and the lift refuses the mismatch outright.
    const import_position = blk: {
        const wire = try client.runtime.core.lowerCapability(client.hs, greeter);
        break :blk wire.far.import_position;
    };
    try std.testing.expectError(error.EnrolledKindConflict, client.runtime.core.liftCapability(
        client.hs,
        .{ .far = .{ .import_position = import_position, .kind = .promise } },
    ));

    // A genuine promise-kind capability (a fresh promise import, lifted
    // through the core escape — the opaque surface itself never mints one
    // from a send): every eventual-send verb must refuse it, never coerce it
    // into an object turn.
    const fresh_promise_position: u64 = 40;
    try client.peer().importObject(fresh_promise_position);
    const far_promise = try client.runtime.core.liftCapability(
        client.hs,
        .{ .far = .{ .import_position = model.ImportPosition.from(fresh_promise_position), .kind = .promise } },
    );
    try std.testing.expectError(error.UncallableTarget, client.call(far_promise, "greet", &.{}, arena.allocator()));
    try std.testing.expectError(error.UncallableTarget, client.send(far_promise, "greet", &.{}));
    try std.testing.expectError(error.UncallableTarget, client.tell(far_promise, "greet", &.{}));

    // The shapes that are not capabilities cannot even enter the opaque
    // surface: a promise-kind local export and a bare answer-promise are
    // refused at the lift itself.
    const near_promise = model.Reference{ .near = .{ .export_position = model.ExportPosition.from(1), .kind = .promise } };
    try std.testing.expectError(error.UncallableTarget, client.runtime.core.liftCapability(client.hs, near_promise));
    const bare_promise = model.Reference{ .promise = .{ .answer_position = model.AnswerPosition.from(1) } };
    try std.testing.expectError(error.UncallableTarget, client.runtime.core.liftCapability(client.hs, bare_promise));
}
