//! Checked Syrup leaf readers for hostile byte slices.
//!
//! These routines mutate only a caller-owned cursor and borrow their results
//! from the supplied bytes. Length and collection caps are owned here so every
//! higher Syrup projection makes the same early FrameTooLarge decision.

const std = @import("std");

const model = @import("model");
const limits = @import("codec_limits");
const shared = @import("../shared.zig");

const Error = shared.Error;

/// Syrup's public name for the shared codec decode recursion bound.
pub const max_decode_nesting: usize = limits.max_decode_nesting;

/// Decode-time width bound for a single `list` / `set` / `struct` collection —
/// the width sibling of `max_decode_nesting`. Collection width is
/// attacker-controlled, and every later walk over a collection — the lazy
/// view's `len`/`at`, session validation, owned materialization — is linear in
/// the element count, so width needs an explicit bound rather than being an
/// emergent property of whatever byte cap a deployment configures. An
/// over-wide collection fails loud as `MalformedFrame` during the slice walk,
/// before any of those walks run. The bound sits just above what the *default*
/// streaming byte cap can even carry (one-byte elements under the 1 MiB
/// `max_frame_bytes`), so on the streaming path with default limits the byte
/// cap's `.too_large` verdict always fires first (the ADR-0041 contract the
/// C ABI pins); this cap binds the uncapped whole-frame entry points and any
/// deployment that raises the byte cap. Ordinary CapTP messages carry a
/// handful of arguments, six orders of magnitude below it.
pub const max_collection_elements: usize = 1 << 20;

/// Byte-position cap threaded through the decode walk. Whole-frame entry
/// points (`decodeBody`, the owned readers, re-parses of already-bounded
/// sub-slices) pass this no-op limit; only the streaming `decodePrefix`
/// passes its `max_frame_bytes`, so a length prefix that declares a body past
/// the cap fails `FrameTooLarge` the moment the prefix is read, per ADR-0029
/// the in-flight frame is refused *during* decode, not after the adapter has
/// buffered the whole cap.
pub const no_limit: usize = std.math.maxInt(usize);

/// The two halves of a decoded `sig-val` record, borrowed from the frame.
pub const SignatureView = struct {
    r: []const u8,
    s: []const u8,
};

/// Read one length-prefixed Syrup leaf — `<len><marker><payload>` — at
/// `cursor`, advancing past it and returning the borrowed payload. The three
/// leaf kinds share this one reader and differ only in their `marker` byte:
/// `:` for byte-strings, `"` for strings, `'` for symbols. The length digits
/// are canonical-checked and parsed with overflow rejection, and the body is
/// bound-checked without wrappable arithmetic, so a hostile length fails
/// closed (`Incomplete` / `MalformedFrame` / `FrameTooLarge`) rather than
/// reading out of bounds.
fn readLengthPrefixed(bytes: []const u8, cursor: *usize, comptime marker: u8, limit: usize) Error![]const u8 {
    const len_start = cursor.*;
    while (cursor.* < bytes.len and std.ascii.isDigit(bytes[cursor.*])) {
        cursor.* += 1;
    }
    if (cursor.* >= bytes.len) return Error.Incomplete;
    if (cursor.* == len_start or bytes[cursor.*] != marker) {
        return Error.MalformedFrame;
    }
    try rejectNonCanonicalDigits(bytes, len_start, cursor.*);

    const len = parseDecimalDigits(usize, bytes[len_start..cursor.*]) orelse {
        return Error.MalformedFrame;
    };
    cursor.* += 1;

    const body_start = cursor.*;
    if (len > limit -| body_start) return Error.FrameTooLarge;
    if (len > bytes.len - body_start) {
        return Error.Incomplete;
    }
    const body_end = body_start + len;
    cursor.* = body_end;
    return bytes[body_start..body_end];
}

pub fn readString(bytes: []const u8, cursor: *usize) Error![]const u8 {
    return readStringLimited(bytes, cursor, no_limit);
}

pub fn readStringLimited(bytes: []const u8, cursor: *usize, limit: usize) Error![]const u8 {
    const string = try readLengthPrefixed(bytes, cursor, '"', limit);
    if (!std.unicode.utf8ValidateSlice(string)) return Error.MalformedFrame;
    return string;
}

pub fn readSymbol(bytes: []const u8, cursor: *usize) Error![]const u8 {
    return readSymbolLimited(bytes, cursor, no_limit);
}

