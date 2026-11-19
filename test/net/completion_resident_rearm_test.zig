//! `net.completion_resident` listeners over the platform TCP backend whose
//! re-arm the allocator refused: the listener owes it, a claim leaves it
//! unarmed, and only the resident's retry arms it again. Real arrivals fill the
//! reservation that runs out, every accept completion consumes or releases its
//! seat exactly once, and a record list that grows beside a held seat keeps it.

const std = @import("std");
const builtin = @import("builtin");
const glowcap = @import("glowcap");
const harness = @import("completion_resident/harness.zig");
const FailingOnce = @import("../support/failing_once.zig").FailingOnce;

const net = glowcap.net;
const model = glowcap.ocapn.model;
const er = net.multiplexed_resident;

// Exercise readiness-driven sends on Linux even when io_uring is available.
comptime {
    _ = Tests(net.Backend);
    if (builtin.target.os.tag == .linux) _ = Tests(net.epoll_white_box.TestBackend);
}

fn Tests(comptime Backend: type) type {
    return struct {
        const H = harness.Harness(Backend);
        const Resident = H.Resident;
        const Events = H.Events;
        const open = H.open;
        const retire = H.retire;
        const connectPair = H.connectPair;
        const fill = H.fill;
        const park = H.park;
        const listenRow = H.listenRow;
        const localLocator = H.localLocator;
        const arrival = H.arrival;
        const expectCapacityLaw = H.expectCapacityLaw;
        const refuse_first = H.refuse_first;

        /// The reservation a re-arm needs that the listener runs out of first.
        const Reserve = enum { accepted, records };

        /// Real arrivals fill the reservation named by `which` until the next
        /// arrival's re-arm no longer fits, then one more arrives while the
        /// allocator refuses growth: the arrival is claimable and the listener
        /// owes its re-arm. Every arrival is a completed kernel accept, so the
        /// later re-arm is not a duplicate submit, and no storage an armed
        /// accept holds is freed or shrunk. The accepted list is the limit
        /// when records are taken away each time, and the record list when
        /// each arrival is claimed instead.
        fn refuseRearm(server: *Resident, client: *Resident, row: *Resident.Listener, which: Reserve) !void {
            const allocator = server.allocator;
            const locator = try localLocator(server, row);
            defer model.freePeerLocator(allocator, locator);
            var request = 1000 + 100 * row.route;
            while (switch (which) {
                .accepted => row.accepted.items.len + 1 < row.accepted.capacity,
                .records => server.records.items.len + 1 < server.records.capacity,
            }) : (request += 1) {
                try arrival(server, client, row, locator, request);
                switch (which) {
                    // Readiness records are not this helper's subject.
                    .accepted => server.records.clearRetainingCapacity(),
                    .records => switch (server.resident().vtable.listen.?.finish_accept(server, row)) {
                        .connection => |id| try std.testing.expect(id != null),
                        .arrival_failed, .failed => |failure| return failure.chain.cause,
                    },
                }
            }
            var failing = std.testing.FailingAllocator.init(allocator, refuse_first);
            server.allocator = failing.allocator();
            defer server.allocator = allocator;
            try arrival(server, client, row, locator, request);
            try std.testing.expect(failing.has_induced_failure);
        }

        fn expectOwed(server: *Resident, row: *const Resident.Listener) !void {
            try std.testing.expect(row.rearm_owed);
            try std.testing.expect(!row.accept_armed);
            try std.testing.expect(row.accept_failure == null);
            try std.testing.expectEqual(@as(?anyerror, null), server.failure);
            try std.testing.expectEqual(@as(usize, 1), server.rearm_owed_count);
            try std.testing.expectEqual(@as(usize, 0), server.accept_seats);
            try std.testing.expect(row.accepted.items.len >= 1);
            try std.testing.expect(server.records.items.len >= 1);
            try std.testing.expect(server.resident().memoryRetry().?.owes());
        }

        /// An owed listener is claimable, an ordinary claim leaves it unarmed,
        /// and only the retry re-arms it.
        fn expectClaimThenRetry(server: *Resident, row: *Resident.Listener, route: usize) !void {
            const retry = server.resident().memoryRetry().?;
            // The retry meets the same refusal and keeps the debt.
            {
                const allocator = server.allocator;
                var failing = std.testing.FailingAllocator.init(allocator, refuse_first);
                server.allocator = failing.allocator();
                defer server.allocator = allocator;
                retry.retry();
                try std.testing.expect(failing.has_induced_failure);
            }
            try expectOwed(server, row);
            var events: Events = .{ .resident = server.resident() };
            defer events.deinit();
            try std.testing.expect(try events.take(route, er.ev_accept));
            switch (server.resident().vtable.listen.?.finish_accept(server, row)) {
                .connection => |id| try std.testing.expect(id != null),
                .arrival_failed, .failed => |failure| return failure.chain.cause,
            }
            // The ordinary claim neither re-armed the owed listener nor
            // released any seat.
            try std.testing.expect(!row.accept_armed);
            try std.testing.expect(row.rearm_owed);
            try std.testing.expectEqual(@as(usize, 0), server.accept_seats);
            retry.retry();
            try std.testing.expect(row.accept_armed);
            try std.testing.expect(!row.rearm_owed);
            try std.testing.expectEqual(@as(usize, 0), server.rearm_owed_count);
            try std.testing.expectEqual(@as(usize, 1), server.accept_seats);
            try std.testing.expect(!retry.owes());
            try expectCapacityLaw(server);
        }

        test "the paced retry runs while a received chunk is lent and leaves the lent bytes alone" {
            const allocator = std.testing.allocator;
            var server = try open();
            defer retire(&server);
            var client = try open();
            defer retire(&client);
            var server_events: Events = .{ .resident = server.resident() };
            defer server_events.deinit();
            var client_events: Events = .{ .resident = client.resident() };
            defer client_events.deinit();
            const pair = try connectPair(allocator, &server, &client, &server_events, &client_events);
            defer model.freePeerLocator(allocator, pair.locator);
            const row: *Resident.Listener = @ptrCast(@alignCast(pair.listener));
            const client_ops = client.resident().vtable;
            const lend = server.resident().vtable.borrowed_read.?;

            // One received chunk is lent and held across the whole retry.
            var chunk: [512]u8 = undefined;
            fill(&chunk, 3);
            try std.testing.expectEqual(@as(isize, chunk.len), client_ops.try_write(&client, pair.client_conn, &chunk));
            client_ops.flush_writes.?(&client, pair.client_conn);
            const deadline = net.clock.nowMonotonicMs() + H.wait_budget_ms;
            const lent = while (true) {
                client.resident().beforeWait(.park);
                server.resident().beforeWait(.park);
                switch (lend.lend(&server, pair.server_conn)) {
                    .bytes => |bytes| break bytes,
                    .would_block => {},
                    else => return error.LendFailed,
                }
                if (net.clock.nowMonotonicMs() >= deadline) return error.NothingLent;
                _ = try park(server.resident(), 10);
            };
            try std.testing.expectEqualSlices(u8, &chunk, lent);
            const lent_ptr = lent.ptr;
            // Records the lent receive queued are not this test's subject.
            server.records.clearRetainingCapacity();

            // A second arrival refused at the re-arm leaves the debt, then the
            // retry runs with the chunk still lent.
            try refuseRearm(&server, &client, row, .accepted);
            try expectOwed(&server, row);
            server.resident().memoryRetry().?.retry();
            try std.testing.expect(row.accept_armed);
            try std.testing.expect(!row.rearm_owed);
            try std.testing.expectEqual(lent_ptr, lent.ptr);
            try std.testing.expectEqualSlices(u8, &chunk, lent);
            lend.release(&server, pair.server_conn);
        }

        test "an accepted-slot refusal at the rearm leaves the listener owed" {
            var server = try open();
            defer retire(&server);
            var client = try open();
            defer retire(&client);
            const row = try listenRow(&server, 13);
            try refuseRearm(&server, &client, row, .accepted);
            try expectOwed(&server, row);
            try expectClaimThenRetry(&server, row, 13);
        }

        test "a record seat refusal at the rearm leaves the listener owed" {
            var server = try open();
            defer retire(&server);
            var client = try open();
            defer retire(&client);
            const row = try listenRow(&server, 14);
            try refuseRearm(&server, &client, row, .records);
            try expectOwed(&server, row);
            try expectClaimThenRetry(&server, row, 14);
        }

        test "every accept completion consumes or releases its seat exactly once" {
            var server = try open();
            defer retire(&server);
            var client = try open();
            defer retire(&client);
            const row = try listenRow(&server, 15);
            try std.testing.expectEqual(@as(usize, 1), server.accept_seats);
            try expectCapacityLaw(&server);

            // Success: a real arrival's seat backs its record, and the re-arm
            // reserves anew. The refusal branches are driven through a
            // provider in `external_listen_failure_test.zig`.
            const locator = try localLocator(&server, row);
            defer model.freePeerLocator(server.allocator, locator);
            try arrival(&server, &client, row, locator, 1500);
            try std.testing.expectEqual(@as(usize, 1), server.accept_seats);
            try std.testing.expectEqual(@as(usize, 1), row.accepted.items.len);
            try expectCapacityLaw(&server);

            // Stopping an armed listener returns its seat.
            const armed = try listenRow(&server, 24);
            try std.testing.expectEqual(@as(usize, 2), server.accept_seats);
            switch (server.resident().vtable.listen.?.stop_listen(&server, armed)) {
                .complete, .pending => {},
                .failed => |failure| return failure.chain.cause,
            }
            try std.testing.expectEqual(@as(usize, 1), server.accept_seats);
        }

        test "stopping an owed listener clears its debt and its retry" {
            var server = try open();
            defer retire(&server);
            var client = try open();
            defer retire(&client);
            const row = try listenRow(&server, 25);
            try refuseRearm(&server, &client, row, .records);
            try expectOwed(&server, row);
            switch (server.resident().vtable.listen.?.stop_listen(&server, row)) {
                .complete, .pending => {},
                .failed => |failure| return failure.chain.cause,
            }
            try std.testing.expectEqual(@as(usize, 0), server.rearm_owed_count);
            try std.testing.expectEqual(@as(usize, 0), server.accept_seats);
            try std.testing.expect(!server.resident().memoryRetry().?.owes());
            try std.testing.expectEqual(@as(?anyerror, null), server.failure);
        }

        test "a positive accept the kernel completed before the stop is retired once and takes no seat" {
            var server = try open();
            defer retire(&server);
            var client = try open();
            defer retire(&client);
            const row = try listenRow(&server, 26);
            const token = net.completion_resident.userData(.accept, row.token);
            const locator = try localLocator(&server, row);
            defer model.freePeerLocator(server.allocator, locator);
            try std.testing.expect(client.resident().vtable.dial.?.start_connect(&client, 2600, locator, .{}, .application) == .admitted);

            // Take the kernel's one accept completion straight from the
            // backend and withhold it: the resident still counts the accept
            // as armed and holds its seat.
            var out: [8]net.completion.Completion = undefined;
            const deadline = net.clock.nowMonotonicMs() + H.wait_budget_ms;
            const saved: net.completion.Completion = found: while (true) {
                client.resident().beforeWait(.park);
                const n = try server.backend.poll(&out, 10);
                for (out[0..n]) |comp| {
                    if (comp.user_data != token) return error.UnexpectedCompletion;
                    break :found comp;
                }
                if (net.clock.nowMonotonicMs() >= deadline) return error.ArrivalNeverCompleted;
            };
            try std.testing.expect(saved.result >= 0);
            const fd = saved.accepted_fd orelse saved.result;
            try std.testing.expect(row.accept_armed);
            try std.testing.expectEqual(@as(usize, 1), server.accept_seats);
            try std.testing.expectEqual(@as(usize, 0), row.accepted.items.len);

            // The stop returns the seat the withheld completion would have
            // consumed.
            switch (server.resident().vtable.listen.?.stop_listen(&server, row)) {
                .complete, .pending => {},
                .failed => |failure| return failure.chain.cause,
            }
            try std.testing.expectEqual(@as(usize, 0), server.accept_seats);
            const records = server.records.items.len;

            // The queued completion is delivered once, after the stop: it
            // finds no listener, retires its descriptor, and releases no
            // second seat.
            Resident.Completions.dispatch(&server, saved);
            try std.testing.expectEqual(@as(usize, 0), server.accept_seats);
            try std.testing.expectEqual(records, server.records.items.len);
            try std.testing.expectEqual(@as(?anyerror, null), server.failure);
            if (builtin.target.os.tag == .linux) {
                const rc = std.os.linux.fcntl(fd, std.os.linux.F.GETFD, 0);
                try std.testing.expectEqual(std.os.linux.E.BADF, std.os.linux.errno(rc));
            }
        }

        /// A real non-accept completion reaches a resident that also holds a
        /// listener's seat: outgoing dials to a second resident's listener
        /// leave `ev_connect` records queued until one more completion needs
        /// the record list to grow past its capacity less the seat. Healthy
        /// growth keeps the seat and every record, and refused growth latches.
        fn growRecordsBesideSeat(refuse: bool) !void {
            const allocator = std.testing.allocator;
            var server = try open();
            defer retire(&server);
            var target = try open();
            defer retire(&target);
            var events: Events = .{ .resident = server.resident() };
            defer events.deinit();
            const row = try listenRow(&server, 30);
            const far = try listenRow(&target, 31);
            const locator = try localLocator(&target, far);
            defer model.freePeerLocator(allocator, locator);
            const dial = server.resident().vtable.dial.?;
            try std.testing.expectEqual(@as(usize, 1), server.accept_seats);

            var requests: usize = 0;
            while (server.records.items.len + server.accept_seats < server.records.capacity or requests == 0) : (requests += 1) {
                const before = server.records.items.len;
                try std.testing.expect(dial.start_connect(&server, 3000 + requests, locator, .{}, .application) == .admitted);
                const deadline = net.clock.nowMonotonicMs() + H.wait_budget_ms;
                while (server.records.items.len == before) {
                    if (net.clock.nowMonotonicMs() >= deadline) return error.ConnectNeverCompleted;
                    target.resident().beforeWait(.park);
                    _ = try park(server.resident(), 10);
                }
            }
            // The queued records and the seat fill the list exactly.
            try std.testing.expectEqual(server.records.capacity, server.records.items.len + server.accept_seats);
            const capacity = server.records.capacity;
            // The dial verb reaps what the kernel already completed, so this
            // one's record is the one that crosses the capacity. When refused,
            // every allocation from here is, whichever the growth meets.
            const healthy = server.allocator;
            var failing = FailingOnce.init(healthy, std.math.maxInt(usize));
            failing.lasting = true;
            failing.fail_index = 0;
            if (refuse) server.allocator = failing.allocator();
            defer server.allocator = healthy;
            try std.testing.expect(dial.start_connect(&server, 3000 + requests, locator, .{}, .application) == .admitted);
            const deadline = net.clock.nowMonotonicMs() + H.wait_budget_ms;
            while (if (refuse) server.failure == null else server.records.items.len + server.accept_seats <= capacity) {
                if (net.clock.nowMonotonicMs() >= deadline) return error.ConnectNeverCompleted;
                target.resident().beforeWait(.park);
                _ = try park(server.resident(), 10);
            }
            server.allocator = healthy;
            // The listener's seat is intact either way.
            try std.testing.expect(row.accept_armed);
            try std.testing.expectEqual(@as(usize, 1), server.accept_seats);
            if (refuse) {
                try std.testing.expect(failing.induced);
                try std.testing.expectEqual(@as(?anyerror, error.OutOfMemory), server.failure);
                return;
            }
            try std.testing.expectEqual(@as(?anyerror, null), server.failure);
            try std.testing.expect(server.records.capacity > capacity);
            try expectCapacityLaw(&server);
            // Every record is readable, and every dial is claimed once.
            for (0..requests + 1) |request| {
                try events.await(3000 + request, er.ev_connect);
                switch (dial.finish_connect(&server, 3000 + request)) {
                    .connected => |id| try std.testing.expect(id != 0),
                    .failed => |failure| return failure.chain.cause,
                }
            }
        }

        test "record growth past capacity less the seat is healthy beside a held accept seat" {
            try growRecordsBesideSeat(false);
        }

        test "refused record growth beside a held accept seat latches the resident" {
            try growRecordsBesideSeat(true);
        }

        test "a refused connection adoption retires one arrival and leaves its listener armed" {
            var server = try open();
            defer retire(&server);
            var client = try open();
            defer retire(&client);
            const row = try listenRow(&server, 17);
            const locator = try localLocator(&server, row);
            defer model.freePeerLocator(server.allocator, locator);
            try arrival(&server, &client, row, locator, 1700);
            const allocator = server.allocator;
            var failing = std.testing.FailingAllocator.init(allocator, refuse_first);
            server.allocator = failing.allocator();
            const outcome = server.resident().vtable.listen.?.finish_accept(&server, row);
            server.allocator = allocator;
            try std.testing.expect(failing.has_induced_failure);
            switch (outcome) {
                .arrival_failed => |failure| try std.testing.expectEqual(error.OutOfMemory, failure.chain.cause),
                .connection, .failed => return error.AdoptRefusalLost,
            }
            // The listener was armed and stays so.
            try std.testing.expect(row.accept_armed);
            try std.testing.expect(!row.rearm_owed);
            try arrival(&server, &client, row, locator, 1701);
            switch (server.resident().vtable.listen.?.finish_accept(&server, row)) {
                .connection => |id| try std.testing.expect(id != null),
                .arrival_failed, .failed => |failure| return failure.chain.cause,
            }
        }

        test "a non-memory rearm failure stops the retries and surfaces through readiness" {
            if (comptime !@hasDecl(net.epoll_white_box, "TestBackend") or Backend != net.epoll_white_box.TestBackend) return error.SkipZigTest;
            var server = try open();
            defer retire(&server);
            var client = try open();
            defer retire(&client);
            const first = try listenRow(&server, 21);
            const second = try listenRow(&server, 22);
            try refuseRearm(&server, &client, first, .accepted);
            // The first arrival's record is the sibling's cue to wait for its own.
            server.records.clearRetainingCapacity();
            try refuseRearm(&server, &client, second, .accepted);
            try std.testing.expectEqual(@as(usize, 2), server.rearm_owed_count);
            const retry = server.resident().memoryRetry().?;
            try std.testing.expect(!server.resident().readyPending() or server.records.items.len != 0);
            net.epoll_white_box.failNextControl(&server.backend, .INVAL);
            retry.retry();
            // The first retried listener latched the failure and cleared its
            // flag. The sibling stays owed and untouched.
            try std.testing.expectEqual(@as(?anyerror, error.EpollControlFailed), server.failure);
            try std.testing.expectEqual(@as(usize, 1), server.rearm_owed_count);
            try std.testing.expect(!first.accept_armed and !second.accept_armed);
            try std.testing.expect(!retry.owes());
            try std.testing.expect(server.resident().readyPending());
            // A further retry does nothing, and no new I/O is needed to surface it.
            retry.retry();
            try std.testing.expectEqual(@as(usize, 1), server.rearm_owed_count);
            var out: [4]er.ReadyEvent = undefined;
            try std.testing.expectError(error.ProviderContract, server.resident().drainReady(&out));
        }
    };
}
