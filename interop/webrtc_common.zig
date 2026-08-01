//! The shared WebRTC interop signaling core (ADR-0089): the one signaling-inbox
//! actor and the one channel-bring-up client that `webrtc-signaling-captp` and
//! the WebRTC CapTP signaling drivers share. It lives here so those drivers
//! are thin callers of one spine rather than two byte-identical copies of it.
//!
//! The inbox holds an exporter's sidecar peer and answers three verbs so a
//! recipient can bring up the DataChannel through capability calls before the
//! keyed handshake: `offer(sdp)` returns the exporter's SDP answer, `candidate`
//! applies one trickled ICE candidate, and `poll` returns the exporter's next
//! locally gathered candidate (or ""). Channel establishment is driven through
//! the resident readiness fd; no native driver uses the old parked open wait.

const std = @import("std");
const pancake = @import("pancake");
const webrtc = @import("webrtc");

const model = pancake.ocapn.model;
const actors = pancake.actors;
const driver = pancake.driver;

/// The signaling session's frame cap: an SDP offer/answer is a few KiB, larger
/// than the keyed session's frames, so the signaling session sizes up for it.
pub const sig_frame_cap: usize = 16 * 1024;

pub fn pollOpen(resident: *webrtc.Resident, peer: *webrtc.Peer, timeout_ms: i32) !bool {
    var events: [16]webrtc.ReadyEvent = undefined;
    const count = try resident.pollReady(&events, timeout_ms);
    for (events[0..count]) |event| {
        if (event.subject != @intFromEnum(peer.id())) return error.UnexpectedReadySubject;
    }
    peer.checkOpen() catch |err| return switch (err) {
        error.WouldBlock => false,
        error.Closed => error.ChannelClosed,
    };
    return true;
}

pub fn waitOpen(resident: *webrtc.Resident, peer: *webrtc.Peer, timeout_ms: usize) !void {
    var elapsed: usize = 0;
    while (elapsed < timeout_ms) : (elapsed += 50) {
        if (try pollOpen(resident, peer, 50)) return;
    }
    return error.ChannelBringUpTimeout;
}

pub fn strArg(a: model.Argument) ?[]const u8 {
    return switch (a) {
        .string => |s| s,
        else => null,
    };
}

/// The exporter's signaling inbox, hosted over CapTP: it holds the exporter's
/// sidecar peer and answers `offer` / `candidate` / `poll` by driving it. The
/// answer and candidate bytes are returned from buffers the actor owns, so they
/// outlive the turn that produced them (the serve path copies the reply onto the
/// wire before the next turn overwrites the buffer).
pub const SignalingInbox = struct {
    peer: *webrtc.Peer,
    answer_buf: [sig_frame_cap]u8 = undefined,
    cand_buf: [4 * 1024]u8 = undefined,

    pub fn handle(self: *SignalingInbox, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (std.mem.eql(u8, msg.verb, "offer")) {
            if (msg.args.len != 1) return error.BadSignalingCall;
            const sdp = strArg(msg.args[0]) orelse return error.BadSignalingCall;
            try self.peer.setRemoteOffer(sdp);
            var len: usize = 0;
            return .{ .string = try self.peer.createAnswer(&self.answer_buf, &len) };
        }
        if (std.mem.eql(u8, msg.verb, "candidate")) {
            if (msg.args.len != 1) return error.BadSignalingCall;
            try self.peer.addRemoteCandidate(strArg(msg.args[0]) orelse return error.BadSignalingCall);
            return .{ .string = "" };
        }
        if (std.mem.eql(u8, msg.verb, "poll")) {
            var len: usize = 0;
            if (try self.peer.nextLocalCandidate(&self.cand_buf, &len)) |ice| return .{ .string = ice };
            return .{ .string = "" };
        }
        return error.NoSuchMethod;
    }
};

/// Bring the offerer's DataChannel up through the exporter's signaling inbox over
/// CapTP: send the offer, set the answer, then trickle local candidates with
/// `candidate` and pull the exporter's with `poll` until the channel opens.
pub fn bringUpViaCapTP(sig: *driver.BlockingSession, inbox: actors.Ref, resident: *webrtc.Resident, offerer: *webrtc.Peer, allocator: std.mem.Allocator) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sdp_buf: [sig_frame_cap]u8 = undefined;
    var cand_buf: [4 * 1024]u8 = undefined;
    var len: usize = 0;

    const offer_sdp = try offerer.createOffer(&sdp_buf, &len);
    const answered = try sig.call(inbox, .{ .verb = "offer", .args = &.{.{ .string = offer_sdp }} }, arena);
    switch (answered) {
        .fulfilled => |arg| try offerer.setRemoteAnswer(strArg(arg) orelse return error.NoAnswer),
        .broken, .give => return error.OfferBroke,
    }

    var rounds: usize = 0;
    while (rounds < 400) : (rounds += 1) {
        _ = arena_state.reset(.retain_capacity);
        while (try offerer.nextLocalCandidate(&cand_buf, &len)) |ice| {
            _ = try sig.call(inbox, .{ .verb = "candidate", .args = &.{.{ .string = ice }} }, arena);
        }
        const polled = try sig.call(inbox, .{ .verb = "poll", .args = &.{} }, arena);
        switch (polled) {
            .fulfilled => |arg| {
                const ice = strArg(arg) orelse "";
                if (ice.len > 0) try offerer.addRemoteCandidate(ice);
            },
            .broken, .give => return error.PollBroke,
        }
        if (try pollOpen(resident, offerer, 50)) return;
    }
    return error.ChannelBringUpTimeout;
}
