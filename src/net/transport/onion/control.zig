//! The Tor control protocol conversation that creates an onion service.
//!
//! Like its SOCKS sibling this module is bytes only: it formats requests into
//! caller buffers and classifies reply lines out of caller buffers, and it opens
//! no socket. The driver above moves them.
//!
//! The protocol is line-oriented text. A request is one line ending `\r\n`. A
//! reply is one or more lines, each beginning with a three-digit status code
//! followed by a separator that says whether more lines follow: `-` for an
//! intermediate line, ` ` for the last one, and `+` for a line introducing a
//! block terminated by a lone `.`.
//!
//! What glowcap sends is what the pinned Goblins sends, read off
//! `conformance/spritely-goblins/upstream/goblins/ocapn/netlayer/onion.rkt`:
//! a bare `AUTHENTICATE`, then `ADD_ONION NEW:ED25519-V3 PORT=9045,<target>` for
//! a fresh service or `ADD_ONION <key> PORT=9045,<target>` to restore one, and it
//! reads `250-ServiceID=` and `250-PrivateKey=` before the closing `250 OK`.
//!
//! Two things here go beyond that source, each because a real deployment needs
//! it. Cookie and password authentication exist because Goblins assumes an
//! unauthenticated control socket while a distribution's Tor package defaults to
//! a cookie, so without them the netlayer would work only against a hand-written
//! `torrc`. `SETEVENTS HS_DESC` exists because `ADD_ONION` returns before the
//! network can resolve the address, so a caller that publishes a locator and
//! expects an immediate dial has nothing to wait on.

const std = @import("std");

const socks5 = @import("socks5.zig");

/// The virtual port an `ADD_ONION` forwards. One authority with the SOCKS side,
/// because a mismatch between the port glowcap asks Tor to forward and the port
/// it dials would produce a service nothing could reach.
pub const virtual_port = socks5.virtual_port;

/// The key specification that asks Tor for a fresh version 3 service. Both the
/// key type and the request text are fixed by the OCapN draft and the control
/// protocol, so this is a constant rather than a setting.
pub const new_key_spec = "NEW:ED25519-V3";

/// The longest control line glowcap will format or accept. The control protocol
/// sets no limit of its own, so one is set here: every reply glowcap reads is a
/// status line or a short key-value pair, and a peer or a wedged daemon that
/// sends an unbounded line must fail rather than grow a buffer. A service key
/// blob is the longest legitimate value and sits far under this.
pub const max_line_bytes = 1024;

/// A line's terminator. The reader strips it, and every writer appends it.
pub const line_ending = "\r\n";

pub const Error = error{
    /// The formatted request does not fit the caller's buffer, which for a
    /// bounded protocol means an input longer than `max_line_bytes` allows.
    LineTooLong,
    /// A reply line is not `<three digits><separator>...`.
    MalformedReply,
    /// A credential carries a byte that cannot appear in a control-protocol
    /// quoted string. Refused rather than escaped, because a control character
    /// in a password is far more likely to be a mistake than an intention.
    InvalidCredential,
};

/// How the control endpoint expects to be authenticated.
///
/// The three arms are the three a real `torrc` produces. `none` is what an
/// unauthenticated Unix control socket gives, and what the pinned Goblins
/// assumes. `cookie` carries the bytes of the file named by `CookieAuthFile`,
/// which glowcap sends as hexadecimal. `password` carries the cleartext of a
/// `HashedControlPassword` setup, which glowcap sends as a quoted string.
pub const Auth = union(enum) {
    none,
    cookie: []const u8,
    password: []const u8,
};

/// Where Tor forwards the service's virtual port. Both forms are the control
/// protocol's own. The pinned Goblins always uses `unix`.
pub const Forward = union(enum) {
    /// A Unix socket path, formatted as `unix:<path>`.
    unix: []const u8,
    /// An address and port, formatted verbatim as Tor's `addr:port`.
    address: []const u8,
};

