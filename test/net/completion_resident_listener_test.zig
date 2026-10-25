//! `net.completion_resident` listeners over the platform TCP backend: an
//! accept the kernel refused for descriptor quota reaches the claim as a
//! failure and does not re-arm, only an arrival's own failure re-arms, and a
//! listener stops accepting at the unclaimed bound and resumes on a claim.

const std = @import("std");
const builtin = @import("builtin");
const glowcap = @import("glowcap");
const harness = @import("completion_resident/harness.zig");

const net = glowcap.net;
const model = glowcap.ocapn.model;
const er = net.multiplexed_resident;

// Exercise readiness-driven sends on Linux even when io_uring is available.
comptime {
    _ = Tests(net.Backend);
    if (builtin.os.tag == .linux) _ = Tests(net.epoll_white_box.TestBackend);
}

fn Tests(comptime Backend: type) type {
    return struct {
        const H = harness.Harness(Backend);
        const Resident = H.Resident;
        const Events = H.Events;
        const open = H.open;
        const retire = H.retire;
        const connectPair = H.connectPair;
        const park = H.park;

        test "an accept refused for descriptor quota reaches the claim as a failure and does not re-arm" {
            // A loopback socket cannot make the kernel refuse an accept, so the
            // verdict is handed to the completion machine directly. The listener
            // must not re-arm against the same quota, and the runtime learns the
            // refusal through the claim verb, after any arrival accepted before it.
            var server = try open();
            defer retire(&server);
            var server_events: Events = .{ .resident = server.resident() };
            defer server_events.deinit();
            const server_ops = server.resident().vtable;

            const route = 11;
            const listener = switch (server_ops.listen.?.listen(&server, route, model.transport.tcp, .{ .designator = "127.0.0.1:0" })) {
                .admitted => |admitted| admitted.ready,
                .failed => |failure| return failure.cause,
            };
            const row: *Resident.Listener = @ptrCast(@alignCast(listener));
            try std.testing.expect(row.accept_armed);

            Resident.Completions.dispatch(&server, .{
                .user_data = net.completion_resident.userData(.accept, row.token),
                .result = -1,
                .failure = error.ProcessFdQuotaExceeded,
            });
            try std.testing.expect(!row.accept_armed);
            try std.testing.expect(try server_events.take(route, er.ev_accept));
            switch (server_ops.listen.?.finish_accept(&server, listener)) {
                .failed => |failure| {
                    try std.testing.expectEqual(error.AcceptRefused, failure.classification);
                    try std.testing.expectEqual(error.ProcessFdQuotaExceeded, failure.chain.cause);
                },
                .connection => return error.ClaimedAnAcceptTheKernelRefused,
            }
            // Handed over once: the next claim finds nothing.
            switch (server_ops.listen.?.finish_accept(&server, listener)) {
                .connection => |id| try std.testing.expectEqual(@as(?usize, null), id),
                .failed => return error.RefusalReportedTwice,
            }
            switch (server_ops.listen.?.stop_listen(&server, listener)) {
                .complete, .pending => {},
                .failed => |failure| return failure.cause,
            }
        }

        test "an accept refusal persists unless the arrival itself failed" {
            const persists = net.completion_resident.acceptRefusalPersists;
            // The arrival reset or refused a socket option: the next one is
            // unaffected, so the listener re-arms.
            try std.testing.expect(!persists(error.ConnectionAborted));
            try std.testing.expect(!persists(error.SocketConfigurationFailed));
            // Pressure, a dead listener, and anything unclassified would
            // complete again for as long as the arrival waits.
            try std.testing.expect(persists(error.ProcessFdQuotaExceeded));
            try std.testing.expect(persists(error.SystemFdQuotaExceeded));
            try std.testing.expect(persists(error.OutOfMemory));
            try std.testing.expect(persists(error.InvalidFileDescriptor));
            try std.testing.expect(persists(error.AcceptFailed));
        }

        test "a listener stops accepting at the unclaimed bound and resumes on a claim" {
            // A flood of connections costs the listener a bounded number of accepted
            // sockets the runtime has not claimed. Past the bound the resident leaves
            // arrivals in the kernel's listen backlog, and one claim re-arms it.
            const allocator = std.testing.allocator;
            var server = try open();
            defer retire(&server);
            var client = try open();
            defer retire(&client);
            var server_events: Events = .{ .resident = server.resident() };
            defer server_events.deinit();
            var client_events: Events = .{ .resident = client.resident() };
            defer client_events.deinit();
            const server_ops = server.resident().vtable;
            const client_ops = client.resident().vtable;

            const route = 9;
            const listener = switch (server_ops.listen.?.listen(&server, route, model.transport.tcp, .{ .designator = "127.0.0.1:0" })) {
                .admitted => |admitted| admitted.ready,
                .failed => |failure| return failure.cause,
            };
            const locator = switch (server_ops.listen.?.local_locator(&server, listener, model.transport.tcp, allocator)) {
                .locator => |locator| locator,
                .failed => |failure| return failure.cause,
            };
            defer model.freePeerLocator(allocator, locator);

            const bound = Resident.max_unclaimed_accepts;
            const arrivals = bound + 4;
            for (0..arrivals) |i| {
                try std.testing.expect(client_ops.dial.?.start_connect(&client, 100 + i, locator, .{}, .application) == .admitted);
            }
            for (0..arrivals) |i| {
                try client_events.await(100 + i, er.ev_connect);
                switch (client_ops.dial.?.finish_connect(&client, 100 + i)) {
                    .connected => {},
                    .failed => |failure| return failure.chain.cause,
                }
            }
            for (0..bound) |_| try server_events.await(route, er.ev_accept);

            // Every later arrival stays in the kernel: a few more parks accept
            // nothing more, and the listener is not armed.
            const row: *Resident.Listener = @ptrCast(@alignCast(listener));
            for (0..3) |_| _ = try park(server.resident(), 20);
            try std.testing.expect(!try server_events.take(route, er.ev_accept));
            try std.testing.expectEqual(bound, row.accepted.items.len);
            try std.testing.expect(!row.accept_armed);

            // One claim makes room and the next arrival is accepted.
            switch (server_ops.listen.?.finish_accept(&server, listener)) {
                .connection => |id| try std.testing.expect(id != null),
                .failed => |failure| return failure.chain.cause,
            }
            // A readiness backend may accept the next arrival inside finish_accept.
            try std.testing.expect(row.accept_armed or row.accepted.items.len == bound);
            try server_events.await(route, er.ev_accept);
            try std.testing.expectEqual(bound, row.accepted.items.len);
        }
    };
}
