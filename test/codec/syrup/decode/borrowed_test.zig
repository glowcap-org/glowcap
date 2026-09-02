//! Borrowed Syrup views: abort fixtures, GC position lists, and deliver,
//! get, index, listen, and resolve bodies without copying message bytes.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const syrup = glowcap.ocapn.codec.syrup;
const protocol_oracle = @import("../../../oracle/protocol_oracle.zig");
const handoff_fixtures = @import("../../../support/handoff_fixtures.zig");

const harness = @import("../harness.zig");
const expectFixtureBytes = harness.expectFixtureBytes;
const repeatedByte = harness.repeatedByte;
const hexToOwned = harness.hexToOwned;

test "op:abort fixture decodes as a borrowed view" {
    const frame = glowcap.foundation.FrameView{
        .bytes = "<8'op:abort13\"shutting down>",
        .shape = .byte,
    };

    const decoded = try syrup.decodeBody(frame);

    try std.testing.expectEqual(model.AbortKind.other, decoded.abort.kind);
    try std.testing.expectEqualStrings("shutting down", decoded.abort.message);
    try std.testing.expectEqual(@intFromPtr(frame.bytes.ptr) + 14, @intFromPtr(decoded.abort.message.ptr));
}

test "typed op:abort fixture decodes without copying message bytes" {
    const fixture = protocol_oracle.fixtureByName("op_abort_typed.bin").?;
    const frame = glowcap.foundation.FrameView{
        .bytes = fixture.bytes(),
        .shape = .byte,
    };

    const decoded = try syrup.decodeBody(frame);

    try std.testing.expectEqual(model.AbortKind.version_mismatch, decoded.abort.kind);
    try std.testing.expectEqualStrings("peer requested 2.0", decoded.abort.message);
}

test "op:abort with an unrecognized label prefix stays other, message verbatim" {
    // The decoder recovers a kind only from labels the model names; a peer's
    // free-form "<Word>: ..." message must not lose its prefix to a label that
    // matches nothing.
    const frame = glowcap.foundation.FrameView{
        .bytes = "<8'op:abort14\"Bogus: message>",
        .shape = .byte,
    };

    const decoded = try syrup.decodeBody(frame);

    try std.testing.expectEqual(model.AbortKind.other, decoded.abort.kind);
    try std.testing.expectEqualStrings("Bogus: message", decoded.abort.message);
}

test "decodeBody exposes borrowed GC position lists" {
    {
        const fixture = protocol_oracle.fixtureByName("op_gc_exports.bin").?;
        const decoded = try syrup.decodeBody(.{ .bytes = fixture.bytes(), .shape = .byte });

        try std.testing.expectEqual(@as(usize, 2), try decoded.gc_export.positions.len());
        try std.testing.expectEqual(@as(u64, 3), try decoded.gc_export.positions.at(0));
        try std.testing.expectEqual(@as(u64, 7), try decoded.gc_export.positions.at(1));
        try std.testing.expectEqual(@as(u64, 1), try decoded.gc_export.deltas.at(0));
        try std.testing.expectEqual(@as(u64, 2), try decoded.gc_export.deltas.at(1));
    }

    {
        const fixture = protocol_oracle.fixtureByName("op_gc_answers.bin").?;
        const decoded = try syrup.decodeBody(.{ .bytes = fixture.bytes(), .shape = .byte });

        try std.testing.expectEqual(@as(usize, 2), try decoded.gc_answer.positions.len());
        try std.testing.expectEqual(@as(u64, 11), try decoded.gc_answer.positions.at(0));
        try std.testing.expectEqual(@as(u64, 13), try decoded.gc_answer.positions.at(1));
    }
}

