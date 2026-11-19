//! Steady borrowed delivery costs one owned frame, plus a mention copy for
//! a capability-carrying delivery. Check each measured turn on both codecs.

const std = @import("std");
const glowcap = @import("glowcap");

const foundation = glowcap.foundation;
const codec = glowcap.ocapn.codec;
const engine = glowcap.ocapn.engine;
const model = glowcap.ocapn.model;
const session = glowcap.ocapn.session;

const CountingAllocator = @import("../support/alloc_metrics.zig").CountingAllocator;
const warm_turn = @import("../support/warm_turn.zig");

const Case = struct {
    syrup_frame: []const u8,
    argument: model.Argument,
    allocations: usize,
};

const cases = [_]Case{
    .{
        .syrup_frame = warm_turn.deliver_to_live_export,
        .argument = .{ .bytes = "hello" },
        .allocations = 1,
    },
    .{
        .syrup_frame = "<10'op:deliver<11'desc:export7+>[<18'desc:import-object99+>]ff>",
        .argument = .{ .reference = .{ .near = model.NearRef.object(99) } },
        .allocations = 2,
    },
};

test "steady-state borrowed deliveries spend their exact allocation budget on both codecs" {
    const allocator = std.testing.allocator;
    const profile = model.CaptpVersion.v1_0;
    for ([_]model.CodecId{ .syrup, .capnp }) |selected| {
        for (cases) |case| {
            var encoded: ?foundation.Frame = if (selected == .capnp)
                try codec.dispatch.encodeMessageForProfile(selected, allocator, profile, .{ .deliver = .{
                    .target = .{ .far = model.FarRef.object(7) },
                    .args = &.{case.argument},
                } })
            else
                null;
            defer if (encoded) |*frame| frame.deinit();
            const input: foundation.FrameView = if (encoded) |*frame| frame.view() else .{
                .bytes = case.syrup_frame,
                .shape = .byte,
            };

            var counter: CountingAllocator = .{ .backing = allocator };
            const measured = counter.allocator();
            var peer = engine.Peer.initWithSession(measured, session.Session.initWith(measured, .{ .codec = selected, .captp_version = profile }));
            defer peer.deinit();
            try peer.session_state.registerExport(.from(7));

            // Warm the queues and hold the capability in the case that carries one.
            for (0..8) |_| {
                try peer.recvBorrowed(input);
                try std.testing.expectEqual(@as(usize, 1), warm_turn.drainEvents(&peer));
            }
            for (0..16) |_| {
                counter.allocs = 0;
                try peer.recvBorrowed(input);
                try std.testing.expectEqual(@as(usize, 1), warm_turn.drainEvents(&peer));
                try std.testing.expectEqual(case.allocations, counter.allocs);
            }
        }
    }
}
