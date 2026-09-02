//! The relay's RFC 6455 upgrade and frame grammar. These units pin the exact
//! client subset independently of the resident listener and connection
//! lifecycle scenarios in `keyed_relay_test.zig`.

const std = @import("std");
const keyed_relay = @import("glowcap").net.relay;

fn headerOf(bytes: []const u8) keyed_relay.FrameError!keyed_relay.FrameHeader {
    var reader = std.Io.Reader.fixed(bytes);
    return keyed_relay.readFrameHeader(&reader);
}

test "acceptKey reproduces the RFC 6455 worked example" {
    var out: [28]u8 = undefined;
    keyed_relay.acceptKey(&out, "dGhlIHNhbXBsZSBub25jZQ==");
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", out[0..]);
}

test "upgrade response requires the full RFC 6455 handshake" {
    var expected: [28]u8 = undefined;
    keyed_relay.acceptKey(&expected, "dGhlIHNhbXBsZSBub25jZQ==");
    const valid =
        "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: keep-alive, Upgrade\r\n" ++
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=";
    try std.testing.expect(keyed_relay.validUpgradeResponse(valid, &expected));
    try std.testing.expect(!keyed_relay.validUpgradeResponse(
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
        &expected,
    ));
    try std.testing.expect(!keyed_relay.validUpgradeResponse(
        "XXXXXXXXX101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
        &expected,
    ));
    try std.testing.expect(!keyed_relay.validUpgradeResponse(valid ++ "\r\nnot-a-header", &expected));
    try std.testing.expect(!keyed_relay.validUpgradeResponse(
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade : websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
        &expected,
    ));
    try std.testing.expect(!keyed_relay.validUpgradeResponse(
        valid ++ "\r\nSec-WebSocket-Accept: wrong",
        &expected,
    ));
    // The client offered neither field; a server cannot unilaterally install
    // extension bits or subprotocol semantics this endpoint does not speak.
    try std.testing.expect(!keyed_relay.validUpgradeResponse(
        valid ++ "\r\nSec-WebSocket-Extensions: permessage-deflate",
        &expected,
    ));
    try std.testing.expect(!keyed_relay.validUpgradeResponse(
        valid ++ "\r\nSec-WebSocket-Protocol: ocapn",
        &expected,
    ));
}

test "readFrameHeader accepts the plain server shapes" {
    const small = try headerOf(&.{ 0x82, 0x05 });
    try std.testing.expectEqual(keyed_relay.Opcode.binary, small.opcode);
    try std.testing.expectEqual(@as(u64, 5), small.len);
    try std.testing.expect(small.fin);

    const mid = try headerOf(&.{ 0x82, 126, 0x01, 0x2c });
    try std.testing.expectEqual(@as(u64, 300), mid.len);

    const big = try headerOf(&.{ 0x82, 127, 0, 0, 0, 0, 0, 0x01, 0x11, 0x70 });
    try std.testing.expectEqual(@as(u64, 70000), big.len);

    const frag = try headerOf(&.{ 0x02, 0x05 });
    try std.testing.expect(!frag.fin);
    const cont = try headerOf(&.{ 0x80, 0x03 });
    try std.testing.expectEqual(keyed_relay.Opcode.continuation, cont.opcode);
}

test "readFrameHeader fails closed on every hostile shape" {
    try std.testing.expectError(error.ProtocolViolation, headerOf(&.{ 0xc2, 0x05 }));
    try std.testing.expectError(error.ProtocolViolation, headerOf(&.{ 0x82, 0x85, 1, 2, 3, 4 }));
    try std.testing.expectError(error.ProtocolViolation, headerOf(&.{ 0x81, 0x05 }));
    try std.testing.expectError(error.ProtocolViolation, headerOf(&.{ 0x83, 0x05 }));
    try std.testing.expectError(error.ProtocolViolation, headerOf(&.{ 0x89, 126, 0x00, 0x80 }));
    try std.testing.expectError(error.ProtocolViolation, headerOf(&.{ 0x09, 0x05 }));
    try std.testing.expectError(
        error.ProtocolViolation,
        headerOf(&.{ 0x82, 127, 0x80, 0, 0, 0, 0, 0, 0, 1 }),
    );
    try std.testing.expectError(error.ProtocolViolation, headerOf(&.{ 0x82, 126, 0, 125 }));
    try std.testing.expectError(
        error.ProtocolViolation,
        headerOf(&.{ 0x82, 127, 0, 0, 0, 0, 0, 0, 0xff, 0xff }),
    );
    try std.testing.expectError(error.ProtocolViolation, headerOf(&.{ 0x88, 1 }));
    try std.testing.expectError(error.Truncated, headerOf(&.{0x82}));
    try std.testing.expectError(error.Truncated, headerOf(&.{ 0x82, 126, 0x01 }));
}

test "close payload validates status codes and UTF-8 reasons" {
    try keyed_relay.validateClosePayload(&.{});
    try keyed_relay.validateClosePayload(&.{ 0x03, 0xe8 });
    try keyed_relay.validateClosePayload(&.{ 0x0b, 0xb8, 'b', 'y', 'e' });
    try std.testing.expectError(error.ProtocolViolation, keyed_relay.validateClosePayload(&.{0x03}));
    try std.testing.expectError(error.ProtocolViolation, keyed_relay.validateClosePayload(&.{ 0x03, 0xed }));
    try std.testing.expectError(error.ProtocolViolation, keyed_relay.validateClosePayload(&.{ 0x07, 0xd0 }));
    try std.testing.expectError(
        error.ProtocolViolation,
        keyed_relay.validateClosePayload(&.{ 0x03, 0xe8, 0xff }),
    );
}

test "writeFrameHeader emits masked client shapes" {
    const mask = [4]u8{ 0xa1, 0xb2, 0xc3, 0xd4 };
    var buf: [keyed_relay.max_header_len]u8 = undefined;

    const small = try keyed_relay.writeFrameHeader(&buf, .binary, 5, mask);
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 0x85, 0xa1, 0xb2, 0xc3, 0xd4 }, small);

    const mid = try keyed_relay.writeFrameHeader(&buf, .binary, 300, mask);
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 0xfe, 0x01, 0x2c, 0xa1, 0xb2, 0xc3, 0xd4 }, mid);

    const big = try keyed_relay.writeFrameHeader(&buf, .binary, 70000, mask);
    try std.testing.expectEqual(@as(usize, keyed_relay.max_header_len), big.len);
    try std.testing.expectEqual(@as(u8, 0x82), big[0]);
    try std.testing.expectEqual(@as(u8, 0xff), big[1]);

    try std.testing.expectError(
        error.ControlPayloadTooLarge,
        keyed_relay.writeFrameHeader(&buf, .ping, 126, mask),
    );
    _ = try keyed_relay.writeFrameHeader(&buf, .binary, std.math.maxInt(i64), mask);
    try std.testing.expectError(
        error.PayloadTooLarge,
        keyed_relay.writeFrameHeader(&buf, .binary, @as(u64, std.math.maxInt(i64)) + 1, mask),
    );
}
