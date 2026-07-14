//! Eventual-send target refusal — the owning `driver.Session` reference-keyed
//! verbs (`callReference` / `sendReference`, the C surface's
//! `pancake_tcp_session_call` / `_send`, ADR-0062) admit only an _object_
//! near/far reference. A promise-kind near/far (an unresolved import/export
//! promise) must be refused with `Error.UncallableTarget`, not silently
//! coerced into an object turn: pipelining rides the answer vow
//! (`sendToAnswer`), never a promise-kind target.
//!
//! Driven over the in-process netlayer, so the refusal is proven on a real,
//! keyed, handshaken session with no socket. The positive control — a genuine
//! far object still calls and settles — shows the gate refuses on _kind_, not
//! by over-rejecting every reference.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const actors = pancake.actors;
const driver = pancake.driver;
const net = pancake.net;
const inproc = net.inproc;

const node_designator = "target-node";
const frame_cap = 4096;

/// The published actor the positive control calls.
const Greeter = struct {
    pub fn handle(self: *Greeter, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "greet")) return error.NoSuchMethod;
        return .{ .string = "hello over inproc" };
    }
};

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

    var network = inproc.Network.init(allocator, io);
    defer network.deinit();

    var server = try driver.listen(
        allocator,
        network.netlayer(),
        .{ .designator = node_designator },
        .ephemeral,
        .{ .frame_cap = frame_cap },
    );
    defer server.close();

    var host_future = try io.concurrent(hostOnce, .{&server});

    const client_result = clientAsserts(allocator, &network);

    const host_result = host_future.await(io);
    try client_result;
    try host_result;
}

fn clientAsserts(allocator: std.mem.Allocator, network: *inproc.Network) !void {
    const netlayers = [_]net.netlayer.Netlayer{network.netlayer()};
    const client = try driver.connect(
        allocator,
        &netlayers,
        .{ .transport = inproc.transport_name, .designator = node_designator, .hints = model.Hints.emptyFalse() },
        .ephemeral,
        .{ .frame_cap = frame_cap },
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
    try std.testing.expectEqualStrings("hello over inproc", settled.fulfilled.string);

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
