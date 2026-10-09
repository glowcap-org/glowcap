//! Select the CLI's direct TCP or relay listener transport.

const glowcap = @import("glowcap");
const ctx_mod = @import("../ctx.zig");
const relay_runtime = @import("relay_runtime.zig");

const Ctx = ctx_mod.Ctx;

pub const ListenTarget = struct {
    transports: glowcap.driver.Transports,
    transport: []const u8,
    designator: []const u8,
};

pub fn select(
    ctx: *Ctx,
    bind_designator: []const u8,
    register_url_opt: ?[]const u8,
    relay_url_opt: ?[]const u8,
    relay: *?relay_runtime.Provider,
) !ListenTarget {
    const register_url = register_url_opt orelse return .{
        .transports = .{ .symbols = &.{.tcp} },
        .transport = glowcap.ocapn.model.transport.tcp,
        .designator = bind_designator,
    };
    _ = glowcap.net.relay.RelayUrl.parse(register_url) catch {
        ctx.logErr("--rendezvous wants a ws:// or wss:// relay URL, got {s}", .{register_url});
        return error.Usage;
    };
    const dial_url = relay_url_opt orelse ctx.environ.get("GLOWCAP_RENDEZVOUS") orelse {
        ctx.logErr("--rendezvous requires --rendezvous-relay or GLOWCAP_RENDEZVOUS so its locator names a dialable route", .{});
        return error.Usage;
    };
    _ = glowcap.net.relay.RelayUrl.parse(dial_url) catch {
        ctx.logErr("{s} is not a ws:// or wss:// relay URL: {s}", .{
            if (relay_url_opt != null) "--rendezvous-relay" else "GLOWCAP_RENDEZVOUS",
            dial_url,
        });
        return error.Usage;
    };

    relay.* = @as(relay_runtime.Provider, undefined);
    relay_runtime.init(ctx, &relay.*.?, dial_url, register_url) catch |err| {
        relay.* = null;
        return err;
    };
    return .{
        .transports = .{ .symbols = &.{.keyed_relay}, .relay = try relay.*.?.options(ctx.io) },
        .transport = glowcap.ocapn.model.transport.keyed_relay,
        .designator = "",
    };
}
