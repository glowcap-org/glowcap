//! Targets for the WebSocket client's inbound parsers in
//! `test/net/fuzz_test.zig`: everything a relay the operator does not fully
//! trust can send before and after the upgrade. Three targets, each with its
//! own shaped seeds because a frame header and an HTTP header block share no
//! structure to start from.
//!
//! `frameHeader` feeds arbitrary bytes through `headerLenOf`, `parseHeaderBytes`
//! and `parseFrameBytes` and asserts what a caller sizing a read relies on: a
//! parsed header's length is exactly `headerLenOf`'s answer, a control frame
//! never asks for more than `max_control_payload` buffered bytes, and a frame
//! that was admitted consumed no more than was offered. `closePayload` asserts
//! the close validator refuses or accepts without another error. `upgrade`
//! runs the same bytes through `validUpgradeResponse` and through a line walk
//! of its own, and asserts that both agree and that an accepted response
//! really carries the computed accept key, an upgrade token, and a connection
//! token.
//!
//! Validated by injecting one defect per class: `headerLenOf` answering 4 for
//! a 127 length byte (caught by the layout check, from the seeds),
//! `max_control_payload` raised to 126 in the ping arm (caught by the control
//! bound), and `validUpgradeResponse` skipping the accept comparison (caught
//! by the second-validator agreement, from the wrong-key seed). They do
//! not reach payload streaming or the socket reads around these parsers, and
//! an input past `max_upgrade_response_bytes` is the reader's refusal, not the
//! validator's.

const std = @import("std");
const glowcap = @import("glowcap");

const proto = glowcap.net.websocket.client_protocol;
const seeds = @import("../../support/corpus_seeds.zig");

/// A frame header is at most 14 bytes and a control frame carries at most 125
/// more, so 160 reaches every admitted shape and a little past it.
const max_frame_input = 160;

/// A little more than a realistic upgrade response, well under the reader's
/// `max_upgrade_response_bytes` so inputs stay cheap.
const max_upgrade_input = 512;

/// The key a client would have sent. The expected accept value is computed by
/// `acceptKey`, the same function the client uses, so a seed built from it
/// stays valid if the GUID handling is ever corrected.
const request_key = "dGhlIHNhbXBsZSBub25jZQ==";

fn expectedAccept() [28]u8 {
    var accept: [28]u8 = undefined;
    proto.acceptKey(&accept, request_key);
    return accept;
}

pub fn frameHeader(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [max_frame_input]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];

    // The RFC 6455 section 5.2 layout, stated again here rather than read back
    // from the parser: the 7-bit length selects 0, 2, or 8 extension bytes.
    const need = proto.headerLenOf(input);
    try std.testing.expectEqual(input.len < 2, need == null);
    if (need) |len| try std.testing.expectEqual(
        @as(usize, switch (input[1] & 0x7f) {
            126 => 4,
            127 => 10,
            else => 2,
        }),
        len,
    );

    const maybe = proto.parseHeaderBytes(input) catch |err| switch (err) {
        error.ProtocolViolation => return,
    };
    if (maybe) |parsed| {
        try std.testing.expectEqual(need.?, parsed.header_len);
        try std.testing.expect(parsed.header_len <= input.len);
        const control = proto.controlPayloadLen(parsed.frame);
        try std.testing.expect(control <= proto.max_control_payload);
        switch (parsed.frame.opcode) {
            .close, .ping, .pong => {
                try std.testing.expect(parsed.frame.fin);
                try std.testing.expectEqual(parsed.frame.len, control);
            },
            .binary, .continuation => try std.testing.expectEqual(@as(usize, 0), control),
            else => return error.AdmittedAnUnspeakableOpcode,
        }
    } else {
        // Null is only "more header bytes needed".
        try std.testing.expect(need == null or input.len < need.?);
    }

    for ([_]bool{ false, true }) |start| {
        var fragmented = start;
        const frame = proto.parseFrameBytes(&fragmented, input) catch |err| switch (err) {
            error.ProtocolViolation => {
                // A refusal leaves the fragmentation state as it found it.
                try std.testing.expectEqual(start, fragmented);
                continue;
            },
        };
        const admitted = frame orelse {
            try std.testing.expectEqual(start, fragmented);
            continue;
        };
        try std.testing.expect(admitted.consumed_len <= input.len);
        try std.testing.expectEqual(
            admitted.payload_start + proto.controlPayloadLen(admitted.header),
            admitted.consumed_len,
        );
        try std.testing.expect(admitted.controlPayload(input).len <= proto.max_control_payload);
    }
}

