//! Failure observation and claim order at the completion resident, using a
//! scriptable platform so each submission and completion is independently driven.

const std = @import("std");
const glowcap = @import("glowcap");
const Platform = @import("../support/keyed_relay_admission.zig").AdmissionPlatform;
const net = glowcap.net;
const Resident = net.completion_resident.Resident(Platform, net.external_completion.PlatformRefused(Platform));

test "connection failure order keeps a refused receive before an independent failed send" {
    var resident = try Resident.init(std.testing.allocator, .{}, .{});
    defer {
        resident.closeAndDrain(2_000) catch unreachable;
        resident.deinit();
    }
    const ops = resident.resident();
    resident.backend.fail_recv = true;
    const id = try resident.adopt(100);
    ops.beforeWait(.park);
    var buf: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, -1), ops.tryRead(id, &buf));
    try std.testing.expectEqual(@as(isize, 5), ops.tryWrite(id, "later"));
    Resident.Completions.startSend(&resident, id, resident.conns.getPtr(id).?);
    const ud = resident.backend.pending_send.?.user_data;
    resident.backend.pending_send = .{ .user_data = ud, .result = -1, .failure = error.BrokenPipe };
    const result = ops.connCloseOutcome(id, .awaited);
    try std.testing.expect(result == .failed);
    try std.testing.expectEqual(error.SubmitFailed, result.failed.chain.cause);
    try std.testing.expectEqualStrings("BrokenPipe", result.failed.chain.secondaryName().?);
    try std.testing.expectEqual(@as(u16, 1), result.failed.chain.secondary_count);
    try std.testing.expectEqual(@as(usize, 1), resident.backend.send_submits);
    try std.testing.expect(ops.takeFailure(id) == null);
}

test "connection failure order closes after a refused receive, staging append and physical write" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var resident = try Resident.init(failing.allocator(), .{ .fail_recv = true }, .{});
    defer {
        resident.closeAndDrain(2_000) catch unreachable;
        resident.deinit();
    }
    const ops = resident.resident();
    const id = try resident.adopt(100);
    ops.beforeWait(.park);
    try std.testing.expectEqual(@as(isize, 4), ops.tryWrite(id, "send"));
    Resident.Completions.startSend(&resident, id, resident.conns.getPtr(id).?);
    failing.fail_index = failing.alloc_index;
    const refused = ops.tryWrite(id, "append");
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectEqual(@as(isize, -1), refused);
    var detail = glowcap.foundation.FailureChain.initNamed(error.BrokenPipe, "CarrierWrite");
    detail.note(error.CleanupFailed);
    resident.backend.terminal_report = .{ .chain = detail };
    const ud = resident.backend.pending_send.?.user_data;
    resident.backend.pending_send = .{ .user_data = ud, .result = -1, .failure = error.BrokenPipe, .failure_origin = .terminal_io };
    const result = ops.connCloseOutcome(id, .awaited);
    try std.testing.expect(result == .failed);
    try std.testing.expectEqual(error.SubmitFailed, result.failed.chain.cause);
    try std.testing.expectEqualStrings("OutOfMemory", result.failed.chain.secondaryName().?);
    try std.testing.expectEqual(@as(u16, 3), result.failed.chain.secondary_count);
    try std.testing.expectEqual(@as(usize, 1), resident.backend.reports_taken);
}

test "connection failure order counts a marked borrowed report also kept by the provider just once" {
    for ([_]bool{ false, true }) |earlier_staging| {
        for ([_]bool{ false, true }) |phase_only| try expectSharedCarrier(earlier_staging, phase_only);
    }
}

