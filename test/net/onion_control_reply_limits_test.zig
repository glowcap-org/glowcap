//! Onion listener setup against control replies at and past the reply limits.

const std = @import("std");
const glowcap = @import("glowcap");
const sb = @import("../support/onion_script_backend.zig");

const onion = glowcap.net.onion;

const service_id = sb.service_id;
const initBackend = sb.initBackend;
const pollOne = sb.pollOne;
const waitFor = sb.waitFor;
const publishListener = sb.publishListener;

const max_reply_lines = onion.session.max_reply_lines;
const max_line_bytes = onion.control.max_line_bytes;

/// `line` written `count` times, built at comptime so it concatenates.
fn repeated(comptime line: []const u8, comptime count: usize) *const [line.len * count]u8 {
    comptime {
        @setEvalBranchQuota(line.len * count * 8 + 1_000);
        var out: [line.len * count]u8 = undefined;
        for (0..count) |i| @memcpy(out[i * line.len ..][0..line.len], line);
        const frozen = out;
        return &frozen;
    }
}

/// Drive a listener setup over `chunks` to its failed ready seat. `publish_sent`
/// says whether the conversation got far enough to send ADD_ONION.
fn expectSetupFails(chunks: []const []const u8, ready_ud: u64, publish_sent: bool) !void {
    var backend = initBackend(std.testing.allocator, chunks);
    defer backend.deinit();
    const fd = try backend.openListener(.{ .onion = 0 });
    try backend.submitListenReady(ready_ud, fd);
    const ready = try waitFor(&backend, ready_ud);
    try std.testing.expect(ready.result < 0);
    try std.testing.expectEqual(error.ControlReplyTooLong, ready.failure.?);
    try std.testing.expect(!backend.listenerPending(fd));
    try std.testing.expect(backend.control_fd == null);
    const sent = std.mem.find(u8, backend.inner.sent_bytes.items, "ADD_ONION") != null;
    try std.testing.expectEqual(publish_sent, sent);
    try std.testing.expect((try pollOne(&backend)) == null);
}

/// Drive a listener setup over `chunks` to a published service and close it.
fn expectSetupPublishes(chunks: []const []const u8, ready_ud: u64) !void {
    var backend = initBackend(std.testing.allocator, chunks);
    defer backend.deinit();
    const fd = try publishListener(&backend, ready_ud);
    const address = try backend.listenerAddress(fd);
    try std.testing.expectEqualSlices(u8, service_id, &address.onion);
    try backend.submitClose(ready_ud + 1, fd);
    _ = try waitFor(&backend, ready_ud + 1);
}

test "onion completion admits an authentication reply of max_reply_lines lines and refuses one more" {
    const publish_reply = "250-ServiceID=" ++ service_id ++ "\r\n250 OK\r\n";
    const fillers = max_reply_lines - 1;
    const at_bound = comptime repeated("250-Info=x\r\n", fillers) ++ "250 OK\r\n";
    const past_bound = comptime repeated("250-Info=x\r\n", max_reply_lines) ++ "250 OK\r\n";

    const admitted = [_][]const u8{ at_bound, publish_reply };
    try expectSetupPublishes(&admitted, 700);
    // The line past the bound is the terminator, so ADD_ONION is never sent.
    const refused = [_][]const u8{past_bound};
    try expectSetupFails(&refused, 710, false);
}

test "onion completion admits a publish reply of max_reply_lines lines and refuses one more" {
    const id_line = "250-ServiceID=" ++ service_id ++ "\r\n";
    const fillers = max_reply_lines - 2;
    const at_bound = id_line ++ comptime repeated("250-Flags=x\r\n", fillers) ++ "250 OK\r\n";
    const past_bound = id_line ++ comptime repeated("250-Flags=x\r\n", fillers + 1) ++ "250 OK\r\n";

    const admitted = [_][]const u8{ "250 OK\r\n", at_bound };
    try expectSetupPublishes(&admitted, 720);
    const refused = [_][]const u8{ "250 OK\r\n", past_bound };
    try expectSetupFails(&refused, 730, true);
}

test "onion completion admits a reply line of max_line_bytes before its line feed and refuses one more" {
    // The carriage return counts toward the line, so a line of 1023 characters
    // plus `\r` fills the buffer exactly. Its tail arrives in a later chunk.
    const fits_len = max_line_bytes - 5;
    const fits = "250-" ++ comptime repeated("x", fits_len);
    const admitted = [_][]const u8{ fits, "\r\n", "250 OK\r\n", "250-ServiceID=" ++ service_id ++ "\r\n250 OK\r\n" };
    try expectSetupPublishes(&admitted, 740);

    // One more byte: the buffer is full before the carriage return arrives.
    const full = "250-" ++ comptime repeated("x", fits_len + 1);
    const tail_overflows = [_][]const u8{ full, "\r\n" };
    try expectSetupFails(&tail_overflows, 750, false);

    // One more byte inside a single chunk that never carries a line feed.
    const over = "250-" ++ comptime repeated("x", fits_len + 2);
    const chunk_overflows = [_][]const u8{over};
    try expectSetupFails(&chunk_overflows, 760, false);
}
