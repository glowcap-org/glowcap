//! Evidence item 1 of ADR-0108: the SOCKS5 bytes pancake writes to reach an
//! onion service are the bytes the two peers it must meet write.
//!
//! The expectations below are read off two sources, not off pancake's own code.
//! One is the pinned Spritely Goblins netlayer helper
//! `conformance/spritely-goblins/upstream/goblins/ocapn/netlayer/onion-socks.rkt`,
//! whose `onion-socks5-setup!` writes the greeting, then a length byte of 62,
//! then the address text, then `#"#U"` for the port. The other is the upstream
//! OCapN suite's client in
//! `conformance/ocapn-conformance/upstream/netlayers/onion.py`. A test that
//! compared these buffers against constants in the module under test would
//! prove only that the module agrees with itself.

const std = @import("std");
const pancake = @import("pancake");

const socks5 = pancake.net.onion.socks5;

/// A real version 3 service id, taken from the pinned Goblins source, where it
/// is the example in `structs-urls.rkt`. It decodes to 35 bytes whose version
/// byte is 3 and whose checksum matches, so it exercises the whole of
/// `checkServiceId` rather than only its length arm.
const goblins_example_id = "wy46gxdweyqn5m7ntzwlxinhdia2jjanlsh37gxklwhfec7yxqr4k3qd";

test "the greeting offers version 5, one method, and no authentication" {
    // onion-socks.rkt: (write-bytes #"\5\1\0" op)
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x05, 0x01, 0x00 }, &socks5.greeting);
}

test "the connect request is the bytes both reference clients write" {
    var buf: [socks5.connect_request_len]u8 = undefined;
    const request = try socks5.writeConnectRequest(&buf, goblins_example_id);

    // Assembled the way onion-socks.rkt writes it, field by field, so a change
    // to any one of them is named rather than showing up as a length mismatch.
    const expected =
        [_]u8{ 0x05, 0x01, 0x00, 0x03 } ++ // version, CONNECT, reserved, domain name
        [_]u8{62} ++ // "all v3 onions are 62 chars long"
        goblins_example_id.* ++ ".onion".* ++
        [_]u8{ 0x23, 0x55 }; // 9045 big-endian, which Racket spells #"#U"

    try std.testing.expectEqualSlices(u8, &expected, request);
    // Four header bytes, the length byte, the 62-character address, and the
    // two-byte port.
    try std.testing.expectEqual(@as(usize, 69), request.len);
}

test "the port bytes are 9045 and the address length is 62" {
    // Both are literals in the reference clients, so they are asserted against
    // literals here rather than recomputed from the same constants the module
    // used to write them.
    try std.testing.expectEqual(@as(u16, 9045), socks5.virtual_port);
    try std.testing.expectEqual(@as(usize, 62), socks5.address_len);
    try std.testing.expectEqual(@as(u8, 0x23), @as(u8, 9045 >> 8));
    try std.testing.expectEqual(@as(u8, 0x55), @as(u8, 9045 & 0xff));
}

test "a well-formed version 3 service id is accepted" {
    try socks5.checkServiceId(goblins_example_id);
}

test "a service id of the wrong length is refused" {
    try std.testing.expectError(error.InvalidServiceId, socks5.checkServiceId(""));
    try std.testing.expectError(error.InvalidServiceId, socks5.checkServiceId(goblins_example_id[0..55]));
    try std.testing.expectError(
        error.InvalidServiceId,
        socks5.checkServiceId(goblins_example_id ++ "d"),
    );
}

test "a character outside the base32 alphabet is refused" {
    // The pinned Goblins regular expression is `[a-z0-9]{55}d`, which admits
    // these four. None can appear in a real address, so refusing them here
    // costs no interoperation and saves a round trip to Tor.
    for ([_]u8{ '0', '1', '8', '9' }) |c| {
        var id: [socks5.service_id_len]u8 = goblins_example_id.*;
        id[0] = c;
        try std.testing.expectError(error.InvalidServiceId, socks5.checkServiceId(&id));
    }
}

test "a service id whose checksum does not match is refused" {
    var id: [socks5.service_id_len]u8 = goblins_example_id.*;
    // Character 52 sits inside the two checksum bytes. Moving it leaves a
    // string that is the right length and entirely base32, so only the
    // checksum can catch it.
    id[52] = if (id[52] == 'a') 'b' else 'a';
    try std.testing.expectError(error.InvalidServiceId, socks5.checkServiceId(&id));
}

test "a malformed service id is refused before a request is built" {
    var buf: [socks5.connect_request_len]u8 = undefined;
    try std.testing.expectError(
        error.InvalidServiceId,
        socks5.writeConnectRequest(&buf, "not-an-onion-address"),
    );
}

test "the greeting reply must select no authentication" {
    try socks5.checkGreetingReply(&[_]u8{ 0x05, 0x00 });
    // A proxy asking for username/password authentication.
    try std.testing.expectError(
        error.ProtocolViolation,
        socks5.checkGreetingReply(&[_]u8{ 0x05, 0x02 }),
    );
    // "No acceptable methods."
    try std.testing.expectError(
        error.ProtocolViolation,
        socks5.checkGreetingReply(&[_]u8{ 0x05, 0xff }),
    );
    try std.testing.expectError(
        error.ProtocolViolation,
        socks5.checkGreetingReply(&[_]u8{ 0x04, 0x00 }),
    );
    try std.testing.expectError(error.ProtocolViolation, socks5.checkGreetingReply(&[_]u8{0x05}));
}

test "a successful connect reply is reply code zero" {
    try socks5.checkConnectReply(&[_]u8{ 0x05, 0x00, 0x00, 0x01 });
}

test "a refused connect reports the proxy's own code" {
    // 0x04 is host unreachable, Tor's answer when it cannot fetch the
    // service's descriptor.
    try std.testing.expectError(
        error.ConnectRefused,
        socks5.checkConnectReply(&[_]u8{ 0x05, 0x04, 0x00, 0x01 }),
    );
    try std.testing.expectError(
        error.ProtocolViolation,
        socks5.checkConnectReply(&[_]u8{ 0x04, 0x00, 0x00, 0x01 }),
    );
}

test "the bound address after a reply head is measured, not assumed" {
    // Tor answers an onion connect with a null IPv4 address, so this is the
    // arm that runs, and its six bytes have to be consumed before the session's
    // first frame or the frame parser starts mid-reply.
    try std.testing.expectEqualDeep(
        socks5.BoundAddress{ .fixed = 6 },
        try socks5.boundAddress(&[_]u8{ 0x05, 0x00, 0x00, 0x01 }),
    );
    try std.testing.expectEqualDeep(
        socks5.BoundAddress{ .fixed = 18 },
        try socks5.boundAddress(&[_]u8{ 0x05, 0x00, 0x00, 0x04 }),
    );
    try std.testing.expectEqualDeep(
        socks5.BoundAddress.domain,
        try socks5.boundAddress(&[_]u8{ 0x05, 0x00, 0x00, 0x03 }),
    );
    try std.testing.expectError(
        error.ProtocolViolation,
        socks5.boundAddress(&[_]u8{ 0x05, 0x00, 0x00, 0x07 }),
    );
}

test "a connect reply validates its reserved byte and address type" {
    try std.testing.expectError(
        error.ProtocolViolation,
        socks5.checkConnectReply(&[_]u8{ 0x05, 0x00, 0x01, 0x01 }),
    );
    try std.testing.expectError(
        error.ProtocolViolation,
        socks5.checkConnectReply(&[_]u8{ 0x05, 0x00, 0x00, 0x07 }),
    );
}
