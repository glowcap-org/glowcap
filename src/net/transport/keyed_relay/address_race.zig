//! Shared resource and diagnostic policy for relay address races.
//!
//! Pollable POSIX and completion-backed acquisition keep different physical
//! drivers, but they admit the same bounded DNS set, keep the same number of
//! connect seats live, and report failed addresses in resolver order rather
//! than scheduler order.

const std = @import("std");
const foundation = @import("foundation");

pub const max_resolved_addresses = 32;
pub const max_parallel_attempts = 8;

pub fn FailureLedger(comptime Failure: type) type {
    return struct {
        const Self = @This();

        values: [max_resolved_addresses]?Failure =
            @as([max_resolved_addresses]?Failure, @splat(null)),

        pub fn note(self: *Self, address_index: usize, failure: Failure) void {
            std.debug.assert(address_index < self.values.len);
            foundation.latchFailure(&self.values[address_index], failure);
        }

        pub fn appendTo(self: *const Self, target: *?Failure, address_count: usize) void {
            std.debug.assert(address_count <= self.values.len);
            for (self.values[0..address_count]) |attempt| if (attempt) |failure| foundation.latchFailure(target, failure);
        }
    };
}
