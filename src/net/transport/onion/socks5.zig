//! The SOCKS5 client that reaches an onion service through a local Tor.
//!
//! Every byte here is dictated by the peers glowcap must meet, so the module
//! builds and parses bytes and performs no I/O. The two implementations it has
//! to agree with are the pinned Goblins
//! (`conformance/spritely-goblins/upstream/goblins/ocapn/netlayer/onion-socks.rkt`)
//! and the upstream OCapN suite (`conformance/ocapn-conformance/upstream/netlayers/onion.py`).
//! Both write a version 5 greeting offering one method and no authentication,
//! then a connect request whose address is the literal text
//! `<serviceid>.onion` under address type 3, to port 9045.
//!
//! Keeping the encoding separate from the socket is what lets the conformance
//! evidence run with no Tor and no network: the tests compare these buffers to
//! the bytes read off those two sources, and the driver above only moves them.

const std = @import("std");

/// The virtual port every OCapN onion service listens on. Fixed by the OCapN
/// draft's `Netlayers.md`, so it is a constant rather than a setting: a peer that
/// changed it could reach no other implementation.
pub const virtual_port: u16 = 9045;

/// A version 3 onion service id is 56 base32 characters. It encodes a 32-byte
/// Ed25519 public key, a 2-byte checksum, and a 1-byte version, which is 35
/// bytes, and 35 bytes is exactly 56 base32 characters with no padding.
pub const service_id_len = 56;

/// The `.onion` suffix the SOCKS request carries after the service id. The
/// transport label in a locator supplies it, so glowcap stores the designator
/// without it and appends it here.
pub const onion_suffix = ".onion";

/// The length of the address field in the connect request: a service id plus
/// `.onion`. Both reference implementations write this as a literal 62, and it
/// is derived here so the two can be compared rather than trusted.
pub const address_len = service_id_len + onion_suffix.len;

comptime {
    // The literal both reference clients write. `onion-socks.rkt` says
    // `(write-byte 62 op)` and the suite's client writes the same width, so a
    // change to either constant above that broke this equality would silently
    // produce a request neither peer accepts.
    std.debug.assert(address_len == 62);
}

/// Bytes 35 of a decoded v3 address: the version, which is always 3.
const v3_version_byte: u8 = 3;

/// The domain string Tor prepends when it computes a v3 address checksum.
const checksum_domain = ".onion checksum";

pub const Error = error{
    /// The designator is not a well-formed version 3 onion address, so no
    /// socket is opened. Refusing here rather than at connect time is what the
    /// decision record asks for.
    InvalidServiceId,
    /// The proxy answered with a version, method, or reply code the request did
    /// not offer, or a truncated reply.
    ProtocolViolation,
    /// The proxy refused the connect. `reply` carries Tor's own code.
    ConnectRefused,
};

/// The greeting: version 5, one method, no authentication. A fixed three bytes,
/// so callers write the slice rather than building it.
pub const greeting = [_]u8{ 0x05, 0x01, 0x00 };

/// The greeting reply is always two bytes: the version and the method the proxy
/// selected. Tor selects no-authentication, which is the only method offered.
pub const greeting_reply_len = 2;

/// A connect request for an onion address: version, command, reserved, address
/// type, the address length, the address text, and the port.
pub const connect_request_len = 4 + 1 + address_len + 2;

/// Build the connect request for `service_id` into `buf`, returning the written
/// prefix. `service_id` is the bare designator, without the `.onion` suffix.
///
/// Refuses a designator that is not a well-formed v3 address, so a malformed
/// locator fails before anything is dialed.
pub fn writeConnectRequest(
    buf: *[connect_request_len]u8,
    service_id: []const u8,
) Error![]const u8 {
    try checkServiceId(service_id);

    buf[0] = 0x05; // SOCKS version 5.
    buf[1] = 0x01; // CONNECT.
    buf[2] = 0x00; // Reserved.
    buf[3] = 0x03; // Address type: domain name, which is how an onion is named.
    buf[4] = address_len;
    @memcpy(buf[5..][0..service_id_len], service_id);
    @memcpy(buf[5 + service_id_len ..][0..onion_suffix.len], onion_suffix);
    std.mem.writeInt(u16, buf[5 + address_len ..][0..2], virtual_port, .big);
    return buf[0..];
}

