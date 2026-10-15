//! The signaling this program carries between its two netlayers. Both sides
//! are managed: the offerer's provider runs the dial (ADR-0226) and the
//! answerer's provider runs the accept (ADR-0232). The callbacks store each
//! text here, and `carry` hands it across once per round of the main loop,
//! which is all an application does when both ends are in one process.

const std = @import("std");

const cs = @import("c_abi_shared");
const cw = @import("c_abi_net_transport_webrtc");

const signal_cap: usize = cw.GLOWCAP_WEBRTC_MAX_SIGNAL_BYTES;
const candidate_cap: usize = 1024;
const max_candidates: usize = 32;

pub fn expectOk(rc: i32) !void {
    if (rc == cs.GLOWCAP_OK) return;
    var message: [512]u8 = undefined;
    const len = cw.glowcap_webrtc_last_error(&message, message.len);
    if (len != 0) {
        std.debug.print("webrtc-driver-provider: webrtc error {d}: {s}\n", .{ rc, message[0..@min(len, message.len - 1)] });
    }
    return error.CAbiCallFailed;
}

/// Candidates one side produced and the other has not taken yet.
const Candidates = struct {
    texts: [max_candidates][candidate_cap]u8 = undefined,
    lens: [max_candidates]usize = undefined,
    count: usize = 0,

    fn push(self: *Candidates, ice: ?[*]const u8, ice_len: usize) i32 {
        if (self.count == max_candidates or ice_len > candidate_cap) return -1;
        @memcpy(self.texts[self.count][0..ice_len], ice.?[0..ice_len]);
        self.lens[self.count] = ice_len;
        self.count += 1;
        return 0;
    }

    /// Hand every stored candidate to `exchange` on `netlayer`.
    fn drainInto(self: *Candidates, netlayer: ?*cw.GlowcapWebrtcNetlayer, exchange: u64) !void {
        for (self.texts[0..self.count], self.lens[0..self.count]) |*text, len| {
            try expectOk(cw.glowcap_webrtc_netlayer_provide_candidate(netlayer, exchange, text, len));
        }
        self.count = 0;
    }
};

/// The offerer's signaling. A dial to the answerer's key is carried. A dial
/// to any other key is accepted and never answered.
pub const Carrier = struct {
    answerer_designator: *const [64]u8,
    /// The exchange dialing the answerer, from its offer until `done`.
    exchange: ?u64 = null,
    offer: [signal_cap]u8 = undefined,
    offer_len: usize = 0,
    offer_pending: bool = false,
    candidates: Candidates = .{},
    /// The exchange dialing the key nobody answers.
    absent_exchange: ?u64 = null,
    done_exchanges: [2]u64 = .{ 0, 0 },
    done_count: usize = 0,

    pub fn signaling(self: *Carrier) cw.GlowcapWebrtcSignaling {
        return .{ .ctx = self, .send_offer = sendOffer, .send_answer = null, .send_candidate = sendCandidate, .done = done };
    }

    fn sendOffer(ctx: ?*anyopaque, exchange: u64, designator: ?[*]const u8, designator_len: usize, introducer: ?[*]const u8, introducer_len: usize, sdp: ?[*]const u8, sdp_len: usize) callconv(.c) i32 {
        const self: *Carrier = @ptrCast(@alignCast(ctx.?));
        // This process dials on its own, so no session introduced the peer.
        if (introducer != null or introducer_len != 0) return -1;
        if (!std.mem.eql(u8, designator.?[0..designator_len], self.answerer_designator)) {
            self.absent_exchange = exchange;
            return 0;
        }
        if (self.exchange != null or sdp_len > self.offer.len) return -1;
        self.exchange = exchange;
        @memcpy(self.offer[0..sdp_len], sdp.?[0..sdp_len]);
        self.offer_len = sdp_len;
        self.offer_pending = true;
        return 0;
    }

    fn sendCandidate(ctx: ?*anyopaque, exchange: u64, ice: ?[*]const u8, ice_len: usize) callconv(.c) i32 {
        const self: *Carrier = @ptrCast(@alignCast(ctx.?));
        if (exchange != self.exchange) return 0;
        return self.candidates.push(ice, ice_len);
    }

    fn done(ctx: ?*anyopaque, exchange: u64) callconv(.c) void {
        const self: *Carrier = @ptrCast(@alignCast(ctx.?));
        if (self.done_count < self.done_exchanges.len) self.done_exchanges[self.done_count] = exchange;
        self.done_count += 1;
        if (exchange == self.exchange) self.exchange = null;
    }
};

