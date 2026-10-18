//! Allocation-failure scenarios for vow completion and fetch admission.

const std = @import("std");
const glowcap = @import("glowcap");
const test_host = @import("../../../support/core_host.zig");

const model = glowcap.ocapn.model;
const driver = glowcap.driver;
const engine = glowcap.ocapn.engine;
const Host = driver.core.Host;

const harness = @import("../harness.zig");
const frame_cap = harness.frame_cap;
const ParkedDial = harness.ParkedDial;
const shuttleAll = harness.shuttleAll;
const openPair = harness.openPair;
const openWidgetPair = @import("widget_pair.zig").open;

test "core host: a settle under OOM never strands a vow and never trips the reserved completion queue" {
    // Setup runs unarmed. The failing allocator then covers the complete reply
    // window, and every vow must be queued or remain live after the failure.
    var offset: usize = 0;
    while (true) : (offset += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const allocator = failing.allocator();
        var saw_oom = false;
        {
            var client = test_host.init(allocator, @as([32]u8, @splat(0x9a)), Host.Options.withFrameCap(frame_cap));
            defer client.deinit();
            var server = test_host.init(allocator, @as([32]u8, @splat(0x9b)), Host.Options.withFrameCap(frame_cap));
            defer server.deinit();
            var dials: std.ArrayList(ParkedDial) = .empty;
            defer dials.deinit(std.testing.allocator);
            const opened = try openWidgetPair(std.testing.allocator, &client, &server, &dials);

            const burst = 4;
            var vows: [burst]u64 = undefined;
            for (&vows) |*slot| slot.* = try client.send(opened.pair.a, opened.widget, .{ .verb = "poke", .args = &.{} });

            failing.fail_index = failing.alloc_index + offset;
            var failed_run = false;
            _ = shuttleAll(&.{opened.pair}) catch {
                failed_run = true;
            };
            if (!failed_run) _ = shuttleAll(&.{opened.pair}) catch {
                failed_run = true;
            };
            if (failed_run) try std.testing.expect(failing.has_induced_failure);
            saw_oom = failing.has_induced_failure;

            failing.fail_index = std.math.maxInt(usize);
            var seen: [burst]bool = @splat(false);
            while (try client.nextAction()) |action| {
                switch (action) {
                    .settled => |s| for (vows, 0..) |id, i| {
                        if (id == s.vow_id) seen[i] = true;
                    },
                    .failed => |f| for (vows, 0..) |id, i| {
                        if (id == f.vow_id) seen[i] = true;
                    },
                    else => {},
                }
            }
            for (vows, seen) |id, hit| {
                if (!hit) try std.testing.expect(client.vows.contains(id));
            }
        }
        if (!saw_oom) break;
        try std.testing.expect(offset < 512);
    }
}

test "core host: fetch allocation failures are pre-commit and a committed vow id is never lost" {
    var offset: usize = 0;
    var saw_precommit_oom = false;
    while (true) : (offset += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const allocator = failing.allocator();
        var client = test_host.init(allocator, @as([32]u8, @splat(0xa8)), Host.Options.withFrameCap(frame_cap));
        defer client.deinit();
        var server = test_host.init(std.testing.allocator, @as([32]u8, @splat(0xa9)), Host.Options.withFrameCap(frame_cap));
        defer server.deinit();
        var dials: std.ArrayList(ParkedDial) = .empty;
        defer dials.deinit(std.testing.allocator);
        const pair = try openPair(std.testing.allocator, &client, &server, "127.0.0.1:7106", &dials);

        try std.testing.expectEqual(@as(usize, 0), pair.a.served.queuedOutboundBytes());
        const held_bootstrap_before = pair.a.served.port.peer.session_state.holdsImport(.from(engine.bootstrap_position));
        failing.fail_index = failing.alloc_index + offset;

        const result = client.fetch(pair.a, "allocation-transaction");
        if (result) |vow_id| {
            try std.testing.expect(client.vows.contains(vow_id));
            failing.fail_index = std.math.maxInt(usize);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(failing.has_induced_failure);
            saw_precommit_oom = true;
            try std.testing.expectEqual(@as(usize, 0), pair.a.served.queuedOutboundBytes());
            try std.testing.expectEqual(@as(usize, 0), client.vows.count());
            try std.testing.expectEqual(
                held_bootstrap_before,
                pair.a.served.port.peer.session_state.holdsImport(.from(engine.bootstrap_position)),
            );
        }

        failing.fail_index = std.math.maxInt(usize);
        try std.testing.expect(offset < 64);
    }
    try std.testing.expect(saw_precommit_oom);
}
