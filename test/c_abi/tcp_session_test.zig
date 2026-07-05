//! Owning C TCP session proof (ADR-0062) — the `pancake_tcp_session_*` family is
//! the C spelling of the native-Zig `driver.Connection`: it dials, runs the keyed
//! handshake, and offers a blocking `fetch`/`call` over the shared
//! `PancakeReference`/`PancakeArgument` vocabulary, settling into the TCP
//! archive's own `PancakeSettled` outcome. This pairs
//! it against a real `driver.Server` host — the same hosting half the Zig
//! `Connection` tests use — over a 127.0.0.1 socket with the keyed, verified
//! handshake on both ends. The host publishes an `echo` actor; the C session
//! fetches it and calls it, and the reply round-trips as a fulfilled settled
//! value.
//!
//! The host runs on the test's own `std.Io.Threaded` backend via `io.concurrent`;
//! the C session owns its own backend (created by `pancake_tcp_netlayer_new`) and
//! blocks the test thread, so the two pump concurrently over the wire.

const std = @import("std");
const pancake = @import("pancake");

const c = @import("c_abi");
const ct = @import("c_abi_net_transport_tcp");

const model = pancake.ocapn.model;
const actors = pancake.actors;
const driver = pancake.driver;
const tcp = pancake.net.tcp;

const frame_cap = 4096;

/// The published actor: answers `echo(value)` with `value` unchanged.
const Echo = struct {
    pub fn handle(self: *Echo, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "echo")) return error.NoSuchMethod;
        if (msg.args.len < 1) return error.MissingArgument;
        return msg.args[0];
    }
};

/// Accept one partner, publish the echo actor, and serve until the client
/// releases its session (graceful close).
fn serveOnce(server: *driver.Server) anyerror!void {
    var conn = try server.accept();
    defer conn.deinit();
    _ = try conn.publish("echo", Echo, .{});
    try conn.serve();
}

test "c-abi owning session: connect + keyed handshake, fetch, call round-trips against a driver host" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var host_resident = tcp.Resident{ .io = io };
    var server = try driver.listen(
        allocator,
        host_resident.netlayer(),
        .{ .designator = "127.0.0.1:0" },
        .ephemeral,
        .{ .frame_cap = frame_cap },
    );
    defer server.close();

    var addr_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(server.localDesignator(&addr_buf));
    const port = address.getPort();

    var host_future = try io.concurrent(serveOnce, .{&server});

    const client_result = sessionRoundTrip(port);

    const host_result = host_future.await(io);
    try client_result;
    try host_result;
}

/// The C client: a netlayer of its own, an owning session over it, then the
/// blocking fetch/call the surface exists to make read like the Zig
/// `Connection`. Closing the session lets the host observe EOF and finish.
fn sessionRoundTrip(port: u16) !void {
    var netlayer: ?*ct.PancakeTcpNetlayer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, ct.pancake_tcp_netlayer_new(&netlayer));
    const netlayer_ptr = netlayer.?;
    defer ct.pancake_tcp_netlayer_release(netlayer_ptr);

    const host = "127.0.0.1";
    var session: ?*ct.PancakeTcpSession = null;
    try std.testing.expectEqual(c.PANCAKE_OK, ct.pancake_tcp_session_connect(
        netlayer_ptr,
        host.ptr,
        host.len,
        port,
        c.PANCAKE_CODEC_SYRUP,
        frame_cap,
        &session,
    ));
    const session_ptr = session.?;
    defer ct.pancake_tcp_session_release(session_ptr);

    var echo_ref: c.PancakeReference = undefined;
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        ct.pancake_tcp_session_fetch(session_ptr, "echo", 4, &echo_ref),
    );
    // A fetched capability is a far object reference into the partner.
    try std.testing.expectEqual(@as(u32, c.PANCAKE_REF_FAR), echo_ref.kind);

    var value: c.PancakeArgument = std.mem.zeroes(c.PancakeArgument);
    value.kind = c.PANCAKE_ARG_STRING;
    const payload = "world";
    value.bytes = payload.ptr;
    value.bytes_len = payload.len;
    const args = [_]c.PancakeArgument{value};

    // An uncallable target is refused with one consistent code, before any wire
    // traffic: a sturdy reference (would fail in marshalling) and a promise-kind
    // far reference (would otherwise be silently coerced) both return
    // PANCAKE_ERR_INVALID_ARGUMENT, matching the documented contract.
    var rejected: ct.PancakeSettled = undefined;
    const sturdy_ref = c.PancakeReference{ .kind = c.PANCAKE_REF_STURDY, .sub_kind = 0, .id = 0 };
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        ct.pancake_tcp_session_call(session_ptr, &sturdy_ref, "echo", 4, &args, args.len, &rejected),
    );
    var promise_ref = echo_ref;
    promise_ref.sub_kind = c.PANCAKE_REF_SUB_PROMISE;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        ct.pancake_tcp_session_call(session_ptr, &promise_ref, "echo", 4, &args, args.len, &rejected),
    );
    // A near (local-export) object reference names a local object by its wire
    // export position. This session is a client and hosts no exports, so a near
    // target resolves to nothing and fails closed with INVALID_ARGUMENT, it is
    // never coerced into a vat actor id (a different number space), which would
    // silently dispatch to whatever actor happened to carry that id.
    const near_ref = c.PancakeReference{ .kind = c.PANCAKE_REF_NEAR, .sub_kind = c.PANCAKE_REF_SUB_OBJECT, .id = 1 };
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        ct.pancake_tcp_session_call(session_ptr, &near_ref, "echo", 4, &args, args.len, &rejected),
    );

    var settled: ct.PancakeSettled = undefined;
    try std.testing.expectEqual(c.PANCAKE_OK, ct.pancake_tcp_session_call(
        session_ptr,
        &echo_ref,
        "echo",
        4,
        &args,
        args.len,
        &settled,
    ));
    defer ct.pancake_tcp_settled_release(&settled);

    try std.testing.expectEqual(@as(u32, c.PANCAKE_RESOLUTION_FULFILL), settled.resolution_kind);
    try std.testing.expectEqual(@as(u32, c.PANCAKE_ARG_STRING), settled.fulfill.kind);
    const reply = settled.fulfill.bytes.?[0..settled.fulfill.bytes_len];
    try std.testing.expectEqualStrings(payload, reply);
}

