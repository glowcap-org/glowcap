//! Checked Syrup leaf readers for untrusted byte slices.
//!
//! These routines mutate only a caller-owned cursor and borrow their results
//! from the supplied bytes. Length and collection caps are owned here so every
//! higher Syrup projection makes the same early decision.

const std = @import("std");

const model = @import("model");
const limits = @import("codec_limits");
const shared = @import("../shared.zig");

const Error = shared.Error;

/// Syrup's public name for the shared codec decode recursion bound.
pub const max_decode_nesting: usize = limits.max_decode_nesting;

/// Decode-time width bound for a single `list` / `set` / `struct` collection,
/// the width sibling of `max_decode_nesting`. Collection width is
/// untrusted, and every later walk over a collection, the lazy
/// view's `len`/`at`, session validation, owned materialization, is linear in
/// the element count, so width needs an explicit bound rather than being an
/// emergent property of whatever byte cap a deployment configures. An
/// over-wide collection fails loud as `MalformedFrame` during the slice walk,
/// before any of those walks run. The bound sits just above what the *default*
/// frame cap can even carry (one-byte elements under the 1 MiB
/// `max_frame_bytes`), so under default limits the envelope's cap refuses an
/// over-wide frame before it is buffered (ADR-0110). This cap binds the
/// whole-frame entry points and any deployment that raises the byte cap.
/// Ordinary CapTP messages carry a handful of arguments, six orders of
/// magnitude below it.
pub const max_collection_elements: usize = 1 << 20;

/// The two halves of a decoded `sig-val` record, borrowed from the frame.
pub const SignatureView = struct {
    r: []const u8,
    s: []const u8,
};

/// Read one length-prefixed Syrup leaf, `<len><marker><payload>`, at
/// `cursor`, advancing past it and returning the borrowed payload. The three
/// leaf kinds share this one reader and differ only in their `marker` byte:
/// `:` for byte-strings, `"` for strings, `'` for symbols. The length digits
/// are canonical-checked and parsed with overflow rejection, and the body is
/// bound-checked without wrappable arithmetic, so an untrusted length fails
/// closed (`Incomplete` / `MalformedFrame`) rather than
/// reading out of bounds.
fn readLengthPrefixed(bytes: []const u8, cursor: *usize, comptime marker: u8) Error![]const u8 {
    return readLengthPrefixedScanned(bytes, cursor, scanDecimal(bytes[cursor.*..]), marker);
}

/// The leaf reader after its width was scanned: a caller that read the
/// digits to find the marker and chose its reader by that marker hands the
/// run in, so the width is read once. The checks are the same as a fresh
/// read's.
fn readLengthPrefixedScanned(bytes: []const u8, cursor: *usize, run: DigitRun, comptime marker: u8) Error![]const u8 {
    const len_start = cursor.*;
    const marker_index = len_start + run.len;
    if (marker_index >= bytes.len) return Error.Incomplete;
    if (run.len == 0 or bytes[marker_index] != marker) {
        return Error.MalformedFrame;
    }
    try rejectNonCanonicalDigits(bytes, len_start, marker_index);
    const len = run.lengthValue() orelse return Error.MalformedFrame;

    const body_start = marker_index + 1;
    if (len > bytes.len - body_start) {
        return Error.Incomplete;
    }
    const body_end = body_start + len;
    cursor.* = body_end;
    return bytes[body_start..body_end];
}

pub fn readString(bytes: []const u8, cursor: *usize) Error![]const u8 {
    return readLeafScanned(bytes, cursor, scanDecimal(bytes[cursor.*..]), '"');
}

/// Read one length-prefixed leaf whose width `run` the caller scanned and
/// whose marker it saw: bytes as they are, a string or a symbol checked as
/// UTF-8 here, once, where it enters. The scanned form of `readBytes`,
/// `readString`, and `readSymbol`, for a reader that chose
/// among the three by the marker byte past the digits.
pub fn readLeafScanned(bytes: []const u8, cursor: *usize, run: DigitRun, comptime marker: u8) Error![]const u8 {
    const payload = try readLengthPrefixedScanned(bytes, cursor, run, marker);
    const valid = switch (marker) {
        ':' => true,
        '"' => shared.textValid(payload),
        '\'' => symbolBytesValid(payload),
        else => @compileError("not a Syrup leaf marker"),
    };
    if (!valid) return Error.MalformedFrame;
    return payload;
}

