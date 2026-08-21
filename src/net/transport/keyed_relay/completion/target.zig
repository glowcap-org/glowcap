//! Locator resolution for the completion-backed relay transport.
//!
//! This module selects the relay target. The completion backend owns channel
//! acquisition and WebSocket I/O after resolution.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const tcp = @import("../../tcp.zig");
const route = @import("../route.zig");

const crypto = foundation.crypto;
const transport_name = model.transport.keyed_relay;

/// Dial target for a completion loop that can keep ordinary TCP and relay
/// outbound dials in one `driver.Bridge`.
pub const LoopConnectTarget = union(enum) {
    tcp: std.Io.net.IpAddress,
    keyed_relay: struct {
        designator: []const u8,
        relay: ?route.RelayUrl,
    },
};

/// Locator grammar for a relay completion loop. The deployment relay URL is
/// backend configuration rather than locator identity; a validated route hint
/// may select a different relay for one dial.
pub const DialResolver = struct {
    pub fn resolve(locator: model.PeerLocator) tcp.Error!LoopConnectTarget {
        if (std.mem.eql(u8, locator.transport, transport_name)) {
            if (crypto.PeerKey.fromDesignator(locator.designator) == null)
                return error.InvalidAddress;
            return .{ .keyed_relay = .{
                .designator = locator.designator,
                .relay = route.relayHint(locator.hints) catch return error.InvalidAddress,
            } };
        }
        return .{ .tcp = try tcp.DialResolver.resolve(locator) };
    }
};