/// A board task (the pipelining host's leaf): `assign`/`complete`/`status`,
/// the four-verb taskboard unit the bench drives. `complete` latches `done`.
const Task = struct {
    done: bool = false,
    pub fn handle(self: *Task, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (std.mem.eql(u8, msg.verb, "assign")) return .{ .bytes = "assigned" };
        if (std.mem.eql(u8, msg.verb, "complete")) {
            self.done = true;
            return .{ .bytes = "done" };
        }
        if (std.mem.eql(u8, msg.verb, "status")) return .{ .bytes = if (self.done) "done" else "open" };
        return error.NoSuchMethod;
    }
};

/// The published root: `create` spawns a fresh `Task` and answers with its
/// capability, so a pipelined call against the unresolved `create` answer lands
/// on that task once it resolves.
const Board = struct {
    pub fn handle(self: *Board, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        if (!std.mem.eql(u8, msg.verb, "create")) return error.NoSuchMethod;
        const cap = try driver.spawnAt(turn.vat, Task, .{});
        return cap.arg();
    }
};

fn serveBoardOnce(server: *driver.Server) anyerror!void {
    var conn = try server.accept();
    defer conn.deinit();
    _ = try conn.publish("root", Board, .{});
    try conn.serve();
}

test "c-abi owning session: promise pipelining drives create->assign->complete->status as one batch through the C surface" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var host_resident = tcp.Resident{ .io = io };
    var server = try driver.listen(
        allocator,
        host_resident.netlayer(),
        .{ .designator = "127.0.0.1:0" },
        .ephemeral,
        .{ .frame_cap = frame_cap },
    );
    defer server.close();

    var addr_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(server.localDesignator(&addr_buf));
    const port = address.getPort();

    var host_future = try io.concurrent(serveBoardOnce, .{&server});

    const client_result = pipelineRoundTrip(port);

    const host_result = host_future.await(io);
    try client_result;
    try host_result;
}

