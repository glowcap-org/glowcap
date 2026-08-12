//! Evidence item 2 of ADR-0108: the Tor control protocol exchange pancake writes
//! is the exchange the pinned Spritely Goblins writes, and the replies it reads
//! are the replies Goblins reads.
//!
//! The expected request text is read off
//! `conformance/spritely-goblins/upstream/goblins/ocapn/netlayer/onion.rkt`. It
//! sends `"AUTHENTICATE"`, then
//! `(format "ADD_ONION NEW:ED25519-V3 PORT=9045,unix:~a" path)` for a fresh
//! service and `(format "ADD_ONION ~a PORT=9045,unix:~a" key path)` to restore
//! one, and its writer thread appends `"\r\n"` to every line. It reads the service
//! id and key with `^250-ServiceID=(.+)$` and `^250-PrivateKey=(.+)$` before a
//! closing `250 OK`.
//!
//! Cookie and password authentication and `SETEVENTS HS_DESC` have no counterpart
//! in that source. Their expectations come from the control protocol itself, and
//! each is asserted as text rather than by round-tripping pancake's own formatter.

const std = @import("std");
const pancake = @import("pancake");

const control = pancake.net.onion.control;

/// The same real version 3 id the SOCKS evidence uses, from the pinned Goblins
/// `structs-urls.rkt`.
const goblins_example_id = "wy46gxdweyqn5m7ntzwlxinhdia2jjanlsh37gxklwhfec7yxqr4k3qd";

/// A forward target shaped like the one Goblins builds: a socket inside a
/// temporary directory it made for this process.
const goblins_shaped_path = "/home/vscode/.cache/goblins/tor/ocapn-tor-1/ocapn.sock";

test "the credential-free authenticate is the line Goblins sends" {
    var buf: [control.max_line_bytes]u8 = undefined;
    // onion.rkt: (async-channel-put tor-out-ch "AUTHENTICATE"), and the writer
    // thread appends "\r\n".
    try std.testing.expectEqualStrings(
        "AUTHENTICATE\r\n",
        try control.writeAuthenticate(&buf, .none),
    );
}

test "a cookie authenticates as hexadecimal" {
    var buf: [control.max_line_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "AUTHENTICATE 00010f7fff\r\n",
        try control.writeAuthenticate(&buf, .{ .cookie = &[_]u8{ 0x00, 0x01, 0x0f, 0x7f, 0xff } }),
    );
    // An empty cookie file is a misconfiguration rather than a credential.
    try std.testing.expectError(
        error.InvalidCredential,
        control.writeAuthenticate(&buf, .{ .cookie = "" }),
    );
}

test "a password authenticates as a quoted string with quotes escaped" {
    var buf: [control.max_line_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "AUTHENTICATE \"hunter2\"\r\n",
        try control.writeAuthenticate(&buf, .{ .password = "hunter2" }),
    );
    try std.testing.expectEqualStrings(
        "AUTHENTICATE \"a\\\"b\\\\c\"\r\n",
        try control.writeAuthenticate(&buf, .{ .password = "a\"b\\c" }),
    );
}

test "a password carrying a line ending is refused, not escaped" {
    // A newline would end the request early and turn whatever follows into a
    // second command the daemon would run.
    var buf: [control.max_line_bytes]u8 = undefined;
    try std.testing.expectError(
        error.InvalidCredential,
        control.writeAuthenticate(&buf, .{ .password = "pass\r\nSETCONF Foo=1" }),
    );
    try std.testing.expectError(
        error.InvalidCredential,
        control.writeAuthenticate(&buf, .{ .password = "pass\nGETINFO version" }),
    );
    try std.testing.expectError(
        error.InvalidCredential,
        control.writeAuthenticate(&buf, .{ .password = "pass\x00" }),
    );
}

test "creating a service is the ADD_ONION line Goblins sends" {
    var buf: [control.max_line_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "ADD_ONION NEW:ED25519-V3 PORT=9045,unix:" ++ goblins_shaped_path ++ "\r\n",
        try control.writeAddOnionNew(&buf, .{ .unix = goblins_shaped_path }),
    );
}

test "restoring a service passes the stored key through verbatim" {
    var buf: [control.max_line_bytes]u8 = undefined;
    // The value Tor returned in `250-PrivateKey=`, including its type prefix.
    // pancake never parses it, so the request must carry exactly these bytes.
    const key = "ED25519-V3:0PDwaQEnbFVXRZrq7uqvY0XmvJXhbXCXsiuXqYbAY1nOZ1Bnj2Rw1qJpZbDLb0hnbC6q6IjhVaKrhVv6bBGx6A==";
    try std.testing.expectEqualStrings(
        "ADD_ONION " ++ key ++ " PORT=9045,unix:" ++ goblins_shaped_path ++ "\r\n",
        try control.writeAddOnionRestore(&buf, key, .{ .unix = goblins_shaped_path }),
    );
}

test "unquoted control atoms cannot inject another command" {
    var buf: [control.max_line_bytes]u8 = undefined;
    try std.testing.expectError(
        error.InvalidCredential,
        control.writeAddOnionNew(&buf, .{ .unix = "/tmp/ocapn.sock\r\nSIGNAL HALT" }),
    );
    try std.testing.expectError(
        error.InvalidCredential,
        control.writeAddOnionNew(&buf, .{ .address = "127.0.0.1:1\nGETINFO version" }),
    );
    try std.testing.expectError(
        error.InvalidCredential,
        control.writeAddOnionRestore(&buf, "ED25519-V3:abc\r\nDEL_ONION " ++ goblins_example_id, .{ .unix = goblins_shaped_path }),
    );
    try std.testing.expectError(
        error.InvalidCredential,
        control.writeAddOnionNew(&buf, .{ .unix = "" }),
    );
}