fn expectSharedCarrier(earlier_staging: bool, phase_only: bool) !void {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var resident = try Resident.init(failing.allocator(), .{}, .{});
    defer {
        resident.closeAndDrain(2_000) catch unreachable;
        resident.deinit();
    }
    const id = try resident.adopt(100);
    const ops = resident.resident();
    try std.testing.expectEqual(@as(isize, 5), ops.tryWrite(id, "first"));
    Resident.Completions.startSend(&resident, id, resident.conns.getPtr(id).?);
    if (earlier_staging) {
        failing.fail_index = failing.alloc_index;
        const refused = ops.tryWrite(id, "later");
        failing.fail_index = std.math.maxInt(usize);
        try std.testing.expectEqual(@as(isize, -1), refused);
    }
    var detail = glowcap.foundation.FailureChain.initNamed(error.BrokenPipe, "CarrierWrite");
    detail.note(error.CleanupFailed);
    const borrowed: net.carrier_failure.Failure = .{
        .chain = detail,
        .phase = .transmit,
        .detail = .{ .engine_code = -19, .verification_flags = 1 },
    };
    resident.backend.terminal_report = if (phase_only)
        .{ .chain = detail }
    else
        .{ .chain = detail, .phase = .transmit, .detail = .{ .peer_alert = 48, .verification_flags = 2 } };
    const ud = resident.backend.pending_send.?.user_data;
    resident.backend.pending_send = .{
        .user_data = ud,
        .result = -1,
        .failure_origin = .terminal_io,
        .borrowed = if (phase_only) .phaseOnly(.transmit) else .carrierFailure(&borrowed, 17),
    };
    resident.pump();
    try std.testing.expectEqual(@as(u32, if (phase_only) 0 else 17), resident.backend.last_recycled_token);
    const report = ops.takeFailure(id) orelse return error.FailureMissing;
    try std.testing.expectEqualStrings(if (earlier_staging) "OutOfMemory" else "CarrierWrite", report.chain.primaryName());
    try std.testing.expectEqualStrings(if (earlier_staging) "CarrierWrite" else "CleanupFailed", report.chain.secondaryName().?);
    try std.testing.expectEqual(@as(u16, if (earlier_staging) 2 else 1), report.chain.secondary_count);
    try std.testing.expectEqual(@as(?net.carrier_failure.Phase, if (earlier_staging) null else .transmit), report.phase);
    const expect_detail = !earlier_staging and !phase_only;
    try std.testing.expectEqual(@as(?i32, if (expect_detail) -19 else null), report.detail.engine_code);
    try std.testing.expectEqual(@as(?u8, if (expect_detail) 48 else null), report.detail.peer_alert);
    try std.testing.expectEqual(@as(u32, if (expect_detail) 3 else 0), report.detail.verification_flags);
    try std.testing.expectEqual(@as(usize, 1), resident.backend.reports_taken);
    try std.testing.expect(ops.takeFailure(id) == null);
}

test "connection failure order enriches a scalar read from the same latch on the write" {
    var resident = try Resident.init(std.testing.allocator, .{}, .{});
    defer {
        resident.closeAndDrain(2_000) catch unreachable;
        resident.deinit();
    }
    const id = try resident.adopt(100);
    const ops = resident.resident();
    ops.beforeWait(.park);
    const read_ud = resident.backend.armed_recv_ud.?;
    resident.backend.pending_recv = .{ .user_data = read_ud, .result = -1, .failure = error.WriteFailed, .failure_origin = .terminal_io };
    resident.pump();
    try std.testing.expectEqual(@as(isize, 5), ops.tryWrite(id, "first"));
    Resident.Completions.startSend(&resident, id, resident.conns.getPtr(id).?);
    var detail = glowcap.foundation.FailureChain.initNamed(error.BrokenPipe, "CarrierWrite");
    detail.note(error.CleanupFailed);
    const send_ud = resident.backend.pending_send.?.user_data;
    resident.backend.pending_send = .{
        .user_data = send_ud,
        .result = -1,
        .failure_origin = .terminal_io,
        .borrowed = .failure(&detail, 17),
    };
    resident.pump();
    const report = ops.takeFailure(id) orelse return error.FailureMissing;
    try std.testing.expectEqualStrings("CarrierWrite", report.chain.primaryName());
    try std.testing.expectEqualStrings("CleanupFailed", report.chain.secondaryName().?);
    try std.testing.expectEqual(@as(u16, 1), report.chain.secondary_count);
}

test "connection failure order keeps a retained terminal report at the position of its write" {
    try retainedWrite(false, false);
    try retainedWrite(true, false);
}

test "connection failure order claims a retained terminal write before dispatch without staging refusal" {
    try retainedWrite(false, true);
}

test "connection failure order claims a retained terminal write before dispatch behind staging refusal" {
    try retainedWrite(true, true);
}

