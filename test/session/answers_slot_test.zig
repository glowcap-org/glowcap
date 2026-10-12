//! Answer-to-Slot projection and typed answer-row storage.

const std = @import("std");
const glowcap = @import("glowcap");
const protocol_oracle = @import("../oracle/protocol_oracle.zig");

const model = glowcap.ocapn.model;
const syrup = glowcap.ocapn.codec.syrup;
const answers = glowcap.ocapn.session;
const slot = glowcap.ocapn.session.slot;

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

test "pending inbound answer is Slot.remote_unresolved" {
    const s = answers.pendingInboundSlot(.from(11));
    try std.testing.expect(slot.toReference(s).? == .promise);
    try std.testing.expectEqual(@as(slot.Position, 11), slot.position(s));
}

test "answerSlot maps AnswerStatus onto remote-mint Slot arms" {
    try std.testing.expectEqual(slot.Slot{ .remote_unresolved = 11 }, answers.answerSlot(.from(11), .pending));
    try std.testing.expectEqual(slot.Slot{ .remote_value = 11 }, answers.answerSlot(.from(11), .fulfilled));
    try std.testing.expectEqual(slot.Slot{ .broken = .{ .mint = .remote, .position = 11 } }, answers.answerSlot(.from(11), .broken));
    try std.testing.expectEqual(
        try slot.fulfill(answers.answerSlot(.from(11), .pending)),
        answers.answerSlot(.from(11), .fulfilled),
    );
    try std.testing.expectEqual(
        try slot.breakSlot(answers.answerSlot(.from(11), .pending)),
        answers.answerSlot(.from(11), .broken),
    );
}

test "pending inbound answer through real syrup codec matches answer oracle fixture" {
    const allocator = std.testing.allocator;
    const fixture = protocol_oracle.fixtureByName("op_resolve_fulfill_promise.bin").?;
    const reference = slot.toReference(answers.pendingInboundSlot(.from(11))).?;
    const encoded = try encodeFulfillRef(allocator, reference);
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings(fixture.bytes(), encoded);
}

test "AnswerCell carries status independently of wire position" {
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(answers.AnswerCell));
    var cell = answers.AnswerCell.initPending(42);
    try std.testing.expectEqual(answers.AnswerStatus.pending, cell.status());
    try std.testing.expect(cell.payload == null);

    try cell.fulfill();
    try std.testing.expectEqual(answers.AnswerStatus.fulfilled, cell.status());

    cell = answers.AnswerCell.initPending(42);
    try cell.breakCell();
    try std.testing.expectEqual(answers.AnswerStatus.broken, cell.status());
}

test "InboundAnswerTable stores wire and virtual names independently" {
    const allocator = std.testing.allocator;
    var table: answers.InboundAnswerTable = .empty;
    defer table.deinit(allocator);

    const wire = model.AnswerName.fromWire(.from(11));
    const virtual = model.AnswerName.fromVirtual(.from(11));
    try table.put(allocator, wire, answers.AnswerCell.initPending(1));
    try table.put(allocator, virtual, answers.AnswerCell.initPending(2));
    try std.testing.expect(table.contains(wire));
    try std.testing.expect(table.contains(virtual));
    try std.testing.expectEqual(@as(usize, 2), table.len());
    const cell = table.getPtr(wire).?;
    try std.testing.expectEqual(answers.AnswerStatus.pending, cell.status());
    try cell.fulfill();
    try std.testing.expectEqual(answers.AnswerStatus.fulfilled, table.getPtr(wire).?.status());
    try std.testing.expectEqual(answers.AnswerStatus.pending, table.getPtr(virtual).?.status());
}

test "Session.inboundAnswerSlot projects live AnswerCell onto Slot" {
    const allocator = std.testing.allocator;
    var s = answers.Session.init(allocator);
    defer s.deinit();

    try std.testing.expect(s.inboundAnswerSlot(.from(11)) == null);
    try s.installInboundAnswer(.from(11));
    try std.testing.expectEqual(
        slot.Slot{ .remote_unresolved = 11 },
        s.inboundAnswerSlot(.from(11)).?,
    );
    try std.testing.expectEqual(answers.AnswerStatus.pending, s.inboundAnswer(.from(11)).?.status);
}

test "Session.outboundAnswerSlot projects live AnswerCell onto Slot" {
    const allocator = std.testing.allocator;
    var s = answers.Session.init(allocator);
    defer s.deinit();

    try std.testing.expect(s.outboundAnswerSlot(.from(7)) == null);
    try s.installOutboundAnswer(.from(7));
    try std.testing.expectEqual(
        slot.Slot{ .remote_unresolved = 7 },
        s.outboundAnswerSlot(.from(7)).?,
    );
    try std.testing.expectEqual(answers.AnswerStatus.pending, s.outboundAnswer(.from(7)).?.status);
}

