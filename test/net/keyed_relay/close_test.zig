//! Terminal close ownership for the completion-backed relay carrier.
//!
//! These scenarios pin the distinction between retiring the wrapped
//! descriptor and truthfully settling the synthetic close barrier.

const std = @import("std");
const pancake = @import("pancake");
const admission = @import("../../support/keyed_relay_admission.zig");

const net = pancake.net;
const admissionBackend = admission.admissionBackend;
const deinitAdmissionBackend = admission.deinitAdmissionBackend;
const openAdmissionRelay = admission.openAdmissionRelay;

test "keyed-relay partial application send gives way to one close frame" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);

    try backend.submitSend(9, fd, "payload");
    backend.platform.pending_send.?.result = 1;
    try backend.submitClose(10, fd);

    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 9), completions[0].user_data);
    try std.testing.expectEqual(@as(usize, 2), backend.platform.send_submits);
    try std.testing.expect(backend.platform.pending_send != null);
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expect(backend.platform.pending_close != null);
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 10), completions[0].user_data);
}

test "keyed-relay defers Loop shutdown until its WebSocket close drains" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);

    backend.shutdownFd(fd);
    try std.testing.expectEqual(@as(usize, 0), backend.platform.shutdown_calls);
    try backend.submitClose(11, fd);

    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(usize, 0), backend.platform.shutdown_calls);
    try std.testing.expect(backend.platform.pending_close != null);
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 11), completions[0].user_data);
}

test "keyed-relay reports a wrapped fd close failure after retiring it" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    backend.platform.close_result = -1;

    try backend.submitClose(10, fd);
    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 10), completions[0].user_data);
    try std.testing.expectEqual(@as(i32, -1), completions[0].result);
    try std.testing.expectEqual(error.CloseFailed, completions[0].failure.?);
    try std.testing.expectEqual(@as(usize, 1), backend.platform.close_calls);
    try std.testing.expectEqual(@as(usize, 0), backend.conns.count());
}

test "keyed-relay reports failed close only after receive retires" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;

    try backend.submitRecv(53, fd);
    backend.platform.close_result = -1;
    backend.platform.close_before_recv = true;
    try backend.submitClose(54, fd);

    var completions: [2]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 53), completions[0].user_data);
    try std.testing.expect(conn.pending.recv);
    try std.testing.expectEqual(.in_flight, conn.close.platform);

    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(usize, 0), backend.platform.close_calls);
    try std.testing.expectEqual(.failed, conn.close.platform);

    backend.closeFd(fd);
    try std.testing.expectEqual(@as(usize, 0), backend.platform.close_calls);
    try std.testing.expectEqual(@as(usize, 1), backend.conns.count());

    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(usize, 1), backend.platform.close_calls);
    try std.testing.expectEqual(@as(u64, 54), completions[0].user_data);
    try std.testing.expectEqual(@as(i32, -1), completions[0].result);
    try std.testing.expectEqual(error.CloseFailed, completions[0].failure.?);
}