/// The C questioner half of ADR-0007: `..._session_send` the `create`, then
/// `..._session_send_pipelined` the three dependent verbs against its *unresolved*
/// answer, and only then `..._session_settle` the final `status`. The four
/// delivers flush together on that settle — a dependent chain crossing the wire
/// as one batch, not four blocking round trips — and `status` of `done` proves
/// the C surface drives it correctly.
fn pipelineRoundTrip(port: u16) !void {
    var netlayer: ?*ct.PancakeTcpNetlayer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, ct.pancake_tcp_netlayer_new(&netlayer));
    const netlayer_ptr = netlayer.?;
    defer ct.pancake_tcp_netlayer_release(netlayer_ptr);

    const host = "127.0.0.1";
    var session: ?*ct.PancakeTcpSession = null;
    try std.testing.expectEqual(c.PANCAKE_OK, ct.pancake_tcp_session_connect(
        netlayer_ptr,
        host.ptr,
        host.len,
        port,
        c.PANCAKE_CODEC_SYRUP,
        frame_cap,
        &session,
    ));
    const session_ptr = session.?;
    defer ct.pancake_tcp_session_release(session_ptr);

    var root_ref: c.PancakeReference = undefined;
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        ct.pancake_tcp_session_fetch(session_ptr, "root", 4, &root_ref),
    );

    // A send refuses an uncallable target with the same code the blocking call
    // does, before any wire traffic.
    var rejected: ?*ct.PancakeTcpPromise = null;
    const sturdy_ref = c.PancakeReference{ .kind = c.PANCAKE_REF_STURDY, .sub_kind = 0, .id = 0 };
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        ct.pancake_tcp_session_send(session_ptr, &sturdy_ref, "create", 6, null, 0, &rejected),
    );
    // The same fail-closed contract as the blocking call: a near reference to an
    // export this client does not host is refused, never dispatched to a vat
    // actor id that happens to match the wire export position.
    const near_ref = c.PancakeReference{ .kind = c.PANCAKE_REF_NEAR, .sub_kind = c.PANCAKE_REF_SUB_OBJECT, .id = 1 };
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        ct.pancake_tcp_session_send(session_ptr, &near_ref, "create", 6, null, 0, &rejected),
    );

    var create_arg: c.PancakeArgument = std.mem.zeroes(c.PancakeArgument);
    create_arg.kind = c.PANCAKE_ARG_STRING;
    const subject = "benchmark";
    create_arg.bytes = subject.ptr;
    create_arg.bytes_len = subject.len;
    const create_args = [_]c.PancakeArgument{create_arg};

    var created: ?*ct.PancakeTcpPromise = null;
    try std.testing.expectEqual(c.PANCAKE_OK, ct.pancake_tcp_session_send(
        session_ptr,
        &root_ref,
        "create",
        6,
        &create_args,
        create_args.len,
        &created,
    ));
    const created_ptr = created.?;
    defer ct.pancake_tcp_promise_release(created_ptr);

    var assign_arg: c.PancakeArgument = std.mem.zeroes(c.PancakeArgument);
    assign_arg.kind = c.PANCAKE_ARG_STRING;
    const who = "alice";
    assign_arg.bytes = who.ptr;
    assign_arg.bytes_len = who.len;
    const assign_args = [_]c.PancakeArgument{assign_arg};

    var assigned: ?*ct.PancakeTcpPromise = null;
    try std.testing.expectEqual(c.PANCAKE_OK, ct.pancake_tcp_session_send_pipelined(
        session_ptr,
        created_ptr,
        "assign",
        6,
        &assign_args,
        assign_args.len,
        &assigned,
    ));
    defer ct.pancake_tcp_promise_release(assigned.?);

    var completed: ?*ct.PancakeTcpPromise = null;
    try std.testing.expectEqual(c.PANCAKE_OK, ct.pancake_tcp_session_send_pipelined(
        session_ptr,
        created_ptr,
        "complete",
        8,
        null,
        0,
        &completed,
    ));
    defer ct.pancake_tcp_promise_release(completed.?);

    var status: ?*ct.PancakeTcpPromise = null;
    try std.testing.expectEqual(c.PANCAKE_OK, ct.pancake_tcp_session_send_pipelined(
        session_ptr,
        created_ptr,
        "status",
        6,
        null,
        0,
        &status,
    ));
    const status_ptr = status.?;
    defer ct.pancake_tcp_promise_release(status_ptr);

    var settled: ct.PancakeSettled = undefined;
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        ct.pancake_tcp_session_settle(session_ptr, status_ptr, &settled),
    );
    defer ct.pancake_tcp_settled_release(&settled);

    try std.testing.expectEqual(@as(u32, c.PANCAKE_RESOLUTION_FULFILL), settled.resolution_kind);
    // `Task.status` answers with a byte-string, so the projection is _BYTES.
    try std.testing.expectEqual(@as(u32, c.PANCAKE_ARG_BYTES), settled.fulfill.kind);
    const reply = settled.fulfill.bytes.?[0..settled.fulfill.bytes_len];
    try std.testing.expectEqualStrings("done", reply);
}

test "c-abi owning session: connect reports invalid arguments distinctly" {
    var netlayer: ?*ct.PancakeTcpNetlayer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, ct.pancake_tcp_netlayer_new(&netlayer));
    const netlayer_ptr = netlayer.?;
    defer ct.pancake_tcp_netlayer_release(netlayer_ptr);

    const host = "127.0.0.1";
    var session: ?*ct.PancakeTcpSession = null;

    // A zero frame cap is an invalid argument, not a codec problem.
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        ct.pancake_tcp_session_connect(netlayer_ptr, host.ptr, host.len, 9, c.PANCAKE_CODEC_SYRUP, 0, &session),
    );
    // An unknown codec selector is an invalid argument.
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        ct.pancake_tcp_session_connect(netlayer_ptr, host.ptr, host.len, 9, 999, frame_cap, &session),
    );
    // A null required pointer is a null-pointer error.
    try std.testing.expectEqual(
        c.PANCAKE_ERR_NULL_POINTER,
        ct.pancake_tcp_session_connect(null, host.ptr, host.len, 9, c.PANCAKE_CODEC_SYRUP, frame_cap, &session),
    );
}
