const std = @import("std");
const testing = std.testing;
const diagnostics = @import("c_abi_shared").failure_diagnostics;
const shared = @import("c_abi_shared");
const foundation = @import("pancake").foundation;
const c = @import("c_abi");

fn cBytes(ptr: ?[*]const u8, len: usize) []const u8 {
    return if (ptr) |p| p[0..len] else &.{};
}

fn providerResult(cause: anyerror) i32 {
    return switch (cause) {
        error.CleanupDenied => shared.PANCAKE_ERR_CLOSED,
        else => shared.PANCAKE_ERR_IO,
    };
}

test "provider failure projection preserves one neutral chain exactly" {
    var failure = foundation.FailureChain.initNamed(error.ProviderProxy, "ProviderRefusedByName");
    failure.noteNamed(error.CleanupDenied, "SocketUnlinkRefused");
    failure.note(error.LaterCleanup);

    var report = shared.transport_provider.emptyProviderFailure();
    try testing.expectEqual(
        shared.PANCAKE_ERR_IO,
        shared.transport_provider.failProviderChain(
            &report,
            shared.PANCAKE_ERR_IO,
            failure,
            providerResult,
        ),
    );
    try testing.expectEqual(shared.PANCAKE_ERR_IO, report.result);
    try testing.expectEqualStrings("ProviderRefusedByName", cBytes(report.primary_name, report.primary_name_len));
    try testing.expectEqual(shared.PANCAKE_ERR_CLOSED, report.secondary_result);
    try testing.expectEqualStrings("SocketUnlinkRefused", cBytes(report.secondary_name, report.secondary_name_len));
    try testing.expectEqual(@as(u32, 2), report.secondary_count);

    shared.lastErrorClear();
    shared.setLastErrorChain("provider release", failure);
    var message: [256]u8 = undefined;
    const len = shared.lastErrorRead(&message, message.len);
    try testing.expectEqualStrings(
        "provider release: ProviderRefusedByName; cleanup: SocketUnlinkRefused (2 secondary failures)",
        message[0..len],
    );
}

test "Context lifecycle identities are stable nonzero and do not wrap" {
    var context: ?*c.PancakeContext = null;
    try testing.expectEqual(c.PANCAKE_OK, c.pancake_context_new(&context));
    defer c.pancake_context_release(context);

    var first: u64 = 0;
    var second: u64 = 0;
    try testing.expectEqual(c.PANCAKE_OK, c.pancake_context_allocate_lifecycle_id(context, &first));
    try testing.expectEqual(c.PANCAKE_OK, c.pancake_context_allocate_lifecycle_id(context, &second));
    try testing.expectEqual(@as(u64, 1), first);
    try testing.expectEqual(@as(u64, 2), second);
    try testing.expectEqual(c.PANCAKE_ERR_NULL_POINTER, c.pancake_context_allocate_lifecycle_id(context, null));

    var ids = shared.LifecycleIds.init();
    ids.value.store(std.math.maxInt(u64), .monotonic);
    try testing.expectError(error.IdentifierExhausted, ids.allocate());
}

test "failure diagnostics preserve typed cause identity and claim once" {
    var journal = try diagnostics.Journal.init(testing.allocator, 2, 256);
    defer journal.deinit(testing.allocator);
    journal.record(.{
        .layer = .transport,
        .operation = "listener.close",
        .scope_kind = .listener,
        .scope_id = 31,
        .operation_id = 47,
        .primary_result = c.PANCAKE_ERR_IO,
        .primary_name = "CloseFailed",
        .primary_message = "socket refused shutdown",
        .secondary_result = c.PANCAKE_ERR_INTERNAL,
        .secondary_name = "ReleaseFailed",
        .secondary_message = "descriptor remained live",
        .secondary_count = 2,
    });

    try testing.expectEqual(@as(?usize, 85), journal.nextPayloadLen());
    var payload: [256]u8 = undefined;
    var event: diagnostics.Claim = undefined;
    var required: usize = undefined;
    try testing.expect(try journal.pop(&event, &payload, &required));
    try testing.expectEqual(@as(usize, 85), required);
    try testing.expectEqual(@as(u64, 1), event.sequence);
    try testing.expectEqual(diagnostics.Layer.transport, event.layer);
    try testing.expectEqual(diagnostics.ScopeKind.listener, event.scope_kind);
    try testing.expectEqual(@as(u64, 31), event.scope_id);
    try testing.expectEqual(@as(u64, 47), event.operation_id);
    try testing.expectEqual(c.PANCAKE_ERR_IO, event.primary_result);
    try testing.expectEqual(c.PANCAKE_ERR_INTERNAL, event.secondary_result);
    try testing.expectEqual(@as(u32, 2), event.secondary_count);
    try testing.expectEqualStrings("listener.close", event.operation);
    try testing.expectEqualStrings("CloseFailed", event.primary_name);
    try testing.expectEqualStrings("socket refused shutdown", event.primary_message);
    try testing.expectEqualStrings("ReleaseFailed", event.secondary_name);
    try testing.expectEqualStrings("descriptor remained live", event.secondary_message);
    try testing.expect(!try journal.pop(&event, &payload, &required));
}