fn retainedWrite(earlier_staging: bool, before_dispatch: bool) !void {
    const External = net.external_completion.CompletionBackend(Platform);
    const Wrapped = net.completion_resident.Resident(External, net.external_completion.PlatformRefused(External));
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const backend = try External.initWithPlatform(std.testing.allocator, .{ .providers = &.{} }, .{}, 16, 256);
    var resident = try Wrapped.init(failing.allocator(), backend, .{});
    defer {
        resident.closeAndDrain(2_000) catch unreachable;
        resident.deinit();
    }
    const id = try resident.adopt(100);
    const ops = resident.resident();
    try std.testing.expectEqual(@as(isize, 5), ops.tryWrite(id, "first"));
    Wrapped.Completions.startSend(&resident, id, resident.conns.getPtr(id).?);
    if (earlier_staging) {
        failing.fail_index = failing.alloc_index;
        const refused = ops.tryWrite(id, "later");
        failing.fail_index = std.math.maxInt(usize);
        try std.testing.expectEqual(@as(isize, -1), refused);
    }
    var detail = glowcap.foundation.FailureChain.initNamed(error.BrokenPipe, "CarrierWrite");
    detail.note(error.CleanupFailed);
    resident.backend.platform.terminal_report = .{ .chain = detail };
    const ud = resident.backend.platform.pending_send.?.user_data;
    resident.backend.platform.pending_send = .{ .user_data = ud, .result = -1, .failure = error.WriteFailed, .failure_origin = .terminal_io };
    if (!before_dispatch) resident.pump();
    const report = ops.takeFailure(id) orelse return error.FailureMissing;
    try std.testing.expectEqualStrings(if (earlier_staging) "OutOfMemory" else "CarrierWrite", report.chain.primaryName());
    try std.testing.expectEqualStrings(if (earlier_staging) "CarrierWrite" else "CleanupFailed", report.chain.secondaryName().?);
    try std.testing.expectEqual(@as(u16, if (earlier_staging) 2 else 1), report.chain.secondary_count);
    switch (ops.connCloseOutcome(id, .awaited)) {
        .complete => {},
        .failed => |duplicate| return duplicate.chain.cause,
        .pending => return error.UnexpectedPendingClose,
    }
    try std.testing.expect(ops.takeFailure(id) == null);
    try std.testing.expectEqual(@as(usize, 1), resident.backend.platform.send_submits);
    try std.testing.expectEqual(@as(usize, 1), resident.backend.platform.reports_taken);
}

test "draining resident returns an ignored read borrow on success, independent failure or abort" {
    const Outcome = enum { success, independent, abort, drain };
    for ([_]Outcome{ .success, .independent, .abort, .drain }) |outcome| {
        var resident = try Resident.init(std.testing.allocator, .{}, .{});
        defer {
            resident.closeAndDrain(2_000) catch unreachable;
            resident.deinit();
        }
        const id = try resident.adopt(100);
        const ops = resident.resident();
        ops.beforeWait(.park);
        try std.testing.expectEqual(@as(isize, 5), ops.tryWrite(id, "bytes"));
        Resident.Completions.startSend(&resident, id, resident.conns.getPtr(id).?);
        const send = resident.backend.pending_send.?;
        resident.backend.pending_send = null;
        try std.testing.expect(ops.connCloseOutcome(id, .awaited) == .pending);
        var detail = glowcap.foundation.FailureChain.initNamed(error.BrokenPipe, "IgnoredRead");
        detail.note(error.TransportCleanup);
        resident.backend.pending_recv = .{
            .user_data = resident.backend.armed_recv_ud.?,
            .result = -1,
            .failure_origin = .terminal_io,
            .borrowed = .failure(&detail, 73),
        };
        resident.pump();
        try std.testing.expect(ops.takeFailure(id) == null);
        try std.testing.expect(ops.connCloseOutcome(id, .awaited) == .pending);
        try std.testing.expectEqual(@as(usize, 0), resident.backend.recycle_calls);
        resident.backend.pending_send = send;
        switch (outcome) {
            .success => try std.testing.expect(ops.connCloseOutcome(id, .awaited) == .complete),
            .independent => {
                resident.backend.pending_send = .{ .user_data = send.user_data, .result = -1, .failure = error.BrokenPipe };
                const close = ops.connCloseOutcome(id, .awaited);
                try std.testing.expect(close == .failed);
                try std.testing.expectEqualStrings("BrokenPipe", close.failed.chain.primaryName());
                try std.testing.expectEqual(@as(u16, 0), close.failed.chain.secondary_count);
            },
            .abort => try std.testing.expect(ops.connAbortOutcome(id, .awaited).? == .complete),
            .drain => try resident.closeAndDrain(2_000),
        }
        try std.testing.expect(ops.takeFailure(id) == null);
        try std.testing.expectEqual(@as(usize, 1), resident.backend.recycle_calls);
        try std.testing.expectEqual(@as(u32, 73), resident.backend.last_recycled_token);
    }
}

