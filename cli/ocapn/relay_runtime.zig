//! Process-owned Mbed TLS relay construction and deterministic close reporting.

const std = @import("std");
const glowcap = @import("glowcap");
const relay_tls = @import("relay_tls");
const Ctx = @import("../ctx.zig").Ctx;

const RelayOptions = glowcap.driver.Transports.RelayOptions;

/// The relay a CLI runtime dials through and, for a listener, registers at:
/// the deployment URLs and the TLS runtime the relay backend leases. URLs are
/// borrowed from argv or the environment, which outlive the process's runtimes.
pub const Provider = struct {
    relay_url: []const u8,
    register_url: ?[]const u8,
    tls: glowcap.net.tls.runtime_owner.Owner,

    pub fn options(self: *const Provider, io: std.Io) !RelayOptions {
        var entropy: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
        try io.randomSecure(&entropy);
        return .{
            .url = self.relay_url,
            .entropy_seed = entropy,
            .resolver_io = io,
            .tls_owner = self.tls,
            .registration = if (self.register_url) |url| .{ .url = url } else null,
        };
    }

    /// Retryable: refused while a runtime still leases the TLS runtime.
    pub fn deinit(self: *Provider) ?FailureChain {
        switch (self.tls.release()) {
            .released => {},
            .busy => return .init(error.RelayTlsStillLeased),
            .failed => |failure| return failure,
        }
        self.* = undefined;
        return null;
    }
};
pub const FailureChain = glowcap.foundation.FailureChain;

pub fn init(
    ctx: *Ctx,
    provider: *Provider,
    relay_url: []const u8,
    register_url: ?[]const u8,
) !void {
    var trust_pem: ?[]u8 = null;
    defer if (trust_pem) |pem| ctx.gpa.free(pem);
    const trust: relay_tls.Trust = if (ctx.environ.get("GLOWCAP_RELAY_CA_FILE")) |path| copied: {
        if (path.len == 0) {
            ctx.logErr("GLOWCAP_RELAY_CA_FILE names no file", .{});
            return error.RelayTrustReadFailed;
        }
        trust_pem = std.Io.Dir.cwd().readFileAlloc(
            ctx.io,
            path,
            ctx.gpa,
            .limited(relay_tls.max_trust_bytes),
        ) catch |err| {
            ctx.logErr("cannot read relay CA file {s}: {s}", .{ path, @errorName(err) });
            return error.RelayTrustReadFailed;
        };
        break :copied .{ .copied_pem = trust_pem.? };
    } else .system;
    glowcap.net.relay.validateConfigurationUrls(relay_url, register_url orelse "") catch
        return error.InvalidRendezvousUrl;
    switch (relay_tls.initTlsOwner(ctx.io, ctx.gpa, trust)) {
        .ready => |ready| provider.* = .{ .relay_url = relay_url, .register_url = register_url, .tls = ready.owner },
        .failed => |failure| {
            const chain = failure.chain();
            ctx.logErr(
                "relay initialization: {s} (and {d} later failure(s))",
                .{ chain.primaryName(), chain.secondary_count },
            );
            return switch (chain.cause) {
                error.InvalidRelayUrl => error.InvalidRendezvousUrl,
                error.OutOfMemory => error.OutOfMemory,
                else => error.RelayInitializationFailed,
            };
        },
    }
}

/// Join the provider's retryable owner barrier. A returned failure means the
/// provider remains live and the caller still owns the right to retry. Callers
/// must not clear or move its storage in that case.
pub fn deinitAndReport(ctx: *Ctx, provider: *Provider) ?FailureChain {
    const failure = provider.deinit() orelse return null;
    ctx.logErr(
        "relay cleanup: {s} (and {d} later failure(s))",
        .{ failure.primaryName(), failure.secondary_count },
    );
    return failure;
}