test "a forward target may be an address instead of a socket path" {
    // Tor accepts either, and the choice is local to the host: the far peer
    // never sees the forward target. Goblins always uses a Unix socket.
    var buf: [control.max_line_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "ADD_ONION NEW:ED25519-V3 PORT=9045,127.0.0.1:37411\r\n",
        try control.writeAddOnionNew(&buf, .{ .address = "127.0.0.1:37411" }),
    );
}

test "the forwarded port is 9045 in the request Tor receives" {
    // The same constant the SOCKS request dials. A mismatch would create a
    // service that nothing could reach, and neither side would report why.
    var buf: [control.max_line_bytes]u8 = undefined;
    const line = try control.writeAddOnionNew(&buf, .{ .address = "127.0.0.1:1" });
    try std.testing.expect(std.mem.indexOf(u8, line, "PORT=9045,") != null);
    try std.testing.expectEqual(@as(u16, 9045), control.virtual_port);
    try std.testing.expectEqual(pancake.net.onion.socks5.virtual_port, control.virtual_port);
}

test "waiting for publication subscribes to descriptor events" {
    var buf: [control.max_line_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "SETEVENTS HS_DESC\r\n",
        try control.writeSetEventsHsDesc(&buf),
    );
}

test "a request too long for its buffer is refused rather than truncated" {
    var small: [8]u8 = undefined;
    try std.testing.expectError(
        error.LineTooLong,
        control.writeAuthenticate(&small, .none),
    );
    try std.testing.expectError(
        error.LineTooLong,
        control.writeAuthenticate(&small, .{ .cookie = "0123456789" }),
    );
    try std.testing.expectError(
        error.LineTooLong,
        control.writeAuthenticate(&small, .{ .password = "0123456789" }),
    );
    try std.testing.expectError(
        error.LineTooLong,
        control.writeAddOnionNew(&small, .{ .unix = goblins_shaped_path }),
    );
}

test "the service id and key are read out of the reply Goblins reads" {
    // The three lines an ADD_ONION answers with, in order.
    const service = try control.parseLine("250-ServiceID=" ++ goblins_example_id);
    try std.testing.expect(service.isOk());
    try std.testing.expectEqual(control.Continuation.mid, service.continuation);
    try std.testing.expectEqualStrings("ServiceID", service.field().?.key);
    try std.testing.expectEqualStrings(goblins_example_id, service.field().?.value);

    const key = try control.parseLine("250-PrivateKey=ED25519-V3:abc+/=");
    try std.testing.expectEqualStrings("PrivateKey", key.field().?.key);
    // The value keeps every byte after the first `=`, including the base64
    // padding, because ADD_ONION has to receive it back unchanged.
    try std.testing.expectEqualStrings("ED25519-V3:abc+/=", key.field().?.value);

    const ok = try control.parseLine("250 OK");
    try std.testing.expect(ok.isOk());
    try std.testing.expectEqual(control.Continuation.end, ok.continuation);
    try std.testing.expectEqualStrings("OK", ok.text);
    try std.testing.expectEqual(@as(?@TypeOf(ok.field().?), null), ok.field());
}

test "a failure reply reports the daemon's own code" {
    // What Tor answers when authentication is required and was not supplied.
    const denied = try control.parseLine("515 Authentication failed: Password did not match");
    try std.testing.expect(!denied.isOk());
    try std.testing.expectEqual(@as(u16, 515), denied.code);

    const bad_key = try control.parseLine("512 Invalid key type");
    try std.testing.expectEqual(@as(u16, 512), bad_key.code);
}

test "a data-block reply line is recognized as introducing one" {
    const line = try control.parseLine("250+onions/current=");
    try std.testing.expectEqual(control.Continuation.data, line.continuation);
}

test "a malformed reply line is refused rather than guessed at" {
    try std.testing.expectError(error.MalformedReply, control.parseLine(""));
    try std.testing.expectError(error.MalformedReply, control.parseLine("250"));
    // No separator.
    try std.testing.expectError(error.MalformedReply, control.parseLine("2500K"));
    // A non-numeric code.
    try std.testing.expectError(error.MalformedReply, control.parseLine("2x0 OK"));
    try std.testing.expectError(error.MalformedReply, control.parseLine("OK 250"));
}

test "an unbounded reply line is refused" {
    // Nothing in the control protocol limits a line, so pancake does. A daemon
    // that streamed without a terminator would otherwise grow a reader's buffer
    // for as long as it kept writing.
    var long: [control.max_line_bytes + 1]u8 = undefined;
    @memset(&long, 'x');
    @memcpy(long[0..4], "250 ");
    try std.testing.expectError(error.MalformedReply, control.parseLine(&long));
}

test "either line terminator is trimmed, as the Goblins reader trims" {
    // onion.rkt reads to a newline and then trims a trailing carriage return,
    // so a daemon sending a bare newline is tolerated there and here.
    try std.testing.expectEqualStrings("250 OK", control.trimLineEnding("250 OK\r\n"));
    try std.testing.expectEqualStrings("250 OK", control.trimLineEnding("250 OK\n"));
    try std.testing.expectEqualStrings("250 OK", control.trimLineEnding("250 OK"));
    try std.testing.expectEqualStrings("", control.trimLineEnding("\r\n"));
}