/// Match the one canonical form of a label the decoder knows, its width, a
/// quote, and its bytes, at `cursor`, advancing past it on a match. Syrup
/// spells a given label one way (the width carries no leading zero), so an
/// exact comparison against that form admits exactly the labels the general
/// reader returns as equal, with no digit scan. A label that would end past
/// the bytes does not match. A mismatch
/// reads nothing: the caller hands the bytes to `readLabel` for the
/// verdict, incomplete, malformed, or a label it does not know.
pub fn readKnownLabel(bytes: []const u8, cursor: *usize, comptime label: []const u8) bool {
    const spelled = comptime std.fmt.comptimePrint("{d}'{s}", .{ label.len, label });
    const end = cursor.* + spelled.len;
    if (!std.mem.startsWith(u8, bytes[cursor.*..], spelled)) return false;
    cursor.* = end;
    return true;
}

/// Read a symbol the caller carries onward as data, such as a method name or
/// a keyword. The bytes are checked as UTF-8 here, once, where they enter.
pub fn readSymbol(bytes: []const u8, cursor: *usize) Error![]const u8 {
    return readLeafScanned(bytes, cursor, scanDecimal(bytes[cursor.*..]), '\'');
}

/// Read a record label the caller matches against known spellings. A label
/// equal to one is that spelling's bytes, and a label equal to none is refused
/// by the caller, so the UTF-8 check `readSymbol` runs is skipped. A
/// caller that keeps an unmatched label as data passes it through
/// `symbolBytesValid` first, as the foreign-record arm of the argument reader
/// does.
pub fn readLabel(bytes: []const u8, cursor: *usize) Error![]const u8 {
    return readLengthPrefixed(bytes, cursor, '\'');
}

/// The one check a symbol's bytes pass before they are data.
pub fn symbolBytesValid(symbol: []const u8) bool {
    return shared.textValid(symbol);
}

/// Read a `[ … ]` list of positive ints, returning the borrowed body slice
/// between the brackets and advancing `cursor` past the closing `]`. Width is
/// bounded by `max_collection_elements`, like its sibling collection readers.
/// One delimited sequence body and how many elements the slicing walk
/// counted. The count rides into the lazy view's context word so `len()` is a
/// read, not a second walk of the subtree. The walk has to count anyway to
/// hold `max_collection_elements`.
pub const Sliced = struct {
    body: []const u8,
    elements: u64,
};

pub fn readPositionList(bytes: []const u8, cursor: *usize) Error!Sliced {
    try readByte(bytes, cursor, '[');
    const body_start = cursor.*;
    var elements: usize = 0;
    while (cursor.* < bytes.len and bytes[cursor.*] != ']') {
        elements += 1;
        if (elements > max_collection_elements) return Error.MalformedFrame;
        _ = try readPositiveInt(bytes, cursor);
    }
    if (cursor.* >= bytes.len) {
        return Error.Incomplete;
    }

    const body = bytes[body_start..cursor.*];
    cursor.* += 1;
    return .{ .body = body, .elements = elements };
}

pub fn readPeerKeyQ(bytes: []const u8, cursor: *usize) Error![]const u8 {
    // `readBalanced` consumes against the live buffer, so a truncated list is a
    // genuine `Incomplete` (read more). `list` is then a *complete* slice, so a
    // short read while re-parsing it is malformed, not stream-incomplete.
    const list = try readBalanced(bytes, cursor, '[', ']');
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
    const symbol = try readLabel(bytes, cursor);
    if (!std.mem.eql(u8, symbol, expected)) return Error.MalformedFrame;
}

