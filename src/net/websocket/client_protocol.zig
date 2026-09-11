//! RFC 6455 client protocol machinery over byte slices.
//!
//! No reader, socket, scheduler, completion, transport route, or CapTP
//! authority lives here. Pollable and completion-backed clients consume the
//! same frame and upgrade grammar without sharing their I/O mechanics.

const std = @import("std");

// --- The WebSocket frame codec (client side) -------------------------------
//
// Pure over byte buffers so untrusted-input tests drive it without a socket.

/// RFC 6455 opcodes this client speaks. Text frames are refused outright:
/// glowcap bytes are binary, and a text frame from a relay is a fault.
pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xa,
    _,
};

/// Opcodes this client may place on the wire. Kept separate from `Opcode`,
/// whose non-exhaustive shape exists to classify untrusted inbound values.
pub const OutgoingOpcode = enum(u4) {
    continuation = 0x0,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xa,
};

/// One parsed frame header. `len` is the payload length; the payload itself is
/// streamed by the caller, never materialized from this length.
pub const FrameHeader = struct {
    opcode: Opcode,
    fin: bool,
    len: u64,
};

pub const ParseError = error{
    /// A reserved bit was set (no extension is negotiated), the server sent a
    /// masked frame (RFC 6455 forbids it), the opcode is unknown or text, a
    /// length is not minimally encoded, or a control frame has an invalid size
    /// or arrives fragmented.
    ProtocolViolation,
};

/// Control frames carry at most 125 payload bytes (RFC 6455 §5.5); the
/// parked-listener wait and the reader's ping handling size their stack
/// buffers from this.
pub const max_control_payload = 125;

/// The widest header a client writes: 2 base bytes, 8 extended-length bytes,
/// 4 mask bytes.
pub const max_header_len = 14;

/// Build a client frame header into `buf` (masked — every client frame is) and
/// return the written prefix.
pub fn writeFrameHeader(
    buf: *[max_header_len]u8,
    opcode: OutgoingOpcode,
    len: u64,
    mask: [4]u8,
) error{ ControlPayloadTooLarge, PayloadTooLarge }![]const u8 {
    if (len > @as(u64, std.math.maxInt(i64))) return error.PayloadTooLarge;
    switch (opcode) {
        .close, .ping, .pong => if (len > max_control_payload) return error.ControlPayloadTooLarge,
        .continuation, .binary => {},
    }
    buf[0] = 0x80 | @as(u8, @backingInt(opcode)); // FIN, no RSV
    var at: usize = 2;
    if (len < 126) {
        buf[1] = 0x80 | @as(u8, @intCast(len));
    } else if (len <= std.math.maxInt(u16)) {
        buf[1] = 0x80 | 126;
        std.mem.writeInt(u16, buf[2..4], @intCast(len), .big);
        at = 4;
    } else {
        buf[1] = 0x80 | 127;
        std.mem.writeInt(u64, buf[2..10], len, .big);
        at = 10;
    }
    @memcpy(buf[at..][0..4], &mask);
    return buf[0 .. at + 4];
}

/// The `Sec-WebSocket-Accept` value for a request key: base64 of the SHA-1
/// over the key joined with the RFC 6455 GUID.
pub fn acceptKey(out: *[28]u8, request_key: []const u8) void {
    const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(request_key);
    sha.update(guid);
    var digest: [20]u8 = undefined;
    sha.final(&digest);
    _ = std.base64.standard.Encoder.encode(out, &digest);
}

/// The cap on the relay's HTTP upgrade response. A response still growing past
/// this is refused — the relay is not fully trusted, so the handshake reader
/// is bounded like any inbound parser.
pub const max_upgrade_response_bytes = 4096;
pub const upgrade_request_fmt =
    "GET {s}{s}{c}{s}={s} HTTP/1.1\r\n" ++
    "Host: {s}\r\n" ++
    "Upgrade: websocket\r\n" ++
    "Connection: Upgrade\r\n" ++
    "Sec-WebSocket-Key: {s}\r\n" ++
    "Sec-WebSocket-Version: 13\r\n\r\n";

