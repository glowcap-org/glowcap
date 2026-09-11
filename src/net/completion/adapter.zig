//! Vocabulary shared by completion adapters that wrap another backend.
//!
//! A wrapped adapter keeps a table of legs, one per synthetic handle, and
//! runs each leg over one inner connection. Two facts about a leg are the
//! same whatever the transport: which inner operations it currently has
//! submitted, and where its inner descriptor stands in its own close. This
//! leaf owns those two facts. The relay, sealing, and onion adapters compose
//! it; none restates it.

const std = @import("std");

/// Where a leg's inner descriptor stands in its own close.
///
/// `open` means no close has been submitted. `in_flight` means the inner
/// backend owns a close it has not completed. `failed` means that close
/// completed negatively, so the descriptor is still owned and the adapter
/// releases it directly once nothing is pending. `closed` means the
/// descriptor is gone.
pub const InnerClose = enum { open, in_flight, failed, closed };

/// Which inner operations one leg currently has submitted.
///
/// `Op` is the adapter's internal operation enum and `tracked` names the
/// members a leg arms at most once at a time. A close is not tracked here
/// because its progress carries more than one bit; `InnerClose` owns it. One
/// byte per tracked member keeps each adapter's leg at the footprint its
/// budget test pins.
pub fn PendingOps(comptime Op: type, comptime tracked: []const Op) type {
    return struct {
        const Self = @This();

        flags: [tracked.len]bool = @as([tracked.len]bool, @splat(false)),

        fn slot(op: Op) usize {
            inline for (tracked, 0..) |candidate, index| {
                if (op == candidate) return index;
            }
            unreachable;
        }

        pub fn get(self: Self, op: Op) bool {
            return self.flags[slot(op)];
        }

        pub fn arm(self: *Self, op: Op) void {
            std.debug.assert(!self.get(op));
            self.flags[slot(op)] = true;
        }

        pub fn retire(self: *Self, op: Op) void {
            std.debug.assert(self.get(op));
            self.flags[slot(op)] = false;
        }

        pub fn count(self: Self) usize {
            var armed: usize = 0;
            for (self.flags) |flag| armed += @intFromBool(flag);
            return armed;
        }
    };
}