test "failure diagnostics expose saturation before the surviving prefix" {
    var journal = try diagnostics.Journal.init(testing.allocator, 2, 64);
    defer journal.deinit(testing.allocator);
    for (1..5) |id| journal.record(.{
        .layer = .binding,
        .operation = "finalizer",
        .scope_kind = .operation,
        .scope_id = id,
        .primary_name = "ReleaseFailed",
    });

    var payload: [64]u8 = undefined;
    var event: diagnostics.Claim = undefined;
    var required: usize = undefined;
    try testing.expect(try journal.pop(&event, &payload, &required));
    try testing.expectEqual(@as(u64, 3), event.sequence);
    try testing.expectEqual(@as(u64, 2), event.dropped_before);
    try testing.expectEqual(@as(u64, 3), event.scope_id);
    try testing.expect(try journal.pop(&event, &payload, &required));
    try testing.expectEqual(@as(u64, 4), event.sequence);
    try testing.expectEqual(@as(u64, 0), event.dropped_before);
}

test "one-slot failure diagnostics retain the entire saturation gap" {
    var journal = try diagnostics.Journal.init(testing.allocator, 1, 32);
    defer journal.deinit(testing.allocator);
    for (1..5) |id| journal.record(.{
        .layer = .binding,
        .operation = "finalizer",
        .scope_kind = .operation,
        .scope_id = id,
        .primary_name = "ReleaseFailed",
    });

    var payload: [32]u8 = undefined;
    var event: diagnostics.Claim = undefined;
    var required: usize = undefined;
    try testing.expect(try journal.pop(&event, &payload, &required));
    try testing.expectEqual(@as(u64, 4), event.sequence);
    try testing.expectEqual(@as(u64, 3), event.dropped_before);
    try testing.expectEqual(@as(u64, 4), event.scope_id);
}

test "failure diagnostics refuse a short claim without consuming" {
    var journal = try diagnostics.Journal.init(testing.allocator, 1, 32);
    defer journal.deinit(testing.allocator);
    journal.record(.{
        .layer = .application_observer,
        .operation = "trace.sink",
        .scope_kind = .process,
        .primary_name = "CallbackFailed",
    });
    var short: [1]u8 = undefined;
    var event: diagnostics.Claim = undefined;
    var required: usize = undefined;
    try testing.expectError(error.BufferTooSmall, journal.pop(&event, &short, &required));
    try testing.expect(required > short.len);
    var payload: [32]u8 = undefined;
    try testing.expect(try journal.pop(&event, &payload, &required));
    try testing.expectEqual(@as(u64, 1), event.sequence);
}

test "failure diagnostics make truncation explicit" {
    var journal = try diagnostics.Journal.init(testing.allocator, 1, 8);
    defer journal.deinit(testing.allocator);
    journal.record(.{
        .layer = .transport,
        .operation = "transport.release",
        .scope_kind = .transport,
        .primary_name = "ReleaseFailed",
    });
    var payload: [8]u8 = undefined;
    var event: diagnostics.Claim = undefined;
    var required: usize = undefined;
    try testing.expect(try journal.pop(&event, &payload, &required));
    try testing.expect(event.flags & diagnostics.truncated_operation != 0);
    try testing.expect(event.flags & diagnostics.truncated_primary_name != 0);
}

test "failure diagnostics truncate UTF-8 only at code-point boundaries" {
    var journal = try diagnostics.Journal.init(testing.allocator, 1, 3);
    defer journal.deinit(testing.allocator);
    journal.record(.{
        .layer = .binding,
        .operation = "abécd",
        .scope_kind = .context,
        .primary_name = "Cause",
    });
    var payload: [3]u8 = undefined;
    var event: diagnostics.Claim = undefined;
    var required: usize = undefined;
    try testing.expect(try journal.pop(&event, &payload, &required));
    try testing.expectEqualStrings("ab", event.operation);
    try testing.expect(std.unicode.utf8ValidateSlice(event.operation));
    try testing.expect(event.flags & diagnostics.truncated_operation != 0);
}

test "C Context rejects non-UTF-8 diagnostic text" {
    var context: ?*c.PancakeContext = null;
    try testing.expectEqual(c.PANCAKE_OK, c.pancake_context_new(&context));
    defer c.pancake_context_release(context);

    const invalid = [_]u8{0xff};
    const primary_name = "Cause";
    const report = c.PancakeFailureReport{
        .abi_version = c.PANCAKE_FAILURE_EVENT_ABI_VERSION,
        .struct_size = @sizeOf(c.PancakeFailureReport),
        .layer = c.PANCAKE_FAILURE_LAYER_BINDING,
        .scope_kind = c.PANCAKE_FAILURE_SCOPE_CONTEXT,
        .scope_id = 0,
        .operation_id = 0,
        .primary_result = c.PANCAKE_ERR_INTERNAL,
        .secondary_result = 0,
        .secondary_count = 0,
        .operation = invalid[0..].ptr,
        .operation_len = invalid.len,
        .primary_name = primary_name.ptr,
        .primary_name_len = primary_name.len,
        .primary_message = null,
        .primary_message_len = 0,
        .secondary_name = null,
        .secondary_name_len = 0,
        .secondary_message = null,
        .secondary_message_len = 0,
    };
    try testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, c.pancake_context_report_failure(context, &report));
}

