//! The two live conversations with a Tor daemon: the SOCKS dial and the control
//! session that hosts a service.
//!
//! `socks5.zig` and `control.zig` own the bytes. This module owns the streams
//! that carry them. Nothing here decides protocol shape, so a change to what Tor
//! is told belongs next door and a change to how it is reached belongs here.

const std = @import("std");

const socks5 = @import("socks5.zig");
const control = @import("control.zig");
const endpoint_mod = @import("endpoint.zig");

const Endpoint = endpoint_mod.Endpoint;
const Stream = std.Io.net.Stream;

/// Reading a reply from the daemon failed, or the daemon said no.
pub const Error = error{
    /// The stream ended or faulted mid-conversation.
    ConnectionLost,
    /// The daemon answered something the protocol does not allow.
    ProtocolViolation,
    /// The daemon declined: a SOCKS connect it would not make, or a control
    /// request it answered with a non-250 code.
    Refused,
    /// Authentication was rejected.
    AuthFailed,
    /// A reply line ran past `control.max_line_bytes`, or the whole reply ran
    /// past `max_reply_lines`. Both are glowcap's bounds, not Tor's.
    ReplyTooLong,
    /// The designator is not a well-formed version 3 onion address.
    InvalidServiceId,
};

/// How many lines one control reply may carry before it is refused. Every reply
/// glowcap reads is a status line or two key-value pairs and a terminator, so
/// this is far above the real shapes and exists only so a wedged daemon cannot
/// stream without end.
pub const max_reply_lines = 64;

/// Upper bound for Tor's `ED25519-V3:` private-key blob returned by ADD_ONION.
pub const service_key_cap: usize = 256;

// --- The SOCKS dial ------------------------------------------------------

/// Run the SOCKS5 handshake for `service_id` over an already-connected stream to
/// Tor's SOCKS endpoint.
///
/// **The reply is read through a reader with no buffer at all**, so it is
/// safe to run before the session's own reader exists. A buffered
/// handshake reader can pull more off the socket than the reply, and the partner
/// may have spoken already: Tor is free to coalesce its SOCKS reply with the first
/// bytes the far peer sent, so those bytes would land in a buffer that dies here
/// and the session would wait forever for a hello already delivered. With no
/// buffer, `readSliceAll` reads exactly what it is asked for and leaves the rest
/// in the kernel, where whichever reader comes next will find it.
///
/// On return the stream is a transparent byte pipe and the next bytes either way
/// are the OCapN session's own, so both the `Connection` and the `FrameStream`
/// forms can build their readers afterwards.
pub fn socksHandshake(io: std.Io, stream: Stream, service_id: []const u8) Error!void {
    socks5.checkServiceId(service_id) catch return Error.InvalidServiceId;

    // Zero bytes of read buffer: see the note above. The write side buffers
    // freely, because a writer cannot lose bytes it has not been given.
    var no_read_buffer: [0]u8 = undefined;
    var write_store: [socks5.connect_request_len]u8 = undefined;
    var stream_reader = stream.reader(io, &no_read_buffer);
    var stream_writer = stream.writer(io, &write_store);
    const reader = &stream_reader.interface;
    const writer = &stream_writer.interface;

    writer.writeAll(&socks5.greeting) catch return Error.ConnectionLost;
    writer.flush() catch return Error.ConnectionLost;

    var greeting_reply: [socks5.greeting_reply_len]u8 = undefined;
    reader.readSliceAll(&greeting_reply) catch return Error.ConnectionLost;
    socks5.checkGreetingReply(&greeting_reply) catch return Error.ProtocolViolation;

    var request: [socks5.connect_request_len]u8 = undefined;
    const bytes = socks5.writeConnectRequest(&request, service_id) catch return Error.InvalidServiceId;
    writer.writeAll(bytes) catch return Error.ConnectionLost;
    writer.flush() catch return Error.ConnectionLost;

    var head: [socks5.connect_reply_head_len]u8 = undefined;
    reader.readSliceAll(&head) catch return Error.ConnectionLost;
    socks5.checkConnectReply(&head) catch |err| return switch (err) {
        socks5.Error.ConnectRefused => Error.Refused,
        else => Error.ProtocolViolation,
    };

    // The bound address is unused, Tor reports a null one, but it precedes the
    // session bytes and has to leave the stream, or the frame reader starts
    // mid-reply and refuses a frame that was never sent.
    var discard: [std.math.maxInt(u8) + 2]u8 = undefined;
    switch (socks5.boundAddress(&head) catch return Error.ProtocolViolation) {
        .fixed => |trailing| {
            std.debug.assert(trailing <= discard.len);
            reader.readSliceAll(discard[0..trailing]) catch return Error.ConnectionLost;
        },
        .domain => {
            var len_byte: [1]u8 = undefined;
            reader.readSliceAll(&len_byte) catch return Error.ConnectionLost;
            if (len_byte[0] == 0) return Error.ProtocolViolation;
            const trailing = @as(usize, len_byte[0]) + 2; // domain plus port
            reader.readSliceAll(discard[0..trailing]) catch return Error.ConnectionLost;
        },
    }
}

// --- The control session -------------------------------------------------