pub fn readSymbolLimited(bytes: []const u8, cursor: *usize, limit: usize) Error![]const u8 {
    const symbol = try readLengthPrefixed(bytes, cursor, '\'', limit);
    if (!std.unicode.utf8ValidateSlice(symbol)) return Error.MalformedFrame;
    return symbol;
}

/// Read a `[ … ]` list of positive ints, returning the borrowed body slice
/// between the brackets and advancing `cursor` past the closing `]`. Width is
/// bounded by `max_collection_elements` and the walk refuses to cross `limit`,
/// like its sibling collection readers.
pub fn readPositionList(bytes: []const u8, cursor: *usize, limit: usize) Error![]const u8 {
    try readByte(bytes, cursor, '[');
    const body_start = cursor.*;
    var elements: usize = 0;
    while (cursor.* < bytes.len and bytes[cursor.*] != ']') {
        elements += 1;
        if (elements > max_collection_elements) return Error.MalformedFrame;
        if (cursor.* > limit) return Error.FrameTooLarge;
        _ = try readPositiveInt(bytes, cursor);
    }
    if (cursor.* >= bytes.len) {
        return Error.Incomplete;
    }

    const body = bytes[body_start..cursor.*];
    cursor.* += 1;
    return body;
}

pub fn readPeerKeyQ(bytes: []const u8, cursor: *usize, limit: usize) Error![]const u8 {
    // `readBalanced` consumes against the live buffer, so a truncated list is a
    // genuine `Incomplete` (read more). `list` is then a *complete* slice, so a
    // short read while re-parsing it is malformed, not stream-incomplete.
    const list = try readBalancedLimited(bytes, cursor, '[', ']', limit);
    return parsePeerKeyQ(list) catch |err| switch (err) {
        Error.Incomplete => Error.MalformedFrame,
        else => |other| other,
    };
}

/// Parse the spec-pinned public-key record (CapTP spec § Public Key):
///
/// ```text
/// ['public-key ['ecc ['curve 'Ed25519] ['flags 'eddsa] ['q q_value]]]
/// ```
///
/// The grammar is matched exactly, algorithm tags included. A record that
/// claims any other curve or scheme is refused as malformed: accepting it and
/// then verifying its `q` as an Ed25519 key would silently coerce the claimed
/// algorithm, exactly the mis-decode ADR-0003's symmetric refusal forbids.
fn parsePeerKeyQ(list: []const u8) Error![]const u8 {
    var cursor: usize = 0;
    try readByte(list, &cursor, '[');
    try expectSymbol(list, &cursor, "public-key");
    try readByte(list, &cursor, '[');
    try expectSymbol(list, &cursor, "ecc");
    try readByte(list, &cursor, '[');
    try expectSymbol(list, &cursor, "curve");
    try expectSymbol(list, &cursor, "Ed25519");
    try readByte(list, &cursor, ']');
    try readByte(list, &cursor, '[');
    try expectSymbol(list, &cursor, "flags");
    try expectSymbol(list, &cursor, "eddsa");
    try readByte(list, &cursor, ']');
    try readByte(list, &cursor, '[');
    try expectSymbol(list, &cursor, "q");
    const q = try readBytes(list, &cursor);
    try readByte(list, &cursor, ']');
    try readByte(list, &cursor, ']');
    try readByte(list, &cursor, ']');
    try expectEnd(list, cursor);
    return q;
}

fn expectSymbol(bytes: []const u8, cursor: *usize, expected: []const u8) Error!void {
    const symbol = try readSymbol(bytes, cursor);
    if (!std.mem.eql(u8, symbol, expected)) return Error.MalformedFrame;
}

pub fn readSignatureView(bytes: []const u8, cursor: *usize) Error!SignatureView {
    return readSignatureViewLimited(bytes, cursor, no_limit);
}

pub fn readSignatureViewLimited(bytes: []const u8, cursor: *usize, limit: usize) Error!SignatureView {
    // See `readPeerKeyQ`: `list` is complete, so a short re-parse is malformed.
    const list = try readBalancedLimited(bytes, cursor, '[', ']', limit);
    return parseSignatureView(list) catch |err| switch (err) {
        Error.Incomplete => Error.MalformedFrame,
        else => |other| other,
    };
}

