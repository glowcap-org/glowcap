//! What the Syrup decoder admits and refuses in a locator's hint map: string
//! keys in canonical order with no duplicate name, a reserved profile name
//! only over a value the hint grammar knows, and a real netlayer's address
//! hints carried through to the owned form. The borrowed walk refuses what
//! the owned walk refuses, in a hello and inside a sturdyref argument alike.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const syrup = glowcap.ocapn.codec.syrup;

const harness = @import("harness.zig");
const repeatedByte = harness.repeatedByte;

test "Syrup decode refuses duplicate feature hints as a noncanonical dictionary" {
    const allocator = std.testing.allocator;
    var peer = glowcap.ocapn.engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    peer.verify_partner_handshake = false;

    const frame_bytes: []const u8 =
        "<16'op:start-session3\"1.0" ++
        "[10'public-key[3'ecc[5'curve7'Ed25519][5'flags5'eddsa][1'q32:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA]]]" ++
        "<10'ocapn-peer3'tcp9\"127.0.0.1{16\"glowcap/features0\"16\"glowcap/features10\"pipelining}>" ++
        "[7'sig-val[5'eddsa[1'r32:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB][1's32:CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC]]]>";
    const view = glowcap.foundation.FrameView{ .bytes = frame_bytes, .shape = .byte };
    try std.testing.expectError(
        syrup.Error.MalformedFrame,
        syrup.decodeBody(view),
    );
    try std.testing.expectError(syrup.Error.MalformedFrame, peer.recvBorrowed(view));
    try std.testing.expect(!peer.session_state.handshake_remote_received);
}

test "Syrup locator hints reject string and symbol spellings of one name" {
    const frame_bytes: []const u8 =
        "<16'op:start-session3\"1.0" ++
        "[10'public-key[3'ecc[5'curve7'Ed25519][5'flags5'eddsa][1'q32:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA]]]" ++
        "<10'ocapn-peer3'tcp9\"127.0.0.1{1\"a1\"x1'a1\"y}>" ++
        "[7'sig-val[5'eddsa[1'r32:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB][1's32:CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC]]]>";
    const view = glowcap.foundation.FrameView{ .bytes = frame_bytes, .shape = .byte };
    try std.testing.expectError(syrup.Error.MalformedFrame, syrup.decodeBody(view));
}

test "Syrup locator hints require string keys" {
    const frame_bytes: []const u8 =
        "<16'op:start-session3\"1.0" ++
        "[10'public-key[3'ecc[5'curve7'Ed25519][5'flags5'eddsa][1'q32:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA]]]" ++
        "<10'ocapn-peer3'tcp9\"127.0.0.1{1'a1\"x}>" ++
        "[7'sig-val[5'eddsa[1'r32:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB][1's32:CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC]]]>";
    const view = glowcap.foundation.FrameView{ .bytes = frame_bytes, .shape = .byte };
    try std.testing.expectError(syrup.Error.MalformedFrame, syrup.decodeBody(view));
}

test "a sturdyref argument refuses a malformed reserved profile hint on the borrowed path" {
    // The borrowed hint walk refuses the same shapes the owned walk refuses,
    // so a locator inside an argument never decodes into a view whose
    // materialization fails later.
    const refused: []const u8 =
        "<10'op:deliver<11'desc:export0+>[" ++
        "<15'ocapn-sturdyref<10'ocapn-peer3'tcp9\"127.0.0.1{16\"glowcap/features[1+]}>4:abcd>" ++
        "]ff>";
    // A sturdyref argument projects lazily, so the refusal lands when the
    // reference is read, not when the frame is framed.
    const refused_body = try syrup.decodeBody(.{ .bytes = refused, .shape = .byte });
    const refused_arg = try refused_body.deliver.args.at(0);
    try std.testing.expectError(error.MalformedView, refused_arg.reference.sturdy.project());
    const accepted: []const u8 =
        "<10'op:deliver<11'desc:export0+>[" ++
        "<15'ocapn-sturdyref<10'ocapn-peer3'tcp9\"127.0.0.1{1\"a1\"x}>4:abcd>" ++
        "]ff>";
    const body = try syrup.decodeBody(.{ .bytes = accepted, .shape = .byte });
    const arg = try body.deliver.args.at(0);
    const sturdy = try arg.reference.sturdy.project();
    try std.testing.expectEqualStrings("abcd", sturdy.swissnum);
}

test "a session refuses malformed reserved profile hints on the borrowed start-session path" {
    const allocator = std.testing.allocator;
    // A reserved name over a value the hint grammar knows reaches the
    // session, which refuses the meaning. A value of another shape is
    // refused by the decoder's hint walk, borrowed and owned alike.
    const hint_maps = .{
        .{ "{21\"glowcap/captp-version7\"ocapn-2}", glowcap.ocapn.session.Error.MalformedMessage },
        .{ "{13\"glowcap/codec3:bad}", glowcap.ocapn.session.Error.MalformedMessage },
        .{ "{16\"glowcap/features[1+]}", syrup.Error.MalformedFrame },
    };
    inline for (hint_maps) |case| {
        const hint_map = case[0];
        var peer = glowcap.ocapn.engine.Peer.initNegotiating(allocator);
        defer peer.deinit();
        peer.verify_partner_handshake = false;

        const frame_bytes: []const u8 =
            "<16'op:start-session3\"1.0" ++
            "[10'public-key[3'ecc[5'curve7'Ed25519][5'flags5'eddsa][1'q32:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA]]]" ++
            "<10'ocapn-peer3'tcp9\"127.0.0.1" ++ hint_map ++ ">" ++
            "[7'sig-val[5'eddsa[1'r32:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB][1's32:CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC]]]>";
        const view = glowcap.foundation.FrameView{ .bytes = frame_bytes, .shape = .byte };
        try std.testing.expectError(case[1], peer.recvBorrowed(view));
        try std.testing.expect(!peer.session_state.handshake_remote_received);
    }
}