/// Validate the optional status code and UTF-8 reason in a close payload.
/// The one-byte shape is rejected by the header parser; this owns the semantic
/// checks that require the complete, bounded payload.
pub fn validateClosePayload(payload: []const u8) ParseError!void {
    if (payload.len == 0) return;
    if (payload.len == 1) return ParseError.ProtocolViolation;
    const code = std.mem.readInt(u16, payload[0..2], .big);
    const defined = code >= 1000 and code <= 1014 and
        code != 1004 and code != 1005 and code != 1006;
    const application = code >= 3000 and code < 5000;
    if (!defined and !application) return ParseError.ProtocolViolation;
    if (!std.unicode.utf8ValidateSlice(payload[2..])) return ParseError.ProtocolViolation;
}

/// The full wire length of the frame header starting `buffered`, or null when
/// fewer than the base two bytes are present. The parked probe uses this to
/// avoid blocking mid-header.
pub fn headerLenOf(buffered: []const u8) ?usize {
    if (buffered.len < 2) return null;
    const len7 = buffered[1] & 0x7f;
    return switch (len7) {
        126 => 4,
        127 => 10,
        else => 2,
    };
}

pub const ParsedHeader = struct {
    frame: FrameHeader,
    header_len: usize,
};

/// Number of payload bytes that must be buffered before a parsed frame can be
/// admitted. Data payload streams through the caller; bounded control payload
/// is part of the protocol decision and must be available in full.
pub fn controlPayloadLen(header: FrameHeader) usize {
    return switch (header.opcode) {
        .close, .ping, .pong => @intCast(header.len),
        .binary, .continuation => 0,
        else => unreachable, // parseHeaderBytes refused it
    };
}

/// Parse one completely buffered server-frame header. This is the sole RFC
/// 6455 header authority shared by the blocking resident and completion
/// adapter; null means only that more header bytes are required.
pub fn parseHeaderBytes(buffered: []const u8) ParseError!?ParsedHeader {
    const need = headerLenOf(buffered) orelse return null;
    if (buffered.len < need) return null;
    const b0 = buffered[0];
    const b1 = buffered[1];
    if (b0 & 0x70 != 0 or b1 & 0x80 != 0)
        return ParseError.ProtocolViolation;
    const opcode: Opcode = @fromBackingInt(@intCast(@as(u4, @truncate(b0 & 0x0f))));
    const fin = b0 & 0x80 != 0;
    const len7 = b1 & 0x7f;
    const len: u64 = switch (len7) {
        126 => blk: {
            const extended = std.mem.readInt(u16, buffered[2..4], .big);
            if (extended < 126) return ParseError.ProtocolViolation;
            break :blk extended;
        },
        127 => blk: {
            const extended = std.mem.readInt(u64, buffered[2..10], .big);
            if (extended <= std.math.maxInt(u16) or extended & (1 << 63) != 0)
                return ParseError.ProtocolViolation;
            break :blk extended;
        },
        else => len7,
    };
    switch (opcode) {
        .continuation, .binary => {},
        .close => if (len == 1 or len > max_control_payload or !fin)
            return ParseError.ProtocolViolation,
        .ping, .pong => if (len > max_control_payload or !fin)
            return ParseError.ProtocolViolation,
        .text => return ParseError.ProtocolViolation,
        _ => return ParseError.ProtocolViolation,
    }
    return .{ .frame = .{ .opcode = opcode, .fin = fin, .len = len }, .header_len = need };
}

pub const UpgradeResponseValidator = struct {
    accept_seen: bool = false,
    accept_ok: bool = false,
    upgrade_ok: bool = false,
    connection_ok: bool = false,
    malformed: bool = false,

    pub fn observe(self: *@This(), line: []const u8, expected_accept: *const [28]u8) void {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
            self.malformed = true;
            return;
        };
        const name = line[0..colon];
        if (!validHeaderName(name) or !validHeaderValue(line[colon + 1 ..])) {
            self.malformed = true;
            return;
        }
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "sec-websocket-accept")) {
            // RFC 6455 defines one computed Accept value, not a list-valued
            // field. A duplicate must not let one valid line mask another.
            if (self.accept_seen) {
                self.malformed = true;
                return;
            }
            self.accept_seen = true;
            self.accept_ok = std.mem.eql(u8, value, expected_accept[0..]);
        } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-extensions") or
            std.ascii.eqlIgnoreCase(name, "sec-websocket-protocol"))
        {
            // The client offers neither extensions nor a subprotocol. A server
            // may select only values the client offered, so accepting either
            // response field would install wire semantics this parser does not
            // implement.
            self.malformed = true;
        } else if (std.ascii.eqlIgnoreCase(name, "upgrade")) {
            self.upgrade_ok = self.upgrade_ok or headerHasToken(value, "websocket");
        } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
            self.connection_ok = self.connection_ok or headerHasToken(value, "upgrade");
        }
    }

    pub fn valid(self: @This()) bool {
        return !self.malformed and self.accept_ok and self.upgrade_ok and self.connection_ok;
    }
};