test "storeResolution pending → fulfilled matches slot.fulfill" {
    const allocator = std.testing.allocator;
    var s = answers.Session.init(allocator);
    defer s.deinit();

    try s.installInboundAnswer(.from(11));
    try s.storeResolution(.from(11), .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "v") } });
    try std.testing.expectEqual(
        slot.Slot{ .remote_value = 11 },
        s.inboundAnswerSlot(.from(11)).?,
    );
    try std.testing.expectEqual(answers.AnswerStatus.fulfilled, s.inboundAnswer(.from(11)).?.status);
}

test "storeResolution pending → broken matches slot.breakSlot" {
    const allocator = std.testing.allocator;
    var s = answers.Session.init(allocator);
    defer s.deinit();

    try s.installInboundAnswer(.from(13));
    try s.storeResolution(.from(13), .{ .@"break" = .{ .message = try allocator.dupe(u8, "x") } });
    try std.testing.expectEqual(
        slot.Slot{ .broken = .{ .mint = .remote, .position = 13 } },
        s.inboundAnswerSlot(.from(13)).?,
    );
    try std.testing.expectEqual(answers.AnswerStatus.broken, s.inboundAnswer(.from(13)).?.status);
    try std.testing.expect(slot.toReference(s.inboundAnswerSlot(.from(13)).?) == null);
}

test "Session exportSlot reads the live export cell" {
    const allocator = std.testing.allocator;
    var s = answers.Session.init(allocator);
    defer s.deinit();

    try std.testing.expect(s.exportSlot(.from(9)) == null);

    const export_pos = try s.allocateExport();
    try std.testing.expectEqual(slot.Slot{ .local_value = export_pos.int() }, s.exportSlot(export_pos).?);
    try std.testing.expect(slot.toReference(s.exportSlot(export_pos).?).?.near.kind == .object);
}

test "Session retainSentExportRef leaves a live export cell authoritative — a re-mention never rebinds it" {
    const allocator = std.testing.allocator;
    var s = answers.Session.init(allocator);
    defer s.deinit();

    // A generically reserved export is an object. Naming it with a promise wire
    // mention takes the wire-delta retain but does not rebind the cell: the wire
    // descriptor rides the marshaled reference, it is not derived into the row
    // (ADR-0080).
    const object_export = try s.allocateExport();
    try std.testing.expectEqual(slot.Slot{ .local_value = object_export.int() }, s.exportSlot(object_export).?);
    try s.retainSentExportRef(.{ .near = .{ .export_position = object_export, .kind = .promise } });
    try std.testing.expectEqual(slot.Slot{ .local_value = object_export.int() }, s.exportSlot(object_export).?);

    // A promise export is authoritative from its allocation. A later object
    // mention does not fulfill it, and a repeat promise mention leaves it be,
    // a live cell is decided once, at establishment.
    const promise_export = try s.allocatePromiseExport();
    try std.testing.expectEqual(slot.Slot{ .local_unresolved = promise_export.int() }, s.exportSlot(promise_export).?);
    try s.retainSentExportRef(.{ .near = .{ .export_position = promise_export, .kind = .object } });
    try std.testing.expectEqual(slot.Slot{ .local_unresolved = promise_export.int() }, s.exportSlot(promise_export).?);
    try s.retainSentExportRef(.{ .near = .{ .export_position = promise_export, .kind = .promise } });
    try std.testing.expectEqual(slot.Slot{ .local_unresolved = promise_export.int() }, s.exportSlot(promise_export).?);
}

test "Session retainSentExportRef mints an absent export's cell from the first wire mention" {
    const allocator = std.testing.allocator;
    var s = answers.Session.init(allocator);
    defer s.deinit();

    // The first mention of an absent position is its only authority: an object
    // mention mints local_value, a promise mention mints local_unresolved (a
    // resolve fulfill or a cross-session re-export; ADR-0080).
    try s.retainSentExportRef(.{ .near = .{ .export_position = .from(7), .kind = .object } });
    try std.testing.expectEqual(slot.Slot{ .local_value = 7 }, s.exportSlot(.from(7)).?);
    try std.testing.expect(slot.toReference(s.exportSlot(.from(7)).?).?.near.kind == .object);

    try s.retainSentExportRef(.{ .near = .{ .export_position = .from(8), .kind = .promise } });
    try std.testing.expectEqual(slot.Slot{ .local_unresolved = 8 }, s.exportSlot(.from(8)).?);
    try std.testing.expect(slot.toReference(s.exportSlot(.from(8)).?).?.near.kind == .promise);
}
