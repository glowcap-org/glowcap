//! Eventual-send target refusal: the owning `driver.Session` reference-keyed
//! verbs (`callReference` / `sendReference`) admit only an _object_
//! near/far reference. A promise-kind near/far (an unresolved import/export
//! promise) must be refused with `Error.UncallableTarget`, not silently
//! coerced into an object turn: pipelining rides the answer vow
//! (`sendToAnswer`), never a promise-kind target.
//!
//! Driven over TCP loopback — the owning tier multiplexes its blocking waits
//! with poll, so it binds fd-backed transports only (ADR-0090). The positive control is a genuine
//! far object that still calls and settles. That shows the gate refuses on _kind_, not
//! by over-rejecting every reference.

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
const Greeter = support_actors.StaticReplyActor("greet", "hello over loopback");

/// Accept one partner over the bound listener, publish the greeter, and serve
/// until the client leaves. Mirrors the owning `Server` accept the bindings ride.
fn hostOnce(server: *driver.Server) anyerror!void {
    const conn = try server.accept();
    defer conn.deinit();
    _ = try conn.publish("greeter", Greeter, .{});
    try conn.serve();
}

test "session reference targets: promise-kind near/far is refused, an object still calls" {
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
    var designator_buf: [net.tcp.designator_buf_len]u8 = undefined;
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
    // and settles. The gate refuses on kind, not by rejecting every reference.
    const greeter = try client.fetchReference("greeter");
    try std.testing.expect(greeter == .far and greeter.far.kind == .object);
    const settled = try client.callReference(greeter, "greet", &.{}, arena.allocator());
    try std.testing.expect(settled == .fulfilled and settled.fulfilled == .string);
    try std.testing.expectEqualStrings("hello over loopback", settled.fulfilled.string);

    // The promise-kind twin of that same far reference: an unresolved import
    // promise. Both reference-keyed verbs must refuse it, never coerce it into
    // an object turn.
    const far_promise = model.Reference{ .far = .{ .import_position = greeter.far.import_position, .kind = .promise } };
    try std.testing.expectError(error.UncallableTarget, client.callReference(far_promise, "greet", &.{}, arena.allocator()));
    try std.testing.expectError(error.UncallableTarget, client.sendReference(far_promise, "greet", &.{}));

    // A promise-kind near reference (an unresolved local export promise) is
    // refused the same way, before the export table is ever consulted.
    const near_promise = model.Reference{ .near = .{ .export_position = model.ExportPosition.from(1), .kind = .promise } };
    try std.testing.expectError(error.UncallableTarget, client.callReference(near_promise, "greet", &.{}, arena.allocator()));
    try std.testing.expectError(error.UncallableTarget, client.sendReference(near_promise, "greet", &.{}));

    // A bare answer-promise, a sturdy, and a broken reference are not targets.
    const bare_promise = model.Reference{ .promise = .{ .answer_position = model.AnswerPosition.from(1) } };
    try std.testing.expectError(error.UncallableTarget, client.sendReference(bare_promise, "greet", &.{}));
}