/// Parse the spec-pinned signature record (CapTP spec § Signature):
///
/// ```text
/// ['sig-val ['eddsa ['r r_value] ['s s_value]]]
/// ```
///
/// As with `parsePeerKeyQ`, the grammar is matched exactly: a record claiming
/// any signature scheme other than `eddsa` is refused rather than having its
/// `r`/`s` bytes verified as Ed25519 anyway.
fn parseSignatureView(list: []const u8) Error!SignatureView {
    var cursor: usize = 0;
    try readByte(list, &cursor, '[');
    try expectSymbol(list, &cursor, "sig-val");
    try readByte(list, &cursor, '[');
    try expectSymbol(list, &cursor, "eddsa");
    try readByte(list, &cursor, '[');
    try expectSymbol(list, &cursor, "r");
    const r = try readBytes(list, &cursor);
    try readByte(list, &cursor, ']');
    try readByte(list, &cursor, '[');
    try expectSymbol(list, &cursor, "s");
    const s = try readBytes(list, &cursor);
    try readByte(list, &cursor, ']');
    try readByte(list, &cursor, ']');
    try readByte(list, &cursor, ']');
    try expectEnd(list, cursor);
    return .{ .r = r, .s = s };
}

pub fn readOptionalPositiveInt(bytes: []const u8, cursor: *usize) Error!?u64 {
    if (cursor.* < bytes.len and bytes[cursor.*] == 'f') {
        cursor.* += 1;
        return null;
    }
    return try readPositiveInt(bytes, cursor);
}

/// Canonical Syrup forbids a superfluous leading zero in any digit run, a
/// length prefix or an integer magnitude. `007"…` and `00+` spell the same
/// value as `7"…` and `0+`, so a lenient read would admit several wire
/// spellings of one message and quietly void byte-level canonicality.
fn rejectNonCanonicalDigits(bytes: []const u8, start: usize, end: usize) Error!void {
    if (end - start > 1 and bytes[start] == '0') return Error.MalformedFrame;
}

/// Hand-rolled base-10 parse for a digit run already scanned as ASCII `0`-`9`
/// (and, for length/integer leaves, already refused a leading zero). Overflow
/// returns `null` — the same verdict `std.fmt.parseInt` gave on these paths —
/// without the formatter's digit-class / base machinery on every length and int.
fn parseDecimalDigits(comptime T: type, digits: []const u8) ?T {
    var value: T = 0;
    for (digits) |c| {
        value = std.math.mul(T, value, 10) catch return null;
        value = std.math.add(T, value, c -% '0') catch return null;
    }
    return value;
}

/// Scan the leading decimal run at `cursor`, advancing past it, and return the
/// borrowed digit slice. `Incomplete` when the run reaches the end with no
/// terminator byte to inspect, `MalformedFrame` when it is empty or
/// non-canonical (a leading zero). The cursor is left on the terminator byte the
/// caller reads (a `+`/`-` sign, or the `+` a positive integer requires), which
/// is guaranteed in-bounds by the `Incomplete` check. The shared prologue of
/// every Syrup integer reader.
fn scanDigits(bytes: []const u8, cursor: *usize) Error![]const u8 {
    const start = cursor.*;
    while (cursor.* < bytes.len and std.ascii.isDigit(bytes[cursor.*])) {
        cursor.* += 1;
    }
    if (cursor.* >= bytes.len) return Error.Incomplete;
    if (cursor.* == start) return Error.MalformedFrame;
    try rejectNonCanonicalDigits(bytes, start, cursor.*);
    return bytes[start..cursor.*];
}

/// Apply the sign terminator at `cursor` to a scanned decimal `digits` run,
/// consuming the terminator. Returns the signed `i64` value when the magnitude
/// fits the i64 range — including the `minInt` boundary the
/// `9223372036854775808-` encoding names — `null` when the magnitude overflows
/// i64, so the caller decides (reject it, or take the arbitrary-precision arm),
/// and `MalformedFrame` for `0-` (the spec has exactly one zero, `0+`) and any
/// non-sign terminator. The shared sign/magnitude tail of `readInteger` and
/// `readIntegerValue`.
fn signedI64FromDigits(digits: []const u8, bytes: []const u8, cursor: *usize) Error!?i64 {
    // Parse the magnitude as u64, not i64: `writeSignedMagnitude` emits
    // `minInt(i64)` as the unsigned magnitude 2^63 (`9223372036854775808`), which
    // does not fit i64, so parsing it as i64 would reject a frame this codec
    // itself produced. The sign is applied below, handling the minInt boundary so
    // the full i64 range round-trips and matches the Cap'n Proto codec.
    const magnitude: ?u64 = parseDecimalDigits(u64, digits);
    const max_positive: u64 = @intCast(std.math.maxInt(i64));
    switch (bytes[cursor.*]) {
        '+' => {
            cursor.* += 1;
            if (magnitude) |m| {
                if (m <= max_positive) return @intCast(m);
            }
            return null;
        },
        '-' => {
            cursor.* += 1;
            if (magnitude) |m| {
                if (m == 0) return Error.MalformedFrame;
                if (m == max_positive + 1) return std.math.minInt(i64);
                if (m <= max_positive) return -@as(i64, @intCast(m));
            }
            return null;
        },
        else => return Error.MalformedFrame,
    }
}

