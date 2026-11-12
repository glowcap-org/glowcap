//! Issuing in-memory ids from a monotonic counter. An id is peeked before the
//! operation it names commits and spent only when that operation commits, so
//! a refusal consumes nothing. Zero is never issued, so it stays free as a
//! sentinel, and the counter's last value is never issued, so spending an id
//! cannot overflow. A caller maps exhaustion to its own refusal.

const std = @import("std");

pub const IdIssuer = struct {
    next: u64 = 1,

    /// The id the next commit spends, or null once the space is spent.
    pub fn peek(self: IdIssuer) ?u64 {
        return if (self.next == std.math.maxInt(u64)) null else self.next;
    }

    /// Spend `id`, which `peek` returned, after its operation committed.
    pub fn commit(self: *IdIssuer, id: u64) void {
        std.debug.assert(id == self.next);
        std.debug.assert(id != std.math.maxInt(u64));
        self.next += 1;
    }

    /// Whether `id` was spent by an earlier commit.
    pub fn issued(self: IdIssuer, id: u64) bool {
        return id != 0 and id < self.next;
    }

    /// Whether no id has been spent.
    pub fn untouched(self: IdIssuer) bool {
        return self.next == 1;
    }
};
