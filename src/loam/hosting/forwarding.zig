//! One forwarded call's completion custody, independent of admission scratch.
const std = @import("std");
const driver = @import("driver_core");

pub const Result = driver.Host.Call.Result;

pub const Forwarding = struct {
    call: ?*driver.Host.Call = null,

    /// One Call owns exact returned capabilities for local and wire delivery.
    /// Neither completion borrows admission leases.
    /// The input arena survives rechecks. Ordinary forwarding may use working.
    /// `via` is the admitting turn's session, so a local target still learns
    /// who delivered the operation it is completing.
    pub fn begin(self: *Forwarding, work: *const driver.Host.PendingWorkLease, target: driver.Capability, verb: []const u8, args: []const driver.Value, arena: std.mem.Allocator, reply_bytes: usize, via: ?@FieldType(driver.HostSession, "peer_handle")) !void {
        std.debug.assert(self.call == null);
        self.call = try work.call(arena, target, verb, args, reply_bytes, via);
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
