const std = @import("std");

const model = @import("model");
const net = @import("net");
const backend = @import("backend.zig");
const locators = @import("locators.zig");

/// OCapN locator mapped to an iroh `ConnectTarget` for `completion.Loop`.
/// Canonical node-id shape is refused here so `dialLocator` / blocking dial
/// fail before the network or sidecar admission is touched.
pub const DialResolver = struct {
    pub fn resolve(
        candidate: model.PeerLocator,
    ) !backend.CompletionBackend(net.Backend).ConnectTarget {
        return .{ .iroh = try locators.resolveConnectTarget(candidate) };
    }
};

/// Dial resolver for an iroh completion adapter whose wrapped backend also
/// owns dialable transports. Iroh locators stay at this layer; every other
/// symbol delegates without translating its target or importing that
/// transport's policy here.
pub fn CompositeDialResolver(comptime Platform: type, comptime Delegate: type) type {
    return struct {
        pub fn resolve(
            candidate: model.PeerLocator,
        ) !backend.CompletionBackend(Platform).ConnectTarget {
            if (std.mem.eql(u8, candidate.transport, model.transport.iroh)) {
                return .{ .iroh = try locators.resolveConnectTarget(candidate) };
            }
            return .{ .platform = try Delegate.resolve(candidate) };
        }
    };
}
