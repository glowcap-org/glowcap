//! Optional native composition of Pancake's TLS contract with Mbed TLS.
//!
//! This is the only module that knows both names. Native relay initializers
//! select trust policy here, then retain only the transport-neutral runtime.

const std = @import("std");

const mbedtls = @import("mbedtls");
const net = @import("net");

pub const Trust = union(enum) {
    system,
    copied_pem: []const u8,
};

pub const TrustSummary = mbedtls.TrustSummary;
pub const max_trust_bytes = mbedtls.max_trust_bytes;

pub const Ready = struct {
    runtime: net.tls.runtime.Runtime,
    trust: TrustSummary,
};

pub const InitOutcome = union(enum) {
    ready: Ready,
    failed: net.tls.engine.Failure,
};

/// Initialize one immutable native TLS runtime. Refusal consumes no caller
/// input; success owns its copied/system trust independently of `trust`.
pub fn init(
    io: std.Io,
    allocator: std.mem.Allocator,
    trust: Trust,
) InitOutcome {
    const initialized = switch (trust) {
        .system => mbedtls.Runtime.initSystemRoots(io, allocator),
        .copied_pem => |pem| mbedtls.Runtime.initCopiedRoots(io, allocator, pem),
    };
    return switch (initialized) {
        .runtime => |ready| .{ .ready = .{
            .runtime = ready.owner.intoRuntime(),
            .trust = ready.trust,
        } },
        .failed => |failure| .{ .failed = failure },
    };
}
