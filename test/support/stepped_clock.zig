//! A test `std.Io` whose clock moves only when it is read.
//!
//! Every `now` reading advances the clock by one fixed step, whatever clock
//! the caller names, and wall time never enters it. A runtime driven through
//! this `Io` measures its windows and deadlines in readings, so a test can
//! assert how long a wait lasted without racing the host's scheduler. Every
//! other operation, sockets and sleeps included, is the base `Io`'s, called
//! with the base's own userdata.

const std = @import("std");

/// The reading and step live at container level because the base's other
/// operations need the base's userdata, which leaves `now` no pointer of its
/// own. So one stepped clock is live per process, and `init` resets it. The
/// Zig test runner runs tests one at a time, which keeps that exact.
var reading_ns: std.atomic.Value(i64) = .init(0);
var step_ns: i64 = 0;

/// An `std.Io` over `base` whose `now` starts at `start_ns` and advances
/// `step` nanoseconds per reading. Hold the value at its final address before
/// calling `io`, and keep it alive as long as anything uses the returned
/// `std.Io`.
pub const SteppedClock = struct {
    table: std.Io.VTable,
    userdata: ?*anyopaque,

    pub fn init(base: std.Io, start_ns: i64, step: i64) SteppedClock {
        reading_ns.store(start_ns, .release);
        step_ns = step;
        var table = base.vtable.*;
        table.now = now;
        return .{ .table = table, .userdata = base.userdata };
    }

    pub fn io(self: *const SteppedClock) std.Io {
        return .{ .userdata = self.userdata, .vtable = &self.table };
    }

    /// The clock's value without advancing it, for a test reading how far a
    /// wait moved it.
    pub fn peekMs(_: *const SteppedClock) i64 {
        return @divFloor(reading_ns.load(.acquire), std.time.ns_per_ms);
    }

    fn now(_: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
        return .fromNanoseconds(reading_ns.fetchAdd(step_ns, .acq_rel) + step_ns);
    }
};