/// The answerer's signaling. The answer and candidates the provider sends
/// under the accept exchange wait here for the next `carry`.
pub const Acceptor = struct {
    offerer_designator: *const [64]u8,
    /// The accept exchange, from the answer until `done`.
    exchange: ?u64 = null,
    answer: [signal_cap]u8 = undefined,
    answer_len: usize = 0,
    answer_pending: bool = false,
    candidates: Candidates = .{},
    done_count: usize = 0,

    pub fn signaling(self: *Acceptor) cw.GlowcapWebrtcSignaling {
        return .{ .ctx = self, .send_offer = null, .send_answer = sendAnswer, .send_candidate = sendCandidate, .done = done };
    }

    fn sendAnswer(ctx: ?*anyopaque, exchange: u64, designator: ?[*]const u8, designator_len: usize, sdp: ?[*]const u8, sdp_len: usize) callconv(.c) i32 {
        const self: *Acceptor = @ptrCast(@alignCast(ctx.?));
        // The answer goes back to the designator the offer came with.
        if (!std.mem.eql(u8, designator.?[0..designator_len], self.offerer_designator)) return -1;
        if (self.exchange != null or sdp_len > self.answer.len) return -1;
        self.exchange = exchange;
        @memcpy(self.answer[0..sdp_len], sdp.?[0..sdp_len]);
        self.answer_len = sdp_len;
        self.answer_pending = true;
        return 0;
    }

    fn sendCandidate(ctx: ?*anyopaque, exchange: u64, ice: ?[*]const u8, ice_len: usize) callconv(.c) i32 {
        const self: *Acceptor = @ptrCast(@alignCast(ctx.?));
        if (exchange != self.exchange) return -1;
        return self.candidates.push(ice, ice_len);
    }

    fn done(ctx: ?*anyopaque, exchange: u64) callconv(.c) void {
        const self: *Acceptor = @ptrCast(@alignCast(ctx.?));
        self.done_count += 1;
        if (exchange == self.exchange) self.exchange = null;
    }
};

/// One round of carrying: the offer to the answerer's netlayer, which
/// answers inside the call, the answer back to the offerer's exchange, and
/// each side's candidates to the other's exchange.
pub fn carry(
    carrier: *Carrier,
    acceptor: *Acceptor,
    offerer_netlayer: ?*cw.GlowcapWebrtcNetlayer,
    answerer_netlayer: ?*cw.GlowcapWebrtcNetlayer,
) !void {
    if (carrier.offer_pending) {
        carrier.offer_pending = false;
        var accept_exchange: u64 = 0;
        try expectOk(cw.glowcap_webrtc_netlayer_provide_offer(
            answerer_netlayer,
            acceptor.offerer_designator,
            acceptor.offerer_designator.len,
            &carrier.offer,
            carrier.offer_len,
            &accept_exchange,
        ));
        if (acceptor.exchange != accept_exchange) return error.AnswerSentUnderAnotherExchange;
    }
    if (acceptor.answer_pending) {
        acceptor.answer_pending = false;
        try expectOk(cw.glowcap_webrtc_netlayer_provide_answer(offerer_netlayer, carrier.exchange.?, &acceptor.answer, acceptor.answer_len));
    }
    if (acceptor.exchange) |exchange| try carrier.candidates.drainInto(answerer_netlayer, exchange);
    if (carrier.exchange) |exchange| try acceptor.candidates.drainInto(offerer_netlayer, exchange);
}