test "C Context reports and atomically claims the cross-language failure vector" {
    var context: ?*c.PancakeContext = null;
    try testing.expectEqual(c.PANCAKE_OK, c.pancake_context_new(&context));
    defer c.pancake_context_release(context);

    const operation = "listener.close";
    const primary_name = "CloseFailed";
    const primary_message = "socket refused shutdown";
    const secondary_name = "ReleaseFailed";
    const secondary_message = "descriptor remained live";
    var report = c.PancakeFailureReport{
        .abi_version = c.PANCAKE_FAILURE_EVENT_ABI_VERSION,
        .struct_size = @sizeOf(c.PancakeFailureReport),
        .layer = c.PANCAKE_FAILURE_LAYER_TRANSPORT,
        .scope_kind = c.PANCAKE_FAILURE_SCOPE_LISTENER,
        .scope_id = 31,
        .operation_id = 47,
        .primary_result = c.PANCAKE_ERR_IO,
        .secondary_result = c.PANCAKE_ERR_INTERNAL,
        .secondary_count = 2,
        .operation = operation.ptr,
        .operation_len = operation.len,
        .primary_name = primary_name.ptr,
        .primary_name_len = primary_name.len,
        .primary_message = primary_message.ptr,
        .primary_message_len = primary_message.len,
        .secondary_name = secondary_name.ptr,
        .secondary_name_len = secondary_name.len,
        .secondary_message = secondary_message.ptr,
        .secondary_message_len = secondary_message.len,
    };
    try testing.expectEqual(c.PANCAKE_OK, c.pancake_context_report_failure(context, &report));

    var event: c.PancakeFailureEvent = undefined;
    var required: usize = 0;
    try testing.expectEqual(
        c.PANCAKE_ERR_BUFFER_TOO_SMALL,
        c.pancake_context_next_failure(context, &event, null, 0, &required),
    );
    try testing.expect(required > 0);
    var payload: [128]u8 = undefined;
    try testing.expect(required <= payload.len);
    try testing.expectEqual(
        c.PANCAKE_OK,
        c.pancake_context_next_failure(context, &event, &payload, payload.len, &required),
    );
    try testing.expectEqual(c.PANCAKE_FAILURE_EVENT_ABI_VERSION, event.abi_version);
    try testing.expectEqual(@as(u64, 1), event.sequence);
    try testing.expectEqual(c.PANCAKE_FAILURE_LAYER_TRANSPORT, event.layer);
    try testing.expectEqual(c.PANCAKE_FAILURE_SCOPE_LISTENER, event.scope_kind);
    try testing.expectEqual(@as(u64, 31), event.scope_id);
    try testing.expectEqual(@as(u64, 47), event.operation_id);
    try testing.expectEqual(c.PANCAKE_ERR_IO, event.primary_result);
    try testing.expectEqual(c.PANCAKE_ERR_INTERNAL, event.secondary_result);
    try testing.expectEqual(@as(u32, 2), event.secondary_count);
    try testing.expectEqualStrings(operation, cBytes(event.operation, event.operation_len));
    try testing.expectEqualStrings(primary_name, cBytes(event.primary_name, event.primary_name_len));
    try testing.expectEqualStrings(primary_message, cBytes(event.primary_message, event.primary_message_len));
    try testing.expectEqualStrings(secondary_name, cBytes(event.secondary_name, event.secondary_name_len));
    try testing.expectEqualStrings(secondary_message, cBytes(event.secondary_message, event.secondary_message_len));
    try testing.expectEqual(
        c.PANCAKE_ERR_WOULD_BLOCK,
        c.pancake_context_next_failure(context, &event, &payload, payload.len, &required),
    );
    try testing.expectEqual(@as(usize, 0), required);

    report.abi_version += 1;
    try testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, c.pancake_context_report_failure(context, &report));

    report.abi_version -= 1;
    report.primary_result = -99;
    try testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, c.pancake_context_report_failure(context, &report));

    report.primary_result = c.PANCAKE_OK;
    report.primary_name_len = 0;
    try testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, c.pancake_context_report_failure(context, &report));

    report.primary_result = c.PANCAKE_ERR_INTERNAL;
    report.primary_name_len = primary_name.len;
    report.secondary_count = 0;
    try testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, c.pancake_context_report_failure(context, &report));

    report.secondary_result = c.PANCAKE_OK;
    report.secondary_name_len = 0;
    report.secondary_count = 1;
    try testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, c.pancake_context_report_failure(context, &report));

    report.secondary_result = c.PANCAKE_ERR_IO;
    try testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, c.pancake_context_report_failure(context, &report));
}
