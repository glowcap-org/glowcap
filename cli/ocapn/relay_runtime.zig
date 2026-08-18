//! Process-owned native relay construction and deterministic close reporting.

const std = @import("std");
const pancake = @import("pancake");
const native_relay = @import("native_relay");
const Ctx = @import("../ctx.zig").Ctx;

pub const Provider = native_relay.Provider;
pub const FailureChain = pancake.foundation.FailureChain;

pub fn init(
    ctx: *Ctx,
    provider: *Provider,
    relay_url: []const u8,
    register_url: ?[]const u8,
) !void {
    var trust_pem: ?[]u8 = null;
    defer if (trust_pem) |pem| ctx.gpa.free(pem);
    const trust: native_relay.Trust = if (ctx.environ.get("PANCAKE_RELAY_CA_FILE")) |path| copied: {
        if (path.len == 0) {
            ctx.logErr("PANCAKE_RELAY_CA_FILE names no file", .{});
            return error.RelayTrustReadFailed;
        }
        trust_pem = std.Io.Dir.cwd().readFileAlloc(
            ctx.io,
            path,
            ctx.gpa,
            .limited(native_relay.max_trust_bytes),
        ) catch |err| {
            ctx.logErr("cannot read relay CA file {s}: {s}", .{ path, @errorName(err) });
            return error.RelayTrustReadFailed;
        };
        break :copied .{ .copied_pem = trust_pem.? };
    } else .system;
    switch (provider.init(ctx.io, ctx.gpa, relay_url, register_url, trust)) {
        .ready => {},
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
/// provider remains live and the caller still owns the right to retry; callers
/// must not clear or move its storage in that case.
pub fn deinitAndReport(ctx: *Ctx, provider: *Provider) ?FailureChain {
    const failure = provider.deinit() orelse return null;
    ctx.logErr(
        "relay cleanup: {s} (and {d} later failure(s))",
        .{ failure.primaryName(), failure.secondary_count },
    );
    return failure;
}
