//! Completion-loop Noise sealing (ADR-0107).
//!
//! Byte-fed sessions compose the responder channel in `HostSession`; this
//! facade exposes the independent initiator composition used by completion
//! backends. A sealed dial completes its Noise_XK handshake before connect is
//! published, and the verified responder key is available at that same edge.
//! Plain targets retain the wrapped backend's exact contract and cost.
//!
//! The implementation has one ownership direction: facade -> backend adapter
//! -> sealed reactor -> per-connection row. The reactor is embedded, so the
//! split adds no allocation, copy, scan, or second state view.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const backend = @import("noise_completion/backend.zig");

const crypto = foundation.crypto;

/// The locator designator scheme `noise-relay` shares with every sealed
/// symbol: the responder's durable Ed25519 key (ADR-0107).
pub const designator_scheme: model.transport.DesignatorScheme =
    model.transport.Known.noise_relay.metadata().designator_scheme;

/// Resolve `noise-relay` to a sealed dial over the inner resolver's
/// `keyed-relay` target. Every other transport remains a plain inner target.
pub fn DialResolver(comptime Backend: type, comptime InnerResolver: type) type {
    return struct {
        pub fn resolve(locator: model.PeerLocator) !Backend.ConnectTarget {
            if (std.mem.eql(u8, locator.transport, model.transport.noise_relay)) {
                const remote = crypto.PeerKey.fromDesignator(locator.designator) orelse
                    return error.InvalidAddress;
                return .{ .sealed = .{
                    .inner = try InnerResolver.resolve(.{
                        .transport = model.transport.keyed_relay,
                        .designator = locator.designator,
                        .hints = locator.hints,
                    }),
                    .remote = remote,
                    .transport = model.transport.noise_relay,
                } };
            }
            return .{ .plain = try InnerResolver.resolve(locator) };
        }
    };
}

/// A completion backend that seals `.sealed` dial targets and delegates every
/// plain operation to `Inner` without changing its bytes or handle identity.
pub fn CompletionBackend(comptime Inner: type) type {
    return backend.Backend(Inner);
}