test "Syrup decodes a start-session whose location carries non-empty hints" {
    // A real netlayer (the OCapN conformance suite's `tcp-testing-only`) puts the
    // address in the locator's hints map `{host …, port …}`. The decoder must
    // consume it so the whole frame decodes, and borrowed decode must expose the
    // entries through `BorrowedHints.lazy` (Cap'n Proto parity) so a Host can
    // dial without a separate re-parse. Goblins uses `#f` hints, so this shape
    // was unexercised until an external peer sent a hinted locator.
    const allocator = std.testing.allocator;
    const frame_bytes: []const u8 =
        "<16'op:start-session3\"1.0" ++
        "[10'public-key[3'ecc[5'curve7'Ed25519][5'flags5'eddsa][1'q32:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA]]]" ++
        "<10'ocapn-peer3'tcp9\"127.0.0.1{4\"host9\"127.0.0.14\"port5\"52833}>" ++
        "[7'sig-val[5'eddsa[1'r32:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB][1's32:CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC]]]>";
    const view = glowcap.foundation.FrameView{ .bytes = frame_bytes, .shape = .byte };
    const body = try syrup.decodeBody(view);
    try std.testing.expect(body == .start_session);
    try std.testing.expectEqualStrings("127.0.0.1", body.start_session.acceptable_location.designator);
    try std.testing.expect(body.start_session.acceptable_location.hints == .lazy);

    const owned = try body.toOwned(allocator);
    defer {
        allocator.free(owned.start_session.session_pubkey.bytes);
        allocator.free(owned.start_session.acceptable_location.transport);
        allocator.free(owned.start_session.acceptable_location.designator);
        model.freeHints(allocator, owned.start_session.acceptable_location.hints);
        allocator.free(owned.start_session.acceptable_location_sig.bytes);
    }
    try std.testing.expectEqual(@as(usize, 2), owned.start_session.acceptable_location.hints.entries.len);
    try std.testing.expectEqualStrings("host", owned.start_session.acceptable_location.hints.entries[0].name);
    try std.testing.expectEqualStrings("52833", owned.start_session.acceptable_location.hints.entries[1].value.string);
}

test "borrowed start-session decode refuses noncanonical hint order" {
    const entries = [_]model.HintEntry{
        .{ .name = "a", .value = .{ .string = "x" } },
        .{ .name = "b", .value = .{ .string = "y" } },
    };
    var frame = try syrup.encodeMessageForProfile(std.testing.allocator, .v1_0, .{
        .start_session = .{
            .captp_version = .v1_0,
            .session_pubkey = .{ .bytes = &repeatedByte(32, 0xaa) },
            .acceptable_location = .{
                .transport = "tcp",
                .designator = "x",
                .hints = .{ .entries = &entries },
            },
            .acceptable_location_sig = .{ .bytes = &repeatedByte(64, 0xbb) },
        },
    });
    defer frame.deinit();

    const canonical = "{1\"a1\"x1\"b1\"y}";
    const reversed = "{1\"b1\"y1\"a1\"x}";
    const at = std.mem.indexOf(u8, frame.bytes(), canonical) orelse return error.MissingHintMap;
    @memcpy(@constCast(frame.bytes())[at..][0..reversed.len], reversed);
    try std.testing.expectError(syrup.Error.MalformedFrame, syrup.decodeBody(frame.view()));
}

test "a hint map carries every value shape the hint grammar knows and skips the rest" {
    // A bounded integer, bytes, a string, and a boolean read whole. A list
    // is skipped, so it is absent on the owned form and malformed when asked
    // for by name, since a caller that names a hint reads meaning into it.
    const allocator = std.testing.allocator;
    const frame_bytes: []const u8 =
        "<16'op:start-session3\"1.0" ++
        "[10'public-key[3'ecc[5'curve7'Ed25519][5'flags5'eddsa][1'q32:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA]]]" ++
        "<10'ocapn-peer3'tcp9\"127.0.0.1{3\"int5-3\"raw2:ab3\"strt4\"skip[1+]4\"text2\"hi}>" ++
        "[7'sig-val[5'eddsa[1'r32:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB][1's32:CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC]]]>";
    const view = glowcap.foundation.FrameView{ .bytes = frame_bytes, .shape = .byte };
    const body = try syrup.decodeBody(view);
    const hints = body.start_session.acceptable_location.hints;
    try hints.validateShape();
    try std.testing.expectEqual(@as(i64, -5), (try hints.findNamed("int")).?.integer);
    try std.testing.expectEqualStrings("ab", (try hints.findNamed("raw")).?.bytes);
    try std.testing.expectEqual(true, (try hints.findNamed("str")).?.boolean);
    try std.testing.expectEqualStrings("hi", (try hints.findNamed("text")).?.string);
    try std.testing.expectError(error.MalformedView, hints.findNamed("skip"));
    try std.testing.expect((try hints.findNamed("none")) == null);

    const owned = try body.toOwned(allocator);
    defer {
        allocator.free(owned.start_session.session_pubkey.bytes);
        allocator.free(owned.start_session.acceptable_location.transport);
        allocator.free(owned.start_session.acceptable_location.designator);
        model.freeHints(allocator, owned.start_session.acceptable_location.hints);
        allocator.free(owned.start_session.acceptable_location_sig.bytes);
    }
    const entries = owned.start_session.acceptable_location.hints.entries;
    try std.testing.expectEqual(@as(usize, 4), entries.len);
    try std.testing.expectEqualStrings("int", entries[0].name);
    try std.testing.expectEqualStrings("text", entries[3].name);
}