pub fn readPositiveInt(bytes: []const u8, cursor: *usize) Error!u64 {
    const digits = try scanDigits(bytes, cursor);
    if (bytes[cursor.*] != '+') return Error.MalformedFrame;
    const value = parseDecimalDigits(u64, digits) orelse return Error.MalformedFrame;
    cursor.* += 1;
    return value;
}

/// Read an arbitrary-precision OCapN Integer. The split is canonical: a value
/// representable as `i64` never takes the decimal-magnitude arm.
pub fn readIntegerValue(bytes: []const u8, cursor: *usize) Error!model.Integer {
    const digits = try scanDigits(bytes, cursor);
    // Capture the sign before `signedI64FromDigits` consumes the terminator: an
    // overflow (null) takes the arbitrary-precision arm, whose sign is that
    // terminator. A non-sign terminator never returns null — it errors — so the
    // captured byte is `+` or `-` on every path that reads it.
    const sign_byte = bytes[cursor.*];
    if (try signedI64FromDigits(digits, bytes, cursor)) |value| {
        return .{ .integer = value };
    }
    return .{ .big_integer = .{ .negative = sign_byte == '-', .digits = digits } };
}

pub fn readIntegerArgument(bytes: []const u8, cursor: *usize) Error!model.view.Argument {
    return switch (try readIntegerValue(bytes, cursor)) {
        .integer => |value| .{ .integer = value },
        .big_integer => |big| .{ .big_integer = big },
    };
}

pub fn readInteger(bytes: []const u8, cursor: *usize) Error!i64 {
    const digits = try scanDigits(bytes, cursor);
    // Hint integers use the bounded HintValue arm; a magnitude past i64 is not
    // representable there and is therefore malformed.
    return (try signedI64FromDigits(digits, bytes, cursor)) orelse Error.MalformedFrame;
}

pub fn readBool(bytes: []const u8, cursor: *usize) Error!bool {
    if (cursor.* >= bytes.len) return Error.Incomplete;
    switch (bytes[cursor.*]) {
        't' => {
            cursor.* += 1;
            return true;
        },
        'f' => {
            cursor.* += 1;
            return false;
        },
        else => return Error.MalformedFrame,
    }
}

/// Read a `'D'`-tagged `binary64` double: the marker then 8 bytes IEEE-754
/// big-endian. Advances `cursor` past all 9 bytes.
pub fn readFloat64(bytes: []const u8, cursor: *usize) Error!f64 {
    if (cursor.* >= bytes.len or bytes[cursor.*] != 'D') return Error.MalformedFrame;
    if (cursor.* + 9 > bytes.len) return Error.Incomplete;
    const raw = std.mem.readInt(u64, bytes[cursor.* + 1 ..][0..8], .big);
    cursor.* += 9;
    return @bitCast(raw);
}

/// Read a Syrup byte-string (`<len>:<bytes>`) at `cursor` and advance past it,
/// returning the borrowed payload. The length prefix is parsed with overflow
/// rejection and the body is bound-checked without wrappable arithmetic, so a
/// hostile length fails closed (`Incomplete` / `MalformedFrame`) rather than
/// reading out of bounds. Exposed so callers that need a raw byte-string at a
/// known offset reuse this reader instead of re-deriving the wire grammar.
fn readBytes(bytes: []const u8, cursor: *usize) Error![]const u8 {
    return readBytesLimited(bytes, cursor, no_limit);
}

pub fn readBytesLimited(bytes: []const u8, cursor: *usize, limit: usize) Error![]const u8 {
    return readLengthPrefixed(bytes, cursor, ':', limit);
}

