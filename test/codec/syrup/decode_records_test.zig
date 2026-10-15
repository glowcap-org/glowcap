//! What Syrup decode makes of the two wide records a frame may carry, the
//! signed handoff envelope and the sturdyref: framed at decode, parsed when a
//! consumer reads them, and refused there when the bytes do not spell one.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const syrup = glowcap.ocapn.codec.syrup;
const protocol_oracle = @import("../../oracle/protocol_oracle.zig");

test "decodeBody exposes borrowed views for start-session and nested handoff" {
    {
        const fixture = protocol_oracle.fixtureByName("op_start_session_v1_0.bin").?;
        const decoded = try syrup.decodeBody(.{ .bytes = fixture.bytes(), .shape = .byte });

        try std.testing.expectEqual(model.CaptpVersion.v1_0, decoded.start_session.captp_version);
        try std.testing.expectEqual(@as(usize, 32), decoded.start_session.session_pubkey.len);
        try std.testing.expectEqualStrings("memory", decoded.start_session.acceptable_location.transport);
        try std.testing.expectEqualStrings("exporter", decoded.start_session.acceptable_location.designator);
        const sig = decoded.start_session.acceptable_location_sig.halves;
        try std.testing.expectEqual(@as(usize, 64), sig.r.len + sig.s.len);
    }

    {
        const fixture = protocol_oracle.fixtureByName("op_deliver_withdraw_gift.bin").?;
        const decoded = try syrup.decodeBody(.{ .bytes = fixture.bytes(), .shape = .byte });
        const handoff = try (try decoded.deliver.args.at(1)).handoff.project();
        try std.testing.expect(handoff == .receive);
        try std.testing.expect(handoff.receive.signed_give.raw_signed != null);
    }
}

test "typed handoff projection ignores an earlier complete envelope inside bytes" {
    const allocator = std.testing.allocator;
    const fixture = protocol_oracle.fixtureByName("desc_handoff_give_signed.bin").?;
    const give = try syrup.decodeSignedHandoffGiveOwned(allocator, fixture.bytes());
    defer model.freeHandoffGive(allocator, give);
    var handoff: model.Handoff = .{ .give = give };
    const args = [_]model.Argument{
        .{ .bytes = fixture.bytes() },
        .{ .handoff = &handoff },
    };
    var frame = try syrup.encodeMessage(allocator, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &args,
    } });
    defer frame.deinit();

    const deliver = (try syrup.decodeBody(frame.view())).deliver;
    const decoy = (try deliver.args.at(0)).bytes;
    const projected = (try (try deliver.args.at(1)).handoff.project()).give;
    const signed = projected.raw_signed orelse return error.MissingSignedGiveSpan;

    try std.testing.expectEqualSlices(u8, fixture.bytes(), decoy);
    try std.testing.expectEqualSlices(u8, fixture.bytes(), signed);
    try std.testing.expect(@intFromPtr(signed.ptr) >= @intFromPtr(decoy.ptr) + decoy.len);
}

test "standalone signed handoff-give decode refuses trailing bytes" {
    const allocator = std.testing.allocator;
    const fixture = protocol_oracle.fixtureByName("desc_handoff_give_signed.bin").?;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);

    try bytes.appendSlice(allocator, fixture.bytes());
    try bytes.append(allocator, 'x');
    try std.testing.expectError(
        syrup.Error.MalformedFrame,
        syrup.decodeSignedHandoffGiveOwned(allocator, bytes.items),
    );
}

test "Syrup frames a sturdyref at decode and refuses a malformed one when it is read" {
    // The record is bounded by the structural walk like any foreign record,
    // and parsed when a consumer projects it (`model.view.Lazy`). A fourth
    // field is a record the typed grammar does not spell: the frame decodes,
    // the projection refuses, and the owned decode carries that verdict.
    const well_formed = "<10'op:deliver<11'desc:export7+>[<15'ocapn-sturdyref<10'ocapn-peer3'tcp11\"127.0.0.1:0{}>5:swiss>]ff>";
    const body = try syrup.decodeBody(.{ .bytes = well_formed, .shape = .byte });
    const sturdy = try (try body.deliver.args.at(0)).reference.sturdy.project();
    try std.testing.expectEqualStrings("tcp", sturdy.peer.transport);
    try std.testing.expectEqualStrings("swiss", sturdy.swissnum);

    const trailing = "<10'op:deliver<11'desc:export7+>[<15'ocapn-sturdyref<10'ocapn-peer3'tcp11\"127.0.0.1:0{}>5:swiss3:xyz>]ff>";
    const trailing_view = glowcap.foundation.FrameView{ .bytes = trailing, .shape = .byte };
    const framed = try syrup.decodeBody(trailing_view);
    try std.testing.expectError(error.MalformedView, (try framed.deliver.args.at(0)).reference.sturdy.project());
    try std.testing.expectError(error.MalformedView, syrup.decodeOwned(std.testing.allocator, trailing_view));
}

test "Syrup frames a signed envelope at decode and refuses an unreadable payload when it is read" {
    const frame = "<10'op:deliver<11'desc:export7+>[<17'desc:sig-envelope3'foo>]ff>";
    const view = glowcap.foundation.FrameView{ .bytes = frame, .shape = .byte };
    const body = try syrup.decodeBody(view);
    try std.testing.expectError(error.MalformedView, (try body.deliver.args.at(0)).handoff.project());
    try std.testing.expectError(error.MalformedView, syrup.decodeOwned(std.testing.allocator, view));
}