test "decodeBody exposes borrowed views for deliver, get, index, listen, and resolve" {
    // The decoder lifts each payload/target descriptor into the receiver's
    // perspective (ADR-0010 flip): `<desc:export N>` → `.near{export_position=N}` and
    // `<desc:import-object N>` → `.far{import_position=N}`. The fixture-name `_far` /
    // `_near` labels predate the flip and now describe the wire descriptor's
    // historical model arm, not the decoded one.
    {
        const fixture = protocol_oracle.fixtureByName("op_deliver.bin").?;
        const decoded = try syrup.decodeBody(.{ .bytes = fixture.bytes(), .shape = .byte });

        try std.testing.expectEqual(@as(u64, 7), decoded.deliver.target.near.export_position.int());
        try std.testing.expectEqual(@as(usize, 1), try decoded.deliver.args.len());
        try std.testing.expectEqualStrings("hello", (try decoded.deliver.args.at(0)).bytes);
        try std.testing.expectEqual(@as(u64, 42), decoded.deliver.answer.?.int());
        try std.testing.expect(decoded.deliver.resolve_me_desc == null);
    }

    {
        const fixture = protocol_oracle.fixtureByName("op_get.bin").?;
        const decoded = try syrup.decodeBody(.{ .bytes = fixture.bytes(), .shape = .byte });

        try std.testing.expectEqual(@as(u64, 7), decoded.get.receiver.near.export_position.int());
        try std.testing.expectEqualStrings("name", decoded.get.field);
        try std.testing.expectEqual(@as(u64, 11), decoded.get.answer.int());
    }

    {
        const fixture = protocol_oracle.fixtureByName("op_index.bin").?;
        const decoded = try syrup.decodeBody(.{ .bytes = fixture.bytes(), .shape = .byte });

        try std.testing.expectEqual(@as(u64, 7), decoded.index.receiver.near.export_position.int());
        try std.testing.expectEqual(@as(i64, 5), decoded.index.index.integer);
        try std.testing.expectEqual(@as(u64, 11), decoded.index.answer.int());
    }

    {
        const fixture = protocol_oracle.fixtureByName("op_untag.bin").?;
        const decoded = try syrup.decodeBody(.{ .bytes = fixture.bytes(), .shape = .byte });

        try std.testing.expectEqual(@as(u64, 7), decoded.untag.receiver.near.export_position.int());
        try std.testing.expectEqualStrings("cm", decoded.untag.tag);
        try std.testing.expectEqual(@as(u64, 11), decoded.untag.answer.int());
    }

    {
        const fixture = protocol_oracle.fixtureByName("op_listen_promise_target.bin").?;
        const decoded = try syrup.decodeBody(.{ .bytes = fixture.bytes(), .shape = .byte });

        try std.testing.expectEqual(@as(u64, 7), decoded.listen.target.promise.answer_position.int());
        try std.testing.expectEqual(@as(u64, 9), decoded.listen.listener.far.import_position.int());
        try std.testing.expectEqual(model.ListenMode.settling_only, decoded.listen.mode);
    }

    {
        const fixture = protocol_oracle.fixtureByName("op_resolve_break.bin").?;
        const decoded = try syrup.decodeBody(.{ .bytes = fixture.bytes(), .shape = .byte });

        try std.testing.expectEqual(@as(u64, 42), decoded.resolve.answer.int());
        try std.testing.expectEqualStrings("target unreachable", decoded.resolve.resolution.@"break".message);
    }

    {
        const fixture = protocol_oracle.fixtureByName("op_resolve_fulfill_far.bin").?;
        const decoded = try syrup.decodeBody(.{ .bytes = fixture.bytes(), .shape = .byte });

        try std.testing.expectEqual(@as(u64, 7), decoded.resolve.answer.int());
        // `<desc:export 5>` lifts to `.near` post-flip (fixture name predates it).
        try std.testing.expectEqual(@as(u64, 5), decoded.resolve.resolution.fulfill.reference.near.export_position.int());
    }

    {
        const fixture = protocol_oracle.fixtureByName("op_resolve_fulfill_near.bin").?;
        const decoded = try syrup.decodeBody(.{ .bytes = fixture.bytes(), .shape = .byte });

        // `<desc:import-object 9>` lifts to `.far` post-flip.
        try std.testing.expectEqual(@as(u64, 9), decoded.resolve.resolution.fulfill.reference.far.import_position.int());
    }

    {
        const fixture = protocol_oracle.fixtureByName("op_resolve_fulfill_promise.bin").?;
        const decoded = try syrup.decodeBody(.{ .bytes = fixture.bytes(), .shape = .byte });

        try std.testing.expectEqual(@as(u64, 11), decoded.resolve.resolution.fulfill.reference.promise.answer_position.int());
    }
}
