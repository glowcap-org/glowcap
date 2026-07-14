//! Answer → Slot projection and AnswerCell (status derived from binding).

const std = @import("std");
const pancake = @import("pancake");
const protocol_oracle = @import("../oracle/protocol_oracle.zig");

const model = pancake.ocapn.model;
const syrup = pancake.ocapn.codec.syrup;
const answers = pancake.ocapn.session;
const slot = pancake.ocapn.session.slot;

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
    try std.testing.expectEqual(slot.WireDescriptor.desc_answer, slot.wireDescriptor(s).?);
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

test "AnswerCell derives status from Slot; payload hangs off binding" {
    var cell = answers.AnswerCell.initPending(.from(11), 42);
    try std.testing.expectEqual(answers.AnswerStatus.pending, cell.status());
    try std.testing.expectEqual(slot.Slot{ .remote_unresolved = 11 }, cell.binding);
    try std.testing.expect(cell.payload == null);

    try cell.fulfill();
    try std.testing.expectEqual(answers.AnswerStatus.fulfilled, cell.status());
    try std.testing.expectEqual(slot.Slot{ .remote_value = 11 }, cell.binding);

    cell = answers.AnswerCell.initPending(.from(11), 42);
    try cell.breakCell();
    try std.testing.expectEqual(answers.AnswerStatus.broken, cell.status());
    try std.testing.expectEqual(slot.Slot{ .broken = .{ .mint = .remote, .position = 11 } }, cell.binding);
}

test "AnswerTable stores AnswerCell rows by answer position" {
    const allocator = std.testing.allocator;
    var table: answers.AnswerTable = .empty;
    defer table.deinit(allocator);

    try table.put(allocator, .from(11), answers.AnswerCell.initPending(.from(11), 1));
    try std.testing.expect(table.contains(.from(11)));
    try std.testing.expectEqual(@as(usize, 1), table.len());
    const cell = table.getPtr(.from(11)).?;
    try std.testing.expectEqual(answers.AnswerStatus.pending, cell.status());
    try cell.fulfill();
    try std.testing.expectEqual(answers.AnswerStatus.fulfilled, table.getPtr(.from(11)).?.status());
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
    try std.testing.expect(slot.wireDescriptor(s.inboundAnswerSlot(.from(13)).?) == null);
}

test "Session exportSlot and importSlot read live table cells" {
    const allocator = std.testing.allocator;
    var s = answers.Session.init(allocator);
    defer s.deinit();

    try std.testing.expect(s.exportSlot(.from(9)) == null);
    try std.testing.expect(s.importSlot(.from(5)) == null);

    const export_pos = try s.allocateExport();
    try std.testing.expectEqual(slot.Slot{ .local_value = export_pos.int() }, s.exportSlot(export_pos).?);
    try std.testing.expectEqual(slot.WireDescriptor.desc_import_object, slot.wireDescriptor(s.exportSlot(export_pos).?).?);

    // Imports are partner-retained via registerImport.
    try s.registerImport(.from(5));
    try std.testing.expectEqual(slot.Slot{ .remote_value = 5 }, s.importSlot(.from(5)).?);
    try std.testing.expectEqual(slot.WireDescriptor.desc_export, slot.wireDescriptor(s.importSlot(.from(5)).?).?);
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
    // mention does not fulfill it, and a repeat promise mention leaves it be —
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
    try std.testing.expectEqual(slot.WireDescriptor.desc_import_object, slot.wireDescriptor(s.exportSlot(.from(7)).?).?);

    try s.retainSentExportRef(.{ .near = .{ .export_position = .from(8), .kind = .promise } });
    try std.testing.expectEqual(slot.Slot{ .local_unresolved = 8 }, s.exportSlot(.from(8)).?);
    try std.testing.expectEqual(slot.WireDescriptor.desc_import_promise, slot.wireDescriptor(s.exportSlot(.from(8)).?).?);
}