pub fn readSignatureView(bytes: []const u8, cursor: *usize) Error!SignatureView {
    // See `readPeerKeyQ`: `list` is complete, so a short re-parse is malformed.
    const list = try readBalanced(bytes, cursor, '[', ']');
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

/// The leading ASCII digit run of a byte region and its value, read in one
/// pass. `value` is null when the run does not fit `u64`, the verdict
/// `std.fmt.parseInt` gave on these paths. Every length prefix and integer
/// leaf goes through `scanDecimal`, so the digits are read once, counted in
/// a local, and the caller stores its cursor once.
pub const DigitRun = struct {
    len: usize,
    value: ?u64,

    /// The run as a byte length, which on a 32-bit target is narrower than
    /// the `u64` the run was accumulated in.
    pub fn lengthValue(self: DigitRun) ?usize {
        return std.math.cast(usize, self.value orelse return null);
    }
};

pub fn scanDecimal(bytes: []const u8) DigitRun {
    // Every run of fewer digits than `maxInt(u64)` has fits, so those digits
    // accumulate with no check. The twentieth and later take the checked
    // loop, and a run past the range still counts to its end so the caller
    // finds the terminator and refuses with the value.
    const unchecked_digits = comptime std.fmt.comptimePrint("{d}", .{std.math.maxInt(u64)}).len - 1;
    var count: usize = 0;
    var value: u64 = 0;
    // One bound for the unchecked loop, so each digit costs one compare.
    const unchecked_end = @min(bytes.len, unchecked_digits);
    // Four complete digits fold into two pairs, then one decimal chunk.
    // A failed word test leaves every byte for the scalar tail to classify.
    while (unchecked_end - count >= 4) {
        const word = std.mem.readInt(u32, bytes[count..][0..4], .little);
        if (((word -% 0x30303030) | (word +% 0x46464646)) & 0x80808080 != 0) break;
        const digits = word - 0x30303030;
        const pairs = (digits & 0x00ff00ff) * 10 + ((digits >> 8) & 0x00ff00ff);
        const chunk = (pairs & 0xffff) * 100 + (pairs >> 16);
        value = value * 10000 + chunk;
        count += 4;
    }
    while (count < unchecked_end) : (count += 1) {
        // Subtracting '0' with wraparound turns "is this a digit" into one
        // compare. A digit byte becomes 0 through 9. A byte below '0' wraps
        // around to a huge number and a byte above '9' lands past 9, so
        // `digit > 9` catches every non-digit. This works only because the
        // subtraction wraps instead of trapping. Nineteen digits never
        // overflow a u64, so this loop skips the overflow check.
        const digit = bytes[count] -% '0';
        if (digit > 9) return .{ .len = count, .value = value };
        value = value * 10 + digit;
    }
    // From the twentieth digit on, the value can pass the u64 range, so each
    // step is checked. Once it overflows the result stays null, but the loop
    // still counts digits so the caller finds the end of the run.
    var checked: ?u64 = value;
    while (count < bytes.len) : (count += 1) {
        const digit = bytes[count] -% '0';
        if (digit > 9) break;
        if (checked) |v| checked = std.math.mul(u64, v, 10) catch null;
        if (checked) |v| checked = std.math.add(u64, v, digit) catch null;
    }
    return .{ .len = count, .value = checked };
}

/// Scan the leading decimal run at `cursor`, advancing past it, and return the
/// borrowed digit slice with its value. `Incomplete` when the run reaches the
/// end with no terminator byte to inspect, `MalformedFrame` when it is empty
/// or non-canonical (a leading zero). The cursor is left on the terminator
/// byte the caller reads (a `+`/`-` sign, or the `+` a positive integer
/// requires), which is guaranteed in-bounds by the `Incomplete` check. The
/// shared prologue of every Syrup integer reader.
const ScannedDigits = struct { digits: []const u8, value: ?u64 };

fn scanDigits(bytes: []const u8, cursor: *usize) Error!ScannedDigits {
    return finishDigits(bytes, cursor, scanDecimal(bytes[cursor.*..]));
}

/// The prologue's checks after the run was scanned, for a caller that scanned
/// the digits to find the sign.
fn finishDigits(bytes: []const u8, cursor: *usize, run: DigitRun) Error!ScannedDigits {
    const start = cursor.*;
    const end = start + run.len;
    if (end >= bytes.len) return Error.Incomplete;
    if (run.len == 0) return Error.MalformedFrame;
    try rejectNonCanonicalDigits(bytes, start, end);
    cursor.* = end;
    return .{ .digits = bytes[start..end], .value = run.value };
}

/// Apply the sign terminator at `cursor` to a scanned decimal run's
/// `magnitude`, consuming the terminator. Returns the signed `i64` value when the magnitude
/// fits the i64 range, including the `minInt` boundary the
/// `9223372036854775808-` encoding names, `null` when the magnitude overflows
/// i64, so the caller decides (reject it, or take the arbitrary-precision arm),
/// and `MalformedFrame` for `0-` (the spec has exactly one zero, `0+`) and any
/// non-sign terminator. The shared sign/magnitude tail of `readInteger` and
/// `readIntegerValue`.
fn signedI64FromDigits(magnitude: ?u64, bytes: []const u8, cursor: *usize) Error!?i64 {
    // The magnitude is a u64, not an i64: `writeInteger` emits
    // `minInt(i64)` as the unsigned magnitude 2^63 (`9223372036854775808`), which
    // does not fit i64, so parsing it as i64 would reject a frame this codec
    // itself produced. The sign is applied below, handling the minInt boundary so
    // the full i64 range round-trips and matches the Cap'n Proto codec.
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
    const scanned = try scanDigits(bytes, cursor);
    if (bytes[cursor.*] != '+') return Error.MalformedFrame;
    const value = scanned.value orelse return Error.MalformedFrame;
    cursor.* += 1;
    return value;
}

/// Read an arbitrary-precision OCapN Integer. The split is canonical: a value
/// representable as `i64` never takes the decimal-magnitude arm.
pub fn readIntegerValue(bytes: []const u8, cursor: *usize) Error!model.Integer {
    return readIntegerValueScanned(bytes, cursor, scanDecimal(bytes[cursor.*..]));
}

/// `readIntegerValue` after its caller scanned the magnitude's digits.
pub fn readIntegerValueScanned(bytes: []const u8, cursor: *usize, run: DigitRun) Error!model.Integer {
    const scanned = try finishDigits(bytes, cursor, run);
    // Capture the sign before `signedI64FromDigits` consumes the terminator: an
    // overflow (null) takes the arbitrary-precision arm, whose sign is that
    // terminator. A non-sign terminator errors instead of returning null, so the
    // captured byte is `+` or `-` on every path that reads it.
    const sign_byte = bytes[cursor.*];
    if (try signedI64FromDigits(scanned.value, bytes, cursor)) |value| {
        return .{ .integer = value };
    }
    return .{ .big_integer = .{ .negative = sign_byte == '-', .digits = scanned.digits } };
}

/// Read an arbitrary-precision OCapN Integer as an argument view, after its
/// caller scanned the magnitude's digits to find the sign.
pub fn readIntegerArgumentScanned(bytes: []const u8, cursor: *usize, run: DigitRun) Error!model.view.Argument {
    return switch (try readIntegerValueScanned(bytes, cursor, run)) {
        .integer => |value| .{ .integer = value },
        .big_integer => |big| .{ .big_integer = big },
    };
}

pub fn readInteger(bytes: []const u8, cursor: *usize) Error!i64 {
    return readIntegerScanned(bytes, cursor, scanDecimal(bytes[cursor.*..]));
}

/// `readInteger` after its caller scanned the magnitude's digits.
pub fn readIntegerScanned(bytes: []const u8, cursor: *usize, run: DigitRun) Error!i64 {
    const scanned = try finishDigits(bytes, cursor, run);
    // Hint integers use the bounded HintValue arm; a magnitude past i64 is not
    // representable there and is therefore malformed.
    return (try signedI64FromDigits(scanned.value, bytes, cursor)) orelse Error.MalformedFrame;
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
/// untrusted length fails closed (`Incomplete` / `MalformedFrame`) rather than
/// reading out of bounds. Exposed so callers that need a raw byte-string at a
/// known offset reuse this reader instead of re-deriving the wire grammar.
pub fn readBytes(bytes: []const u8, cursor: *usize) Error![]const u8 {
    return readLengthPrefixed(bytes, cursor, ':');
}

pub fn readBalanced(bytes: []const u8, cursor: *usize, open: u8, close: u8) Error![]const u8 {
    const start = cursor.*;
    try readByte(bytes, cursor, open);
    var depth: usize = 1;
    while (cursor.* < bytes.len) {
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
            try skipByteStringLike(bytes, cursor);
        } else if (byte == ':' or byte == '"' or byte == '\'') {
            cursor.* -= 1;
            try skipByteStringLike(bytes, cursor);
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
    if (cursor.* >= bytes.len) return Error.Incomplete;
    switch (bytes[cursor.*]) {
        '<' => _ = try readBalanced(bytes, cursor, '<', '>'),
        '[' => _ = try readBalanced(bytes, cursor, '[', ']'),
        '{' => _ = try readBalanced(bytes, cursor, '{', '}'),
        't', 'f' => cursor.* += 1,
        // A `D`-tagged binary64: the marker plus 8 raw IEEE-754 payload bytes.
        'D' => {
            if (bytes.len - cursor.* < 9) return Error.Incomplete;
            cursor.* += 9;
        },
        '0'...'9' => try skipByteStringLike(bytes, cursor),
        else => return Error.MalformedFrame,
    }
}

pub fn skipByteStringLike(bytes: []const u8, cursor: *usize) Error!void {
    const len_start = cursor.*;
    const run = scanDecimal(bytes[len_start..]);
    cursor.* = len_start + run.len;
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
    const len = run.lengthValue() orelse return Error.MalformedFrame;
    cursor.* += 1;
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
