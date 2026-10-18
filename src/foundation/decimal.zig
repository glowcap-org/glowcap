//! Decimal digits for a wire length or position, written in place.
//!
//! Every Syrup length prefix, every position, and the byte-stream prefix
//! around a frame is one unsigned decimal. A writer measures its width
//! without forming digits, reserves exactly that room, and fills it. Both
//! halves cost a fixed handful of instructions whatever the value.

const std = @import("std");

/// The widest decimal a `u64` takes.
pub const max_width: usize = width(std.math.maxInt(u64));

/// How many digits `value` takes in decimal. The count of binary digits in
/// use fixes the decimal width to within one (a scaled multiply stands in
/// for log10 of 2), and one compare against the power of ten settles it.
pub fn width(value: u64) usize {
    // Zero has one digit, like one, and the `| 1` folds it onto that case
    // without changing any other value's bit count.
    const bits: usize = 64 - @clz(value | 1);
    const guess = (bits * 1233) >> 12;
    return guess + @intFromBool(value | 1 >= powers_of_ten[guess]);
}

/// Ten to the zeroth through the nineteenth. A u64 takes at most twenty
/// digits, so the width guess above never exceeds nineteen.
const powers_of_ten: [20]u64 = blk: {
    var powers: [20]u64 = undefined;
    var power: u64 = 1;
    for (&powers) |*bound| {
        bound.* = power;
        power *|= 10;
    }
    break :blk powers;
};

/// Write `value` as exactly `digits.len` decimal digits, which is its width.
/// Two digits land per division, from a table of the hundred pairs, so a
/// number below one hundred costs no division and a 20-digit one costs nine.
pub inline fn fill(digits: []u8, value: u64) void {
    std.debug.assert(digits.len == width(value));
    var remaining = value;
    var end = digits.len;
    while (remaining >= 100) {
        const pair: usize = @intCast(remaining % 100);
        remaining /= 100;
        end -= 2;
        digits[end..][0..2].* = decimal_pairs[pair];
    }
    if (remaining >= 10) {
        digits[0..2].* = decimal_pairs[@as(usize, @intCast(remaining))];
    } else {
        digits[0] = @intCast(remaining + '0');
    }
}

/// The two ASCII digits of every value below one hundred.
const decimal_pairs: [100][2]u8 = blk: {
    var pairs: [100][2]u8 = undefined;
    for (&pairs, 0..) |*pair, n| pair.* = .{ '0' + n / 10, '0' + n % 10 };
    break :blk pairs;
};