/// Check the greeting reply. The proxy must answer version 5 and must have
/// selected the no-authentication method, because that is the only one offered
/// and a proxy demanding another has nothing this client can do about it.
pub fn checkGreetingReply(bytes: []const u8) Error!void {
    if (bytes.len < greeting_reply_len) return Error.ProtocolViolation;
    if (bytes[0] != 0x05) return Error.ProtocolViolation;
    if (bytes[1] != 0x00) return Error.ProtocolViolation;
}

/// A connect reply's fixed head: version, reply code, reserved, address type.
/// The bound address that follows is variable, so a reader takes this much
/// first and then asks `boundAddress` how much more to take.
pub const connect_reply_head_len = 4;

/// How the bound address following a successful reply head is sized. IPv4 and
/// IPv6 have fixed trailing widths (address plus port). A domain carries its
/// one-byte length first. Tor customarily answers an onion connect with null
/// IPv4, but all three forms are legal SOCKS5 replies and must leave the stream
/// positioned at the same session-byte boundary.
pub const BoundAddress = union(enum) {
    fixed: usize,
    domain,
};

pub fn boundAddress(head: *const [connect_reply_head_len]u8) Error!BoundAddress {
    const port_len = 2;
    return switch (head[3]) {
        0x01 => .{ .fixed = 4 + port_len }, // IPv4.
        0x03 => .domain,
        0x04 => .{ .fixed = 16 + port_len }, // IPv6.
        else => Error.ProtocolViolation,
    };
}

/// Check a connect reply's head. Success is reply code zero. Anything else is
/// the proxy declining, and the code is Tor's own (for example `0x04` host
/// unreachable when a descriptor cannot be fetched).
pub fn checkConnectReply(head: *const [connect_reply_head_len]u8) Error!void {
    if (head[0] != 0x05) return Error.ProtocolViolation;
    if (head[1] != 0x00) return Error.ConnectRefused;
    if (head[2] != 0x00) return Error.ProtocolViolation;
    _ = try boundAddress(head);
}

/// Whether `designator` is a well-formed version 3 onion service id.
///
/// Three things are checked, and the third is what makes this stricter than the
/// pinned Goblins. Its regular expression is `^[a-z0-9]{55}d\.onion$`, which
/// admits `0`, `1`, `8`, and `9`, characters outside the base32 alphabet, so a
/// string containing one cannot decode to any address and Tor would refuse it a
/// round trip later. Refusing it here rejects nothing a real peer could name.
pub fn checkServiceId(designator: []const u8) Error!void {
    if (designator.len != service_id_len) return Error.InvalidServiceId;

    var decoded: [35]u8 = undefined;
    decodeBase32(designator, &decoded) catch return Error.InvalidServiceId;

    if (decoded[34] != v3_version_byte) return Error.InvalidServiceId;

    var hasher = std.crypto.hash.sha3.Sha3_256.init(.{});
    hasher.update(checksum_domain);
    hasher.update(decoded[0..32]);
    hasher.update(&[_]u8{v3_version_byte});
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    if (!std.mem.eql(u8, decoded[32..34], digest[0..2])) return Error.InvalidServiceId;
}

/// Decode lowercase RFC 4648 base32 with no padding. `out.len * 8` must be the
/// number of bits `text` carries, which for a v3 address is 56 characters into
/// 35 bytes exactly, so there are no leftover bits to reject separately.
fn decodeBase32(text: []const u8, out: *[35]u8) error{InvalidCharacter}!void {
    std.debug.assert(text.len * 5 == out.len * 8);
    var acc: u16 = 0;
    var bits: u4 = 0;
    var written: usize = 0;
    for (text) |c| {
        const value: u8 = switch (c) {
            'a'...'z' => c - 'a',
            '2'...'7' => c - '2' + 26,
            else => return error.InvalidCharacter,
        };
        acc = (acc << 5) | value;
        bits += 5;
        if (bits >= 8) {
            bits -= 8;
            out[written] = @truncate(acc >> bits);
            written += 1;
            // Drop the bits just written. Without this the accumulator keeps
            // every character it has ever seen and overflows its width.
            acc &= (@as(u16, 1) << bits) - 1;
        }
    }
    std.debug.assert(written == out.len);
}
