//! Answer the bootstrap request an accepted deliver carried, once authority
//! has recorded the deliver itself (ADR-0002 responder half).

const engine = @import("../mod.zig");
const Peer = engine.Peer;
const bootstrap = @import("../bootstrap.zig");
const outbound = @import("../outbound.zig");

/// A fetch answers from the swissnum table, a deposit records the gift and
/// answers, and a withdraw settles now or parks until its deposit lands on
/// the gifter's session.
pub fn apply(self: *Peer, action: bootstrap.Request) !void {
    const scope = self.peerHandleScope();
    switch (action) {
        .fetch => |req| {
            if (try bootstrap.resolveForSwissnum(&self.session_state, self.localObjectProjection(), scope, req)) |resolution|
                try outbound.enqueueAnswerResolutionOwned(self, req.answer, resolution);
        },
        .deposit_gift => |req| {
            try bootstrap.resolveForDeposit(&self.session_state, self.giftRegistry(), self.localObjectProjection(), scope, req);
            if (self.node_services) |services| services.giftDeposited(req.gift_id);
            if (req.answer) |answer|
                try outbound.enqueueAnswerResolutionOwned(self, answer, .{ .fulfill = .{ .void = {} } });
        },
        .withdraw_gift => |req| {
            if (self.pendingWithdrawCount() >= @as(usize, self.session_state.limits.max_pending_withdraws)) {
                const gifter = bootstrap.liveGifterSession(self.gifterSessionResolver(), req.receive.signed_give);
                if (gifter == null or !gifter.?.gifts.giftLive(req.receive.signed_give.gift_id)) {
                    return error.PendingWithdrawCapExceeded;
                }
            }
            switch (try bootstrap.resolveForWithdraw(self.allocator, &self.session_state, self.giftRegistry(), self.gifterSessionResolver(), self.localObjectProjection(), scope, req)) {
                .settled => |msg| try self.sendWithdrawSettled(msg),
                // The gift's deposit has not arrived yet (it travels on
                // a different session); park the withdraw, `step`
                // settles it once the deposit lands.
                .awaiting_deposit => |admission| {
                    var receive = admission.receive;
                    errdefer receive.deinit(self.allocator);
                    try self.parkPendingWithdraw(receive, req.answer, admission.gifter_peer_handle);
                },
            }
        },
    }
}