pub fn readBalanced(bytes: []const u8, cursor: *usize, open: u8, close: u8) Error![]const u8 {
    return readBalancedLimited(bytes, cursor, open, close, no_limit);
}

fn readBalancedLimited(bytes: []const u8, cursor: *usize, open: u8, close: u8, limit: usize) Error![]const u8 {
    const start = cursor.*;
    try readByte(bytes, cursor, open);
    var depth: usize = 1;
    while (cursor.* < bytes.len) {
        if (cursor.* > limit) return Error.FrameTooLarge;
        const byte = bytes[cursor.*];
        cursor.* += 1;
        if (byte == open) {
            depth += 1;
        } else if (byte == close) {
            depth -= 1;
            if (depth == 0) {
                return bytes[start..cursor.*];
            }
        } else if (std.ascii.isDigit(byte)) {
            cursor.* -= 1;
            try skipByteStringLike(bytes, cursor, limit);
        } else if (byte == ':' or byte == '"' or byte == '\'') {
            cursor.* -= 1;
            try skipByteStringLike(bytes, cursor, limit);
        } else if (byte == 'D') {
            // A `D`-tagged binary64 is the marker plus 8 raw IEEE-754 payload
            // bytes (the marker is already consumed). Skip the payload as opaque
            // so a payload byte equal to `<`/`>`/`[`/`]` or a digit cannot
            // corrupt the depth count or trigger a bogus length parse.
            if (bytes.len - cursor.* < 8) return Error.Incomplete;
            cursor.* += 8;
        }
    }
    return Error.Incomplete;
}

pub fn skipSyrupValue(bytes: []const u8, cursor: *usize) Error!void {
    return skipSyrupValueLimited(bytes, cursor, no_limit);
}

pub fn skipSyrupValueLimited(bytes: []const u8, cursor: *usize, limit: usize) Error!void {
    if (cursor.* >= bytes.len) return Error.Incomplete;
    switch (bytes[cursor.*]) {
        '<' => _ = try readBalancedLimited(bytes, cursor, '<', '>', limit),
        '[' => _ = try readBalancedLimited(bytes, cursor, '[', ']', limit),
        '{' => _ = try readBalancedLimited(bytes, cursor, '{', '}', limit),
        't', 'f' => cursor.* += 1,
        // A `D`-tagged binary64: the marker plus 8 raw IEEE-754 payload bytes.
        'D' => {
            if (bytes.len - cursor.* < 9) return Error.Incomplete;
            cursor.* += 9;
        },
        '0'...'9' => try skipByteStringLike(bytes, cursor, limit),
        else => return Error.MalformedFrame,
    }
}

pub fn skipByteStringLike(bytes: []const u8, cursor: *usize, limit: usize) Error!void {
    const len_start = cursor.*;
    while (cursor.* < bytes.len and std.ascii.isDigit(bytes[cursor.*])) {
        cursor.* += 1;
    }
    if (cursor.* >= bytes.len) return Error.Incomplete;
    if (cursor.* == len_start) {
        return Error.MalformedFrame;
    }
    const marker = bytes[cursor.*];
    if (marker == '+' or marker == '-') {
        cursor.* += 1;
        return;
    }
    if (marker != ':' and marker != '"' and marker != '\'') {
        return Error.MalformedFrame;
    }
    try rejectNonCanonicalDigits(bytes, len_start, cursor.*);
    const len = parseDecimalDigits(usize, bytes[len_start..cursor.*]) orelse {
        return Error.MalformedFrame;
    };
    cursor.* += 1;
    if (len > limit -| cursor.*) return Error.FrameTooLarge;
    if (len > bytes.len - cursor.*) {
        return Error.Incomplete;
    }
    cursor.* += len;
}

pub fn readByte(bytes: []const u8, cursor: *usize, expected: u8) Error!void {
    if (cursor.* >= bytes.len) return Error.Incomplete;
    if (bytes[cursor.*] != expected) return Error.MalformedFrame;
    cursor.* += 1;
}

pub fn expectEnd(bytes: []const u8, cursor: usize) Error!void {
    if (cursor != bytes.len) {
        return Error.MalformedFrame;
    }
}

pub fn countDigits(bytes: []const u8) usize {
    var count: usize = 0;
    while (count < bytes.len and std.ascii.isDigit(bytes[count])) {
        count += 1;
    }
    return count;
}