test "draining resident refines an unclaimed marked send from the following read" {
    const Case = struct {
        claimed: bool = false,
        shared: bool = true,
        internal_steps: usize = 0,
        expected: enum { rich, scalar, complete } = .rich,
    };
    for ([_]Case{
        .{},
        .{ .claimed = true, .expected = .complete },
        .{ .shared = false, .expected = .scalar },
        .{ .internal_steps = 1 },
        .{ .internal_steps = 128, .expected = .scalar },
    }) |case| {
        var resident = try Resident.init(std.testing.allocator, .{}, .{});
        defer {
            resident.closeAndDrain(2_000) catch unreachable;
            resident.deinit();
        }
        const id = try resident.adopt(100);
        const ops = resident.resident();
        ops.beforeWait(.park);
        try std.testing.expectEqual(@as(isize, 5), ops.tryWrite(id, "bytes"));
        Resident.Completions.startSend(&resident, id, resident.conns.getPtr(id).?);
        const send_ud = resident.backend.pending_send.?.user_data;
        resident.backend.pending_send = null;
        try std.testing.expect(ops.connCloseOutcome(id, .awaited) == .pending);

        var detail = glowcap.foundation.FailureChain.initNamed(error.BrokenPipe, "CarrierWrite");
        detail.note(error.TransportCleanup);
        resident.backend.pending_send = .{
            .user_data = send_ud,
            .result = -1,
            .failure = error.BrokenPipe,
            .failure_origin = if (case.shared) .terminal_io else .operation,
        };
        resident.backend.pending_recv = .{
            .user_data = resident.backend.armed_recv_ud.?,
            .result = -1,
            .failure_origin = .terminal_io,
            .borrowed = .failure(&detail, 73),
        };
        // Only the earlier snapshot consumes the scalar before close.
        resident.backend.internal_steps = case.internal_steps;
        if (case.claimed) {
            resident.pump();
            const first = ops.takeFailure(id) orelse return error.FailureMissing;
            try std.testing.expectEqualStrings("BrokenPipe", first.chain.primaryName());
        }
        // Close reaps the already-ready read before claiming the write.
        const close = ops.connCloseOutcome(id, .awaited);
        switch (case.expected) {
            .complete => try std.testing.expect(close == .complete),
            .rich, .scalar => {
                try std.testing.expect(close == .failed);
                const chain = close.failed.chain;
                if (case.expected == .rich) {
                    try std.testing.expectEqualStrings("CarrierWrite", chain.primaryName());
                    try std.testing.expectEqualStrings("TransportCleanup", chain.secondaryName().?);
                    try std.testing.expectEqual(@as(u16, 1), chain.secondary_count);
                } else {
                    try std.testing.expectEqualStrings("BrokenPipe", chain.primaryName());
                    try std.testing.expectEqual(@as(u16, 0), chain.secondary_count);
                }
            },
        }
        if (case.internal_steps == 128) {
            // The close returned while unrelated ready work still preceded
            // the read. Retirement releases its eventual borrow.
            try std.testing.expect(resident.backend.internal_steps >= 64);
            try std.testing.expectEqual(@as(usize, 0), resident.backend.recycle_calls);
            try resident.closeAndDrain(2_000);
        }
        try std.testing.expectEqual(@as(usize, 1), resident.backend.recycle_calls);
        try std.testing.expectEqual(@as(u32, 73), resident.backend.last_recycled_token);
        try std.testing.expect(ops.takeFailure(id) == null);
    }
}

test "draining resident gives the first close the same read disposition as a subsequent close" {
    for ([_]bool{ false, true }) |marked| {
        for ([_]bool{ false, true }) |write_fails| {
            try closeWithReadyRead(marked, write_fails, false);
            try closeWithReadyRead(marked, write_fails, true);
        }
    }
}

