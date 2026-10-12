//! `webrtc` as the transport policy `net.completion_resident.Resident` takes
//! over `webrtc.Backend`.
//!
//! A WebRTC listener is the backend's signaling inbox, so it has no address.
//! Its locator is the identity a signaling authority admits dialers under,
//! the key of the Host it serves, and it carries no hints: a dialer reaches
//! it through its own configured signaling, never through the locator.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const net = @import("net");
const signaling = @import("backend/signaling.zig");

const crypto = foundation.crypto;

pub fn ResidentPolicy(comptime Backend: type) type {
    return struct {
        fn isWebrtc(transport: []const u8) bool {
            return std.mem.eql(u8, transport, model.transport.webrtc);
        }

        pub fn resolve(locator: model.PeerLocator) !Backend.ConnectTarget {
            return signaling.DialResolver.resolve(locator);
        }

        /// Empty asks for the Host's key. Anything else must be it.
        pub fn listenTarget(_: *const Backend, transport: []const u8, config: net.netlayer.ListenConfig) !Backend.ListenTarget {
            if (!isWebrtc(transport)) return error.UnknownTransport;
            const identity = config.identity orelse return error.InvalidAddress;
            if (config.designator.len != 0 and !std.mem.eql(u8, config.designator, &identity.toDesignator()))
                return error.InvalidAddress;
        }

        pub fn localLocator(
            _: *Backend,
            _: Backend.Fd,
            transport: []const u8,
            identity: ?crypto.PeerKey,
            allocator: std.mem.Allocator,
        ) !model.PeerLocator {
            const designator = (identity orelse return error.InvalidAddress).toDesignator();
            return model.clonePeerLocator(allocator, .{
                .transport = transport,
                .designator = &designator,
                .hints = model.Hints.emptyFalse(),
            });
        }

        /// The listener answers only to its Host's key.
        pub fn canonicalizeLocator(
            _: *Backend,
            _: Backend.Fd,
            transport: []const u8,
            identity: ?crypto.PeerKey,
            allocator: std.mem.Allocator,
            candidate: model.PeerLocator,
        ) !model.PeerLocator {
            model.validatePeerLocator(candidate) catch return error.InvalidAddress;
            const expected = (identity orelse return error.InvalidAddress).toDesignator();
            if (!std.mem.eql(u8, candidate.transport, transport) or !std.mem.eql(u8, candidate.designator, &expected))
                return error.InvalidAddress;
            return model.clonePeerLocator(allocator, candidate);
        }
    };
}
