//! ADR-0080: Slot-to-`model.Reference` projection is lossless against the real
//! syrup codec and the oracle corpus. No second Syrup encoder lives in `slot.zig`.

const std = @import("std");
const glowcap = @import("glowcap");
const protocol_oracle = @import("../oracle/protocol_oracle.zig");

const model = glowcap.ocapn.model;
const syrup = glowcap.ocapn.codec.syrup;
const slot = glowcap.ocapn.session.slot;

/// Encode a payload reference the way CapTP does: as the fulfill of an
/// `op:resolve`. Bytes come only from `syrup.encodeMessage`.
fn encodeFulfillRef(allocator: std.mem.Allocator, reference: model.Reference) ![]u8 {
    var frame = try syrup.encodeMessage(allocator, .{
        .resolve = .{
            .answer = .from(7),
            .resolution = .{ .fulfill = .{ .reference = reference } },
        },
    });
    defer frame.deinit();
    return try allocator.dupe(u8, frame.bytes());
}

test "slot projects each CapTP wire reference" {
    try std.testing.expect(slot.toReference(.{ .local_unresolved = 7 }).?.near.kind == .promise);
    try std.testing.expect(slot.toReference(.{ .remote_unresolved = 7 }).? == .promise);
    try std.testing.expect(slot.toReference(.{ .local_value = 7 }).?.near.kind == .object);
    try std.testing.expect(slot.toReference(.{ .remote_value = 7 }).?.far.kind == .object);
    try std.testing.expect(slot.toReference(.{ .broken = .{ .mint = .local, .position = 7 } }) == null);
}

test "slot toReference matches the Reference the syrup codec already encodes" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { slot.Slot, model.Reference }{
        .{ .{ .remote_value = 5 }, .{ .far = model.FarRef.object(5) } },
        .{ .{ .local_value = 9 }, .{ .near = model.NearRef.object(9) } },
        .{ .{ .remote_unresolved = 11 }, .{ .promise = .{ .answer_position = .from(11) } } },
        .{ .{ .local_unresolved = 99 }, .{ .near = model.NearRef.promise(99) } },
    };
    for (cases) |case| {
        const from_slot = slot.toReference(case[0]).?;
        const via_slot = try encodeFulfillRef(allocator, from_slot);
        defer allocator.free(via_slot);
        const via_ref = try encodeFulfillRef(allocator, case[1]);
        defer allocator.free(via_ref);
        try std.testing.expectEqualStrings(via_ref, via_slot);
    }
}

test "slot projection through real syrup codec matches oracle corpus descriptors" {
    const allocator = std.testing.allocator;

    // Oracle fixtures (generate.rkt): resolve fulfill carrying each desc:*.
    // Fixture names are historical; bytes are the wire truth.
    const oracle_cases = [_]struct { []const u8, slot.Slot }{
        // `<…<desc:export 5+>>`, remote value → far on encode
        .{ "op_resolve_fulfill_far.bin", .{ .remote_value = 5 } },
        // `<…<desc:import-object 9+>>`, local value → near object on encode
        .{ "op_resolve_fulfill_near.bin", .{ .local_value = 9 } },
        // `<…<desc:answer 11+>>`, remote unresolved → promise/answer on encode
        .{ "op_resolve_fulfill_promise.bin", .{ .remote_unresolved = 11 } },
        // `<…<desc:import-promise 99+>>`, local unresolved → near promise on encode
        .{ "op_resolve_fulfill_import_promise.bin", .{ .local_unresolved = 99 } },
    };

    for (oracle_cases) |case| {
        const fixture = protocol_oracle.fixtureByName(case[0]).?;
        const reference = slot.toReference(case[1]).?;
        const encoded = try encodeFulfillRef(allocator, reference);
        defer allocator.free(encoded);
        try std.testing.expectEqualStrings(fixture.bytes(), encoded);
    }
}

test "impossible product cells are not constructible — sum only exposes legal arms" {
    const info = @typeInfo(slot.Slot);
    try std.testing.expect(info == .@"union");
    try std.testing.expectEqual(@as(usize, 5), info.@"union".field_names.len);
}

test "Slot never stores a wire descriptor or kind tag — projection only" {
    // ADR-0080 acceptance: descriptor is computed, never a field on the cell.
    comptime {
        const fields = @typeInfo(slot.Slot).@"union".field_names;
        for (fields) |field_name| {
            if (std.mem.eql(u8, field_name, "kind") or
                std.mem.eql(u8, field_name, "descriptor") or
                std.mem.eql(u8, field_name, "wire_descriptor") or
                std.mem.indexOf(u8, field_name, "desc") != null)
            {
                @compileError("Slot must not store a wire descriptor/kind field; project via toReference");
            }
        }
    }
    _ = slot.toReference(.{ .local_value = 1 });
}

test "slot fulfill and break are one transition path preserving mint" {
    const local = slot.Slot{ .local_unresolved = 3 };
    const remote = slot.Slot{ .remote_unresolved = 11 };

    try std.testing.expectEqual(slot.Slot{ .local_value = 3 }, try slot.fulfill(local));
    try std.testing.expectEqual(slot.Slot{ .remote_value = 11 }, try slot.fulfill(remote));
    try std.testing.expectEqual(slot.Slot{ .broken = .{ .mint = .local, .position = 3 } }, try slot.breakSlot(local));
    try std.testing.expectEqual(slot.Slot{ .broken = .{ .mint = .remote, .position = 11 } }, try slot.breakSlot(remote));

    try std.testing.expectError(error.NotUnresolved, slot.fulfill(.{ .local_value = 3 }));
    try std.testing.expectError(error.NotUnresolved, slot.breakSlot(.{ .remote_value = 11 }));
    try std.testing.expectEqual(slot.Mint.local, slot.mintOf(local));
    try std.testing.expectEqual(slot.Mint.remote, slot.mintOf(remote));
}
