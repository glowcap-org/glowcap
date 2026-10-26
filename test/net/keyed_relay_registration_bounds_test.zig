//! The completion relay listener holds at most `max_unaccepted_registrations`
//! promoted legs for the Loop. At that count it starts no replacement leg,
//! however many turns pass, and the first accept frees a seat and starts one.
//! The fake platform connects every leg at once, so the proof is the backlog
//! arithmetic alone.

const std = @import("std");
const glowcap = @import("glowcap");

const crypto = glowcap.foundation.crypto;
const net = glowcap.net;
const admission = @import("../support/keyed_relay_admission.zig");
const AdmissionBackend = admission.AdmissionBackend;
const deinitAdmissionBackend = admission.deinitAdmissionBackend;

const max_unaccepted = net.relay.white_box.max_unaccepted_registrations;

fn poll(backend: *AdmissionBackend) !usize {
    var completions: [1]net.completion.Completion = undefined;
    return backend.poll(&completions, 0);
}

/// Poll until the Loop-facing completion `user_data` arrives.
fn awaitCompletion(backend: *AdmissionBackend, user_data: u64) !net.completion.Completion {
    var completions: [1]net.completion.Completion = undefined;
    var turns: usize = 0;
    while (true) : (turns += 1) {
        try std.testing.expect(turns < 16);
        if (try backend.poll(&completions, 0) == 0) continue;
        try std.testing.expectEqual(user_data, completions[0].user_data);
        return completions[0];
    }
}

/// Drive the current registration leg from its start to its promotion: the
/// platform connects it, the relay's upgrade response parks it, and one
/// application frame promotes it. The turn that promotes a leg starts the
/// replacement when a seat is free, so the next call finds it under way.
fn promoteLeg(backend: *AdmissionBackend) !void {
    var turns: usize = 0;
    const conn = while (true) : (turns += 1) {
        try std.testing.expect(turns < 8);
        // A leg is a pending dial before it has a connection row.
        if (backend.registration.leg) |leg| if (backend.conns.get(leg.id)) |c| if (c.state == .reading_upgrade) break c;
        try std.testing.expectEqual(@as(usize, 0), try poll(backend));
    };
    var response_buf: [256]u8 = undefined;
    const response = try std.fmt.bufPrint(
        &response_buf,
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: {s}\r\n\r\n",
        .{conn.expected_accept[0..]},
    );
    try backend.platform.completeRecv(response);
    try std.testing.expectEqual(@as(usize, 0), try poll(backend));
    try std.testing.expectEqual(.parked, conn.state);

    var frame = [_]u8{ 0x82, 0x02, 'h', 'i' };
    try backend.platform.completeRecv(&frame);
    const before = backend.registration.unaccepted_len;
    try std.testing.expectEqual(@as(usize, 0), try poll(backend));
    try std.testing.expectEqual(before + 1, backend.registration.unaccepted_len);
}

test "keyed-relay listener pauses registration at the unaccepted bound and resumes on an accept" {
    var backend = try AdmissionBackend.initWithRelay(std.testing.allocator, 8, 1, 64, .{
        .url = "ws://127.0.0.1:1/relay",
        .entropy_seed = @splat(0x92),
        .send_staging_bytes = admission.frame_cap,
        .registration = .{ .url = "ws://127.0.0.1:1/register" },
    });
    defer deinitAdmissionBackend(&backend);
    const identity = crypto.SecretKey.fromSeed(@splat(0x74)).publicKey();
    const listen_fd = try backend.openListener(.{ .relay = identity });

    for (0..max_unaccepted) |_| try promoteLeg(&backend);
    try std.testing.expectEqual(max_unaccepted, backend.registration.unaccepted_len);

    // At the bound no replacement leg starts, however many turns pass.
    const dials = backend.platform.dial_submits;
    for (0..4) |_| try std.testing.expectEqual(@as(usize, 0), try poll(&backend));
    try std.testing.expect(backend.registration.leg == null);
    try std.testing.expectEqual(dials, backend.platform.dial_submits);

    // One accept takes the oldest promoted leg, and the freed seat starts
    // the next leg.
    try backend.submitAccept(1, listen_fd);
    try std.testing.expect((try awaitCompletion(&backend, 1)).accepted_fd != null);
    try std.testing.expectEqual(max_unaccepted - 1, backend.registration.unaccepted_len);
    var turns: usize = 0;
    while (backend.registration.leg == null) : (turns += 1) {
        try std.testing.expect(turns < 4);
        try std.testing.expectEqual(@as(usize, 0), try poll(&backend));
    }
    try std.testing.expectEqual(dials + 1, backend.platform.dial_submits);

    // Teardown through the product contract: the Loop accepts every promoted
    // leg, then the listener close retires the one leg still at the relay.
    for (1..max_unaccepted) |index| {
        const user_data: u64 = 100 + index;
        try backend.submitAccept(user_data, listen_fd);
        try std.testing.expect((try awaitCompletion(&backend, user_data)).accepted_fd != null);
    }
    try std.testing.expectEqual(@as(usize, 0), backend.registration.unaccepted_len);
    try backend.submitClose(2, listen_fd);
    try std.testing.expectEqual(@as(i32, 0), (try awaitCompletion(&backend, 2)).result);
    try std.testing.expect(backend.registration.leg == null);
}