/// What `ADD_ONION` answered with: the service that now exists, and the key that
/// brings it back.
pub const Service = struct {
    /// The version 3 service id, without its `.onion` suffix. This is the
    /// locator designator glowcap publishes.
    id: [socks5.service_id_len]u8,
    /// The `250-PrivateKey=` value verbatim, including its `ED25519-V3:` prefix,
    /// or an empty slice when the request restored an existing service (Tor
    /// returns no key for one it did not mint). Borrowed from `key_store`.
    key: []const u8,

    pub fn designator(self: *const Service) []const u8 {
        return &self.id;
    }
};

/// One open control conversation with a Tor daemon.
///
/// The connection is not incidental: an `ADD_ONION` service created without the
/// `Detach` flag lives exactly as long as the control connection that asked for
/// it. So a hosting listener holds this open for its whole life, and dropping it
/// withdraws the service, which is also how the pinned Goblins stops hosting.
pub const ControlSession = struct {
    io: std.Io,
    stream: Stream,
    reader: Stream.Reader,
    writer: Stream.Writer,
    /// Storage for the key `ADD_ONION` returns. Owned here so a `Service` can
    /// borrow it for as long as this session is open. A version 3 key blob is
    /// well under this.
    key_store: [service_key_cap]u8,
    key_len: usize = 0,
    read_buf: [control.max_line_bytes]u8 = undefined,
    write_buf: [control.max_line_bytes]u8 = undefined,
    line: [control.max_line_bytes]u8 = undefined,

    /// Connect to `ep` and authenticate. `self` must already live at a stable
    /// address: the reader and writer recover themselves from `&interface` by
    /// field offset, so a `ControlSession` moved after `open` dangles (the same
    /// pin every stream wrapper in `net` holds).
    pub fn open(self: *ControlSession, io: std.Io, ep: Endpoint, auth: control.Auth) Error!void {
        const stream = ep.connect(io) catch return Error.ConnectionLost;
        errdefer stream.close(io);
        self.io = io;
        self.stream = stream;
        self.reader = stream.reader(io, &self.read_buf);
        self.writer = stream.writer(io, &self.write_buf);
        self.key_len = 0;

        var request: [control.max_line_bytes]u8 = undefined;
        const line = control.writeAuthenticate(&request, auth) catch return Error.ProtocolViolation;
        try self.send(line);
        self.expectOk() catch |err| return switch (err) {
            Error.Refused => Error.AuthFailed,
            else => err,
        };
    }

    pub fn close(self: *ControlSession) void {
        self.stream.close(self.io);
    }

    /// Ask Tor for a service forwarding `virtual_port` to `forward`. `restore_key`
    /// empty asks for a fresh one. Otherwise it is the stored key, passed through
    /// unchanged.
    pub fn addOnion(
        self: *ControlSession,
        forward: Endpoint,
        forward_text: []const u8,
        restore_key: []const u8,
    ) Error!Service {
        const target: control.Forward = if (forward.isUnix())
            .{ .unix = forward_text }
        else
            .{ .address = forward_text };

        var request: [control.max_line_bytes]u8 = undefined;
        const line = if (restore_key.len == 0)
            control.writeAddOnionNew(&request, target) catch return Error.ProtocolViolation
        else
            control.writeAddOnionRestore(&request, restore_key, target) catch return Error.ProtocolViolation;
        try self.send(line);

        var service: Service = .{ .id = undefined, .key = &.{} };
        var have_id = false;
        var lines: usize = 0;
        while (true) {
            lines += 1;
            if (lines > max_reply_lines) return Error.ReplyTooLong;
            const reply = try self.readReply();
            if (!reply.isOk()) return Error.Refused;
            if (reply.field()) |kv| {
                if (std.mem.eql(u8, kv.key, "ServiceID")) {
                    if (kv.value.len != socks5.service_id_len) return Error.ProtocolViolation;
                    socks5.checkServiceId(kv.value) catch return Error.InvalidServiceId;
                    @memcpy(&service.id, kv.value);
                    have_id = true;
                } else if (std.mem.eql(u8, kv.key, "PrivateKey")) {
                    if (kv.value.len > self.key_store.len) return Error.ReplyTooLong;
                    @memcpy(self.key_store[0..kv.value.len], kv.value);
                    self.key_len = kv.value.len;
                }
            }
            if (reply.continuation == .end) break;
        }
        if (!have_id) return Error.ProtocolViolation;
        service.key = self.key_store[0..self.key_len];
        return service;
    }

    fn send(self: *ControlSession, line: []const u8) Error!void {
        self.writer.interface.writeAll(line) catch return Error.ConnectionLost;
        self.writer.interface.flush() catch return Error.ConnectionLost;
    }

    fn expectOk(self: *ControlSession) Error!void {
        var lines: usize = 0;
        while (true) {
            lines += 1;
            if (lines > max_reply_lines) return Error.ReplyTooLong;
            const reply = try self.readReply();
            if (!reply.isOk()) return Error.Refused;
            if (reply.continuation == .end) return;
        }
    }

    /// Read one reply line. Bounded twice: a line longer than the buffer is
    /// refused rather than truncated, because a truncated status line could read
    /// as a different status.
    fn readReply(self: *ControlSession) Error!control.Reply {
        const r = &self.reader.interface;
        var len: usize = 0;
        while (true) {
            const b = r.takeByte() catch return Error.ConnectionLost;
            if (b == '\n') break;
            if (len == self.line.len) return Error.ReplyTooLong;
            self.line[len] = b;
            len += 1;
        }
        const text = control.trimLineEnding(self.line[0..len]);
        return control.parseLine(text) catch return Error.ProtocolViolation;
    }
};
