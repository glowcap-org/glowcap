//! A relay reactor that cannot run reports why: its terminal failure carries
//! the exact cause into the runtime's release outcome.

const std = @import("std");
const glowcap = @import("glowcap");
const c = @import("c_abi_shared");
const relay = @import("c_abi_net_transport_relay");
const harness = @import("harness.zig");

/// Refuses every allocation off the thread that built it, so the reactor
/// thread's first poll-set reservation fails while construction succeeds.
const ReactorStarved = struct {
    child: std.mem.Allocator,
    owner: std.Thread.Id,
    refused: std.atomic.Value(usize) = .init(0),

    fn allocator(self: *ReactorStarved) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn of(ctx: *anyopaque) *ReactorStarved {
        return @ptrCast(@alignCast(ctx));
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self = of(ctx);
        if (std.Thread.getCurrentId() != self.owner) {
            _ = self.refused.fetchAdd(1, .acq_rel);
            return null;
        }
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self = of(ctx);
        if (std.Thread.getCurrentId() != self.owner) return false;
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self = of(ctx);
        if (std.Thread.getCurrentId() != self.owner) return null;
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        of(ctx).child.rawFree(memory, alignment, ret_addr);
    }
};

test "a relay reactor that cannot reserve its poll set releases with the allocation failure" {
    var starved: ReactorStarved = .{ .child = std.testing.allocator, .owner = std.Thread.getCurrentId() };
    const config = harness.copiedTrustConfig("ws://127.0.0.1:1/relay");
    var runtime: ?*relay.GlowcapRelayRuntime = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, relay.white_box.runtimeNewWith(starved.allocator(), &config, &runtime));

    // A hang bound on the reactor thread's first loop turn, not a duration.
    const deadline = glowcap.net.clock.nowMonotonicMs() + 10_000;
    while (starved.refused.load(.acquire) == 0) {
        if (glowcap.net.clock.nowMonotonicMs() >= deadline) return error.ReactorNeverAllocated;
        std.atomic.spinLoopHint();
    }

    var message: [256]u8 = undefined;
    var message_len: usize = 0;
    const released = relay.glowcap_relay_runtime_release(runtime, &message, message.len, &message_len);
    // The runtime is gone either way. The code is coarse, so the message names the cause.
    const result = c.ReleaseResult.fromRaw(released);
    try std.testing.expectEqual(.consumed, result.ownership);
    try std.testing.expectEqual(c.GLOWCAP_ERR_INTERNAL, result.code());
    const text = message[0..@min(message_len, message.len)];
    if (std.mem.find(u8, text, "OutOfMemory") == null) {
        std.debug.print("release reported: {s}\n", .{text});
        return error.TestUnexpectedResult;
    }
}