fn validHeaderName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        switch (byte) {
            '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => {},
            else => return false,
        }
    }
    return true;
}

fn validHeaderValue(value: []const u8) bool {
    for (value) |byte| {
        if (byte == '\t' or (byte >= 0x20 and byte != 0x7f)) continue;
        return false;
    }
    return true;
}

pub fn validUpgradeStatus(line: []const u8) bool {
    const prefix = "HTTP/1.1 101";
    if (!std.mem.startsWith(u8, line, prefix)) return false;
    return line.len == prefix.len or line[prefix.len] == ' ' or line[prefix.len] == '\t';
}

fn headerHasToken(value: []const u8, expected: []const u8) bool {
    var tokens = std.mem.splitScalar(u8, value, ',');
    while (tokens.next()) |raw| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, raw, " \t"), expected)) return true;
    }
    return false;
}

/// Validate the complete HTTP header block of an RFC 6455 server upgrade.
/// `bytes` excludes the terminating blank line; header names and token values
/// are case-insensitive, while `Sec-WebSocket-Accept` must match exactly.
pub fn validUpgradeResponse(bytes: []const u8, expected_accept: *const [28]u8) bool {
    var lines = std.mem.splitSequence(u8, bytes, "\r\n");
    if (!validUpgradeStatus(lines.next() orelse return false)) return false;
    var response = UpgradeResponseValidator{};
    while (lines.next()) |line| response.observe(line, expected_accept);
    return response.valid();
}

/// The protocol meaning of one complete frame. Adapters own byte acquisition
/// and reply submission; this is the single authority for fragmentation,
/// control/data classification, and close-payload validation.
pub const FrameEffect = enum { data, ping, pong, close };

/// One complete frame prefix. Data payload follows `payload_start` and may be
/// split across reads, so only its header is consumed here. Control payload is
/// bounded, must be present in full, and is included in `consumed_len`.
pub const ParsedFrame = struct {
    header: FrameHeader,
    effect: FrameEffect,
    payload_start: usize,
    consumed_len: usize,

    pub fn controlPayload(self: ParsedFrame, bytes: []const u8) []const u8 {
        return switch (self.effect) {
            .data => &.{},
            .ping, .pong, .close => bytes[self.payload_start..self.consumed_len],
        };
    }
};

pub fn admitFrame(
    fragmented: *bool,
    header: FrameHeader,
    control_payload: []const u8,
) ParseError!FrameEffect {
    switch (header.opcode) {
        .binary => {
            if (fragmented.*) return ParseError.ProtocolViolation;
            fragmented.* = !header.fin;
            return .data;
        },
        .continuation => {
            if (!fragmented.*) return ParseError.ProtocolViolation;
            if (header.fin) fragmented.* = false;
            return .data;
        },
        .ping, .pong, .close => {
            if (control_payload.len != @as(usize, @intCast(header.len)))
                return ParseError.ProtocolViolation;
            return switch (header.opcode) {
                .ping => .ping,
                .pong => .pong,
                .close => blk: {
                    try validateClosePayload(control_payload);
                    break :blk .close;
                },
                else => unreachable,
            };
        },
        else => unreachable, // parseHeaderBytes refused it
    }
}

/// Parse and admit one complete frame prefix from `bytes`. Null means the
/// header, or a bounded control payload, is split across reads. Fragmentation
/// state changes only after all bytes needed to admit this frame are present.
pub fn parseFrameBytes(fragmented: *bool, bytes: []const u8) ParseError!?ParsedFrame {
    const parsed = (try parseHeaderBytes(bytes)) orelse return null;
    const control_len = controlPayloadLen(parsed.frame);
    const consumed_len = parsed.header_len + control_len;
    if (bytes.len < consumed_len) return null;
    const payload = bytes[parsed.header_len..consumed_len];
    return .{
        .header = parsed.frame,
        .effect = try admitFrame(fragmented, parsed.frame, payload),
        .payload_start = parsed.header_len,
        .consumed_len = consumed_len,
    };
}
