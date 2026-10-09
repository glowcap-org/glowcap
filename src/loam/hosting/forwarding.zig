//! One forwarded call's completion custody, independent of admission scratch.
const std = @import("std");
const driver = @import("driver_core");

pub const Result = driver.Host.Call.Result;

pub const Forwarding = struct {
    call: ?*driver.Host.Call = null,

    /// One Call owns exact returned capabilities for local and wire delivery;
    /// neither completion borrows admission leases.
    /// The input arena survives rechecks; ordinary forwarding may use working.
    pub fn begin(self: *Forwarding, work: *const driver.Host.PendingWorkLease, target: driver.Capability, verb: []const u8, args: []const driver.Value, arena: std.mem.Allocator, reply_bytes: usize) !void {
        std.debug.assert(self.call == null);
        self.call = try work.call(arena, target, verb, args, reply_bytes);
    }

    pub fn poll(self: *Forwarding) Result {
        const call = self.call orelse return .pending;
        return call.result();
    }

    pub fn deinit(self: *Forwarding) void {
        if (self.call) |call| call.deinit();
        self.* = .{};
    }
};
