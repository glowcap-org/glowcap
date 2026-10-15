//! UTF-8 validation with a word-sized ASCII path for short wire text.

const std = @import("std");

/// Validate complete text. ASCII prefixes end on a character boundary, so
/// the first word containing a high byte can hand the remainder to the full
/// UTF-8 decoder without losing an incomplete or overlong sequence.
pub fn valid(bytes: []const u8) bool {
    const high_bits: u64 = 0x8080808080808080;
    var i: usize = 0;
    // Load 8 bytes as one number and test the top bit of each byte at once. A
    // byte with its top bit clear is plain ASCII and is always valid, so a
    // whole word of them needs no further look. The first byte with the bit
    // set hands the rest to the full UTF-8 decoder, which is sound because a
    // multi-byte character never starts in the middle of an ASCII run.
    while (i + 8 <= bytes.len) : (i += 8) {
        if (std.mem.readInt(u64, bytes[i..][0..8], .little) & high_bits != 0) {
            return std.unicode.utf8ValidateSlice(bytes[i..]);
        }
    }
    // Fewer than 8 bytes are left, and the rule is the same. The tail starts
    // on a character boundary, since everything before it was ASCII, so the
    // full decoder can take the whole tail once any byte in it has its top
    // bit set, and the tail is tested with no loop: four or more bytes as
    // its first four and its last four (overlapping, which covers each byte
    // at least once), fewer as three indexed bytes that cover one, two, or
    // three of them.
    const rest = bytes[i..];
    const tail_bits: u32 = switch (rest.len) {
        0 => 0,
        1, 2, 3 => rest[0] | rest[rest.len - 1] | rest[rest.len / 2],
        else => std.mem.readInt(u32, rest[0..4], .little) | std.mem.readInt(u32, rest[rest.len - 4 ..][0..4], .little),
    };
    if (tail_bits & 0x80808080 != 0) return std.unicode.utf8ValidateSlice(rest);
    return true;
}
