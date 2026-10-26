//! The contract between the WebRTC resident and the Rust library behind it:
//! a length the library reports for an offer, an answer, or a candidate is
//! held to the buffer the resident offered, and a longer one is refused
//! `SignalFailed` instead of read.

const std = @import("std");
const webrtc = @import("webrtc");
const stub = @import("webrtc_sidecar_stub.zig");

fn resetSignalStub() void {
    stub.create_offer_result = -2;
    stub.create_answer_result = -2;
    stub.create_signal_len = 0;
    stub.candidate_bytes_to_emit = 0;
    stub.candidate_ok_past_cap = false;
}

test "webrtc signal verbs refuse an ok result longer than the buffer they offered" {
    defer resetSignalStub();
    var peer: webrtc.Peer = .{ .peer = @ptrFromInt(104) };
    var small: [64]u8 = undefined;
    // Wider than the cap, so the buffer offered is the cap and not the caller's.
    var wide: [webrtc.max_signal_bytes + 8]u8 = undefined;
    var out_len: usize = 0;

    stub.create_offer_result = 0;
    stub.create_signal_len = small.len + 1;
    try std.testing.expectError(error.SignalFailed, peer.createOffer(&small, &out_len));
    stub.create_signal_len = webrtc.max_signal_bytes + 1;
    try std.testing.expectError(error.SignalFailed, peer.createOffer(&wide, &out_len));
    stub.create_signal_len = small.len;
    try std.testing.expectEqual(small.len, (try peer.createOffer(&small, &out_len)).len);

    stub.create_answer_result = 0;
    stub.create_signal_len = small.len + 1;
    try std.testing.expectError(error.SignalFailed, peer.createAnswer(&small, &out_len));
    stub.create_signal_len = webrtc.max_signal_bytes + 1;
    try std.testing.expectError(error.SignalFailed, peer.createAnswer(&wide, &out_len));

    stub.candidate_ok_past_cap = true;
    stub.candidate_bytes_to_emit = small.len + 1;
    try std.testing.expectError(error.SignalFailed, peer.nextLocalCandidate(&small, &out_len));
    stub.candidate_bytes_to_emit = webrtc.max_ice_candidate_bytes + 1;
    try std.testing.expectError(error.SignalFailed, peer.nextLocalCandidate(&wide, &out_len));
    stub.candidate_bytes_to_emit = small.len;
    const candidate = (try peer.nextLocalCandidate(&small, &out_len)) orelse return error.ExpectedCandidate;
    try std.testing.expectEqual(small.len, candidate.len);
}