pub fn closePayload(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [max_frame_input]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    proto.validateClosePayload(input) catch |err| switch (err) {
        error.ProtocolViolation => {
            // Refusing an empty payload would make a bare close unanswerable.
            try std.testing.expect(input.len != 0);
            return;
        },
    };
    if (input.len == 1) return error.AcceptedAOneByteClosePayload;
}

/// Walk the block the way a streaming reader does, one line at a time, without
/// sharing `validUpgradeResponse`'s splitter.
fn validByLines(bytes: []const u8, accept: *const [28]u8) bool {
    var rest = bytes;
    const first_end = std.mem.indexOf(u8, rest, "\r\n") orelse rest.len;
    if (!proto.validUpgradeStatus(rest[0..first_end])) return false;
    rest = rest[@min(rest.len, first_end + 2)..];
    var validator: proto.UpgradeResponseValidator = .{};
    // A block that ends right after its status line has no header lines, and a
    // block ending in a separator has one empty final line.
    var more = first_end < bytes.len;
    while (more) {
        const end = std.mem.indexOf(u8, rest, "\r\n");
        validator.observe(rest[0 .. end orelse rest.len], accept);
        if (end) |at| {
            rest = rest[at + 2 ..];
        } else more = false;
    }
    return validator.valid();
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.findIgnoreCase(haystack, needle) != null;
}

pub fn upgrade(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [max_upgrade_input]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    const accept = expectedAccept();

    const valid = proto.validUpgradeResponse(input, &accept);
    try std.testing.expectEqual(valid, validByLines(input, &accept));
    if (!valid) return;

    // Accepted means the evidence is on the wire, not merely that nothing
    // objected.
    try std.testing.expect(std.mem.startsWith(u8, input, "HTTP/1.1 101"));
    try std.testing.expect(std.mem.indexOf(u8, input, &accept) != null);
    try std.testing.expect(containsIgnoreCase(input, "websocket"));
    try std.testing.expect(containsIgnoreCase(input, "upgrade"));
}

pub const frame_seeds = [_][]const u8{
    seeds.seed(&[_]u8{ 0x82, 0x00 }),
    seeds.seed(&[_]u8{ 0x82, 0x05, 'h', 'e', 'l', 'l', 'o' }),
    seeds.seed(&[_]u8{ 0x02, 0x7e, 0x01, 0x00 }),
    seeds.seed(&[_]u8{ 0x82, 0x7f, 0, 0, 0, 0, 0, 1, 0, 0 }),
    seeds.seed(&[_]u8{ 0x89, 0x02, 'h', 'i' }),
    seeds.seed(&[_]u8{ 0x8a, 0x00 }),
    seeds.seed(&[_]u8{ 0x89, 0x7e, 0x00, 0x7e }),
    seeds.seed(&[_]u8{ 0x88, 0x02, 0x03, 0xe8 }),
    seeds.seed(&[_]u8{ 0x88, 0x00 }),
    // Refusals: masked, text, fragmented control, non-minimal length.
    seeds.seed(&[_]u8{ 0x82, 0x80, 1, 2, 3, 4 }),
    seeds.seed(&[_]u8{ 0x81, 0x00 }),
    seeds.seed(&[_]u8{ 0x09, 0x00 }),
    seeds.seed(&[_]u8{ 0x82, 0x7e, 0x00, 0x05 }),
};

pub const close_seeds = [_][]const u8{
    seeds.seed(""),
    seeds.seed(&[_]u8{ 0x03, 0xe8 }),
    seeds.seed(&[_]u8{ 0x03, 0xe8, 'b', 'y', 'e' }),
    seeds.seed(&[_]u8{0x03}),
    seeds.seed(&[_]u8{ 0x03, 0xed }),
    seeds.seed(&[_]u8{ 0x0b, 0xb8, 0xff, 0xfe }),
};

const valid_upgrade = "HTTP/1.1 101 Switching Protocols\r\n" ++
    "Upgrade: websocket\r\n" ++
    "Connection: Upgrade\r\n" ++
    "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=";

pub const upgrade_seeds = [_][]const u8{
    seeds.seed(valid_upgrade),
    seeds.seed(valid_upgrade ++ "\r\n"),
    seeds.seed("HTTP/1.1 101"),
    seeds.seed("HTTP/1.1 101 Switching Protocols\r\nupgrade: WebSocket\r\nconnection: keep-alive, upgrade\r\n" ++
        "sec-websocket-accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="),
    seeds.seed("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: AAAAAAAAAAAAAAAAAAAAAAAAAAA="),
    seeds.seed(valid_upgrade ++ "\r\nSec-WebSocket-Protocol: chat"),
    seeds.seed(valid_upgrade ++ "\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="),
    seeds.seed("HTTP/1.0 200 OK\r\n"),
};
