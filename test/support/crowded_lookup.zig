//! A test `std.Io` whose hostname lookup answers with a fixed number of
//! loopback addresses, for proving the address cap of a DNS-resolving carrier.
//!
//! The answer is the only difference from the base `std.Io.Threaded`. Every
//! other operation, including `async` and `concurrent`, is the base's. The
//! lookup follows the standard contract: it puts each address into the
//! caller's queue and closes the queue before it returns. A caller that
//! drains the queue while the lookup runs sees any count. A caller that drains
//! only after the lookup returns blocks the lookup at its queue capacity.

const std = @import("std");

const HostName = std.Io.net.HostName;
const LookupQueue = std.Io.Queue(HostName.LookupResult);

/// An `std.Io` over `base` (which must be a `std.Io.Threaded`) whose
/// `HostName.lookup` answers with `count` loopback addresses on the requested
/// port. Hold the value at its final address before calling `io`, and keep it
/// alive as long as anything uses the returned `std.Io`.
pub fn Lookup(comptime count: usize) type {
    return struct {
        const Self = @This();

        table: std.Io.VTable,
        userdata: ?*anyopaque,

        pub fn init(base: std.Io) Self {
            var table = base.vtable.*;
            table.netLookup = lookup;
            return .{ .table = table, .userdata = base.userdata };
        }

        pub fn io(self: *const Self) std.Io {
            return .{ .userdata = self.userdata, .vtable = &self.table };
        }

        fn lookup(
            userdata: ?*anyopaque,
            _: HostName,
            resolved: *LookupQueue,
            options: HostName.LookupOptions,
        ) HostName.LookupError!void {
            const threaded: *std.Io.Threaded = @ptrCast(@alignCast(userdata.?));
            const base = threaded.io();
            defer resolved.close(base);
            // Every answer is the same loopback address, which keeps the test
            // portable to hosts that route only 127.0.0.1.
            for (0..count) |_| {
                const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(options.port) };
                resolved.putOne(base, .{ .address = address }) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    // The caller never closes the queue before this returns.
                    error.Closed => unreachable,
                };
            }
        }
    };
}
