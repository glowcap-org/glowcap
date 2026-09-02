//! Transactional construction of an onion runtime and its copied configuration.

const std = @import("std");
const c = @import("c_abi_shared");
const contract = @import("../contract.zig");
const provider = @import("../provider/mod.zig");
const state = @import("state.zig");

pub fn create(
    allocator: std.mem.Allocator,
    config: *const contract.GlowcapOnionConfig,
    out: *?*state.Netlayer,
) i32 {
    const total = sumLengths(&.{
        config.socks_len,
        config.control_endpoint_len,
        config.auth_secret_len,
        config.service_key_len,
        config.forward_len,
    }) orelse {
        c.setLastError("netlayer_new: copied configuration is too large", .{});
        return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    };
    const socks = viewOf(config.socks, config.socks_len) catch
        return invalid("netlayer_new: socks is null with a nonzero length");
    if (socks.len == 0)
        return invalid("netlayer_new: socks endpoint is required");
    const control = viewOf(config.control_endpoint, config.control_endpoint_len) catch
        return invalid("netlayer_new: control_endpoint is null with a nonzero length");
    const secret = viewOf(config.auth_secret, config.auth_secret_len) catch
        return invalid("netlayer_new: auth_secret is null with a nonzero length");
    const key = viewOf(config.service_key, config.service_key_len) catch
        return invalid("netlayer_new: service_key is null with a nonzero length");
    const forward = viewOf(config.forward, config.forward_len) catch
        return invalid("netlayer_new: forward is null with a nonzero length");
    if (config.auth_kind > contract.GLOWCAP_ONION_AUTH_PASSWORD) {
        c.setLastError("netlayer_new: unknown auth_kind {d}", .{config.auth_kind});
        return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    }

    const payload = allocator.create(state.Netlayer) catch |err|
        return c.failInternal("onion netlayer_new", err);
    const text = allocator.alloc(u8, total) catch |err| {
        allocator.destroy(payload);
        return c.failInternal("onion netlayer_new configuration copy", err);
    };
    var cursor: usize = 0;
    const socks_copy = take(text, &cursor, socks);
    const control_copy = take(text, &cursor, control);
    const secret_copy = take(text, &cursor, secret);
    const key_copy = take(text, &cursor, key);
    const forward_copy = take(text, &cursor, forward);

    payload.allocator = allocator;
    payload.text = text;
    payload.references = .init(1);
    payload.calls = .{};
    payload.failure_mutex = .{};
    payload.terminal_failure = null;
    payload.threaded = std.Io.Threaded.init(allocator, .{});
    payload.resident = .{
        .io = payload.threaded.io(),
        .config = .{
            .socks = socks_copy,
            .control_endpoint = control_copy,
            .auth = switch (config.auth_kind) {
                contract.GLOWCAP_ONION_AUTH_COOKIE => .{ .cookie = secret_copy },
                contract.GLOWCAP_ONION_AUTH_PASSWORD => .{ .password = secret_copy },
                else => .none,
            },
            .service_key = key_copy,
            .forward = forward_copy,
        },
    };
    payload.tasks.init(payload.resident.io) catch |err| {
        payload.threaded.deinit();
        allocator.free(text);
        allocator.destroy(payload);
        return c.failInternal("onion netlayer_new scheduler", err);
    };
    provider.init(payload);
    out.* = payload;
    return c.GLOWCAP_OK;
}

fn invalid(message: []const u8) i32 {
    c.setLastError("{s}", .{message});
    return c.GLOWCAP_ERR_INVALID_ARGUMENT;
}

fn viewOf(ptr: ?[*]const u8, len: usize) error{NullPointer}![]const u8 {
    const value = ptr orelse {
        if (len != 0) return error.NullPointer;
        return &.{};
    };
    return value[0..len];
}

fn sumLengths(parts: []const usize) ?usize {
    var total: usize = 0;
    for (parts) |part| total = std.math.add(usize, total, part) catch return null;
    return total;
}

fn take(block: []u8, cursor: *usize, bytes: []const u8) []const u8 {
    const start = cursor.*;
    @memcpy(block[start..][0..bytes.len], bytes);
    cursor.* = start + bytes.len;
    return block[start..][0..bytes.len];
}