/// Format the `AUTHENTICATE` request for `auth` into `buf`.
///
/// The credential-free form is exactly the line the pinned Goblins sends.
pub fn writeAuthenticate(buf: []u8, auth: Auth) Error![]const u8 {
    return switch (auth) {
        .none => print(buf, "AUTHENTICATE{s}", .{line_ending}),
        .cookie => |bytes| blk: {
            if (bytes.len == 0) return Error.InvalidCredential;
            // The hexadecimal form takes no quoting and cannot contain a byte
            // the protocol reserves, which is why a cookie is sent this way and
            // a password is not.
            var w: Cursor = .{ .buf = buf };
            try w.append("AUTHENTICATE ");
            const hex = "0123456789abcdef";
            for (bytes) |b| {
                try w.appendByte(hex[b >> 4]);
                try w.appendByte(hex[b & 0x0f]);
            }
            try w.append(line_ending);
            break :blk checkLen(w.written());
        },
        .password => |text| blk: {
            try checkQuotable(text);
            var w: Cursor = .{ .buf = buf };
            try w.append("AUTHENTICATE \"");
            for (text) |b| {
                if (b == '"' or b == '\\') try w.appendByte('\\');
                try w.appendByte(b);
            }
            try w.append("\"" ++ line_ending);
            break :blk checkLen(w.written());
        },
    };
}

/// Format the `ADD_ONION` request that creates a fresh version 3 service.
pub fn writeAddOnionNew(buf: []u8, forward: Forward) Error![]const u8 {
    return writeAddOnion(buf, new_key_spec, forward);
}

/// Format the `ADD_ONION` request that restores the service `key` names.
///
/// `key` is the value Tor returned in `250-PrivateKey=`, verbatim and including
/// its `ED25519-V3:` prefix. glowcap never parses it, derives anything from it,
/// or holds it as anything but bytes: the control protocol produced it and the
/// control protocol consumes it, which is exactly the posture the pinned Goblins
/// takes with the string it hands its caller to store.
pub fn writeAddOnionRestore(buf: []u8, key: []const u8, forward: Forward) Error![]const u8 {
    try checkControlAtom(key);
    return writeAddOnion(buf, key, forward);
}

fn writeAddOnion(buf: []u8, key_spec: []const u8, forward: Forward) Error![]const u8 {
    // `key_spec` needs no check here. The only untrusted one arrives through
    // `writeAddOnionRestore`, which checks it at that entry point, and the other
    // caller passes `new_key_spec`, a constant.
    return switch (forward) {
        .unix => |path| blk: {
            try checkControlAtom(path);
            break :blk print(
                buf,
                "ADD_ONION {s} PORT={d},unix:{s}{s}",
                .{ key_spec, virtual_port, path, line_ending },
            );
        },
        .address => |addr| blk: {
            try checkControlAtom(addr);
            break :blk print(
                buf,
                "ADD_ONION {s} PORT={d},{s}{s}",
                .{ key_spec, virtual_port, addr, line_ending },
            );
        },
    };
}

/// Format the `SETEVENTS HS_DESC` request, which asks Tor to report hidden
/// service descriptor activity so a caller can wait for publication.
pub fn writeSetEventsHsDesc(buf: []u8) Error![]const u8 {
    return print(buf, "SETEVENTS HS_DESC{s}", .{line_ending});
}

/// What a reply line's separator says about the lines after it.
pub const Continuation = enum {
    /// `-`: an intermediate line. More follow.
    mid,
    /// ` `: the last line of this reply.
    end,
    /// `+`: this line introduces a block that ends with a lone `.`.
    data,
};

/// One parsed reply line: its status code, whether more lines follow, and the
/// text after the separator.
pub const Reply = struct {
    code: u16,
    continuation: Continuation,
    text: []const u8,

    /// Whether this is a success code. Tor answers `250` for the requests this
    /// module sends. Anything else is the daemon declining, and the caller
    /// reports the code rather than reinterpreting it.
    pub fn isOk(self: Reply) bool {
        return self.code == 250;
    }

    /// Split `text` at its first `=`, which is how `250-ServiceID=<id>` and
    /// `250-PrivateKey=<key>` carry their values. Null when there is no `=`,
    /// which is the ordinary shape of a bare `250 OK`.
    pub fn field(self: Reply) ?struct { key: []const u8, value: []const u8 } {
        const eq = std.mem.indexOfScalar(u8, self.text, '=') orelse return null;
        return .{ .key = self.text[0..eq], .value = self.text[eq + 1 ..] };
    }
};