fn closeWithReadyRead(marked: bool, write_fails: bool, observed_before_close: bool) !void {
    var resident = try Resident.init(std.testing.allocator, .{}, .{});
    defer {
        resident.closeAndDrain(2_000) catch unreachable;
        resident.deinit();
    }
    const ops = resident.resident();
    const id = try resident.adopt(100);
    ops.beforeWait(.park);
    try std.testing.expectEqual(@as(isize, 5), ops.tryWrite(id, "bytes"));
    Resident.Completions.startSend(&resident, id, resident.conns.getPtr(id).?);
    const send = resident.backend.pending_send.?;
    resident.backend.pending_send = null;
    var read = glowcap.foundation.FailureChain.initNamed(error.BrokenPipe, "ReadCause");
    read.note(error.ReadCleanup);
    resident.backend.pending_recv = .{
        .user_data = resident.backend.armed_recv_ud.?,
        .result = -1,
        .failure_origin = if (marked) .terminal_io else .operation,
        .borrowed = .failure(&read, 19),
    };
    if (observed_before_close) {
        resident.pump();
        const snapshot = ops.takeFailure(id) orelse return error.FailureMissing;
        try std.testing.expectEqualStrings("ReadCause", snapshot.chain.primaryName());
        try std.testing.expectEqualStrings("ReadCleanup", snapshot.chain.secondaryName().?);
    } else {
        try std.testing.expect(ops.takeFailure(id) == null);
    }
    if (marked and !observed_before_close) resident.backend.terminal_report = .{ .chain = read };
    // The caller's read ownership ends at this first close. The physical
    // write remains outstanding while the close processes a ready read.
    try std.testing.expect(ops.connCloseOutcome(id, .awaited) == .pending);
    if (!write_fails) try std.testing.expect(ops.takeFailure(id) == null);
    resident.backend.pending_send = if (write_fails)
        .{ .user_data = send.user_data, .result = -1, .failure = error.WriteFailed }
    else
        send;
    const close = ops.connCloseOutcome(id, .awaited);
    if (write_fails) {
        try std.testing.expect(close == .failed);
        try std.testing.expectEqual(error.WriteFailed, close.failed.chain.cause);
        try std.testing.expectEqual(0, close.failed.chain.secondary_count);
        try std.testing.expectEqual(@as(u16, 0), close.failed.chain.secondary_count);
    } else {
        try std.testing.expect(close == .complete);
    }
    try std.testing.expectEqual(@as(usize, 1), resident.backend.recycle_calls);
    try std.testing.expectEqual(@as(u32, 19), resident.backend.last_recycled_token);
    try std.testing.expect(ops.takeFailure(id) == null);
}

test "an independent report precedes a marked transfer with the same scalar across live snapshots" {
    for ([_]bool{ false, true }) |dispatched| {
        for ([_]TransferDetail{ .scalar, .retained, .borrowed_and_retained }) |detail|
            try expectLiveOrder(dispatched, detail);
    }
}

const TransferDetail = enum { scalar, retained, borrowed_and_retained };

fn expectLiveOrder(dispatched: bool, detail: TransferDetail) !void {
    var resident = try Resident.init(std.testing.allocator, .{}, .{});
    defer {
        resident.closeAndDrain(2_000) catch unreachable;
        resident.deinit();
    }
    const id = try resident.adopt(100);
    const ops = resident.resident();
    ops.beforeWait(.park);
    try std.testing.expectEqual(5, ops.tryWrite(id, "bytes"));
    Resident.Completions.startSend(&resident, id, resident.conns.getPtr(id).?);
    resident.backend.independent_report = .{ .chain = .initNamed(error.BrokenPipe, "PriorFailure"), .phase = .receive, .detail = .{ .engine_code = -12 } };
    var transfer = glowcap.foundation.FailureChain.initNamed(error.BrokenPipe, "TransferFailure");
    transfer.note(error.TransferCleanup);
    if (detail != .scalar) resident.backend.terminal_report = .{ .chain = transfer };
    const send = resident.backend.pending_send.?.user_data;
    resident.backend.pending_send = .{ .user_data = send, .result = -1, .failure = error.BrokenPipe, .failure_origin = .terminal_io };
    resident.backend.pending_recv = .{
        .user_data = resident.backend.armed_recv_ud.?,
        .result = -1,
        .failure = error.BrokenPipe,
        .failure_origin = .terminal_io,
        .borrowed = if (detail == .borrowed_and_retained) .failure(&transfer, 23) else .{},
    };
    if (dispatched) ops.beforeWait(.park);
    var report = ops.takeFailure(id) orelse return error.FailureMissing;
    try std.testing.expectEqualStrings("PriorFailure", report.chain.primaryName());
    try std.testing.expectEqual(@as(?i32, -12), report.detail.engine_code);
    ops.beforeWait(.park);
    // A scalar-only backend first exposes the transfer when its completion dispatches.
    if (!dispatched and detail == .scalar) {
        try std.testing.expectEqual(0, report.chain.secondary_count);
        const late = ops.takeFailure(id) orelse return error.FailureMissing;
        report.chain.noteChain(late.chain);
    }
    try std.testing.expectEqualStrings(if (detail == .scalar) "BrokenPipe" else "TransferFailure", report.chain.secondaryName().?);
    try std.testing.expectEqual(@as(u16, if (detail == .scalar) 1 else 2), report.chain.secondary_count);
    try std.testing.expect(ops.takeFailure(id) == null);
}
