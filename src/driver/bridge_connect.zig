//! Owned correlation payload for one completion-loop outbound connect.
//!
//! Application dials retain the complete locator until Host adoption. The
//! transport resolver consumes the same locator at connect time, while the
//! Host consumes its profile knowledge only after the socket exists; keeping
//! one owned value prevents those two projections from drifting. Redeem dials
//! retain only their Node ticket because the Node row already owns that
//! locator until settlement.

const std = @import("std");

const engine = @import("engine");
const model = @import("model");

pub const OutboundConnect = union(enum) {
    app_dial: model.PeerLocator,
    redeem: engine.Node.PendingId,

    pub fn initApplication(
        allocator: std.mem.Allocator,
        locator: model.PeerLocator,
    ) std.mem.Allocator.Error!OutboundConnect {
        return .{ .app_dial = try model.clonePeerLocator(allocator, locator) };
    }

    pub fn deinit(self: OutboundConnect, allocator: std.mem.Allocator) void {
        switch (self) {
            .app_dial => |locator| model.freePeerLocator(allocator, locator),
            .redeem => {},
        }
    }
};