/// Parse one reply line. `line` must already have its terminator removed.
///
/// A three-digit code and a separator are the whole grammar, so anything else is
/// refused rather than guessed at. The length bound is checked here as well as at
/// format time, because this side reads what the daemon sent.
pub fn parseLine(line: []const u8) Error!Reply {
    if (line.len > max_line_bytes) return Error.MalformedReply;
    if (line.len < 4) return Error.MalformedReply;

    var code: u16 = 0;
    for (line[0..3]) |c| {
        if (c < '0' or c > '9') return Error.MalformedReply;
        // Three digits cannot overflow a u16, so this needs no checked add.
        code = code * 10 + (c - '0');
    }

    const continuation: Continuation = switch (line[3]) {
        '-' => .mid,
        ' ' => .end,
        '+' => .data,
        else => return Error.MalformedReply,
    };

    return .{ .code = code, .continuation = continuation, .text = line[4..] };
}

/// Strip a line terminator from `line`, accepting either `\r\n` or a bare `\n`.
///
/// The pinned Goblins reads to `\n` and then trims a trailing `\r`, so a daemon
/// that sent only `\n` would be tolerated there. This matches that tolerance
/// rather than being stricter than the peer it must agree with.
pub fn trimLineEnding(line: []const u8) []const u8 {
    var out = line;
    if (out.len > 0 and out[out.len - 1] == '\n') out = out[0 .. out.len - 1];
    if (out.len > 0 and out[out.len - 1] == '\r') out = out[0 .. out.len - 1];
    return out;
}

/// A bounded append cursor over a caller buffer. The two credential forms build
/// their line byte by byte, so they need somewhere to refuse an overrun. Every
/// append returns `LineTooLong` rather than truncating, because a truncated
/// credential is a request the daemon would answer differently.
const Cursor = struct {
    buf: []u8,
    len: usize = 0,

    fn append(self: *Cursor, bytes: []const u8) Error!void {
        if (self.len + bytes.len > self.buf.len) return Error.LineTooLong;
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    fn appendByte(self: *Cursor, byte: u8) Error!void {
        if (self.len + 1 > self.buf.len) return Error.LineTooLong;
        self.buf[self.len] = byte;
        self.len += 1;
    }

    fn written(self: *const Cursor) []const u8 {
        return self.buf[0..self.len];
    }
};

fn print(buf: []u8, comptime fmt: []const u8, args: anytype) Error![]const u8 {
    const written = std.fmt.bufPrint(buf, fmt, args) catch return Error.LineTooLong;
    return checkLen(written);
}

fn checkLen(written: []const u8) Error![]const u8 {
    if (written.len > max_line_bytes) return Error.LineTooLong;
    return written;
}

/// Refuse a credential that could not survive the quoted-string form. The
/// control protocol's quoting covers `"` and `\`, which the writer escapes. A
/// carriage return or newline would end the line early and turn the rest of the
/// password into a forged request, so it is refused outright.
fn checkQuotable(text: []const u8) Error!void {
    for (text) |b| {
        if (b == '\r' or b == '\n' or b == 0) return Error.InvalidCredential;
    }
}

/// Refuse an unquoted control-line atom that would terminate the command or
/// split it into a second command. Spaces are allowed because Tor's returned
/// private-key form and endpoint grammar decide their own sub-syntax, but line
/// and NUL bytes are never valid inside one request line.
fn checkControlAtom(text: []const u8) Error!void {
    if (text.len == 0) return Error.InvalidCredential;
    for (text) |b| {
        if (b == '\r' or b == '\n' or b == 0) return Error.InvalidCredential;
    }
}
