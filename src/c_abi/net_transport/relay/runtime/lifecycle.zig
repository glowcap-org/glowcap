//! Transactional construction and deterministic release of the Mbed TLS relay runtime.
//!
//! All borrowed C views and declarative trust policy are validated before
//! trust-store I/O. The TLS owner transfers only when the resident carrier is
//! admitted. Every earlier refusal closes what construction acquired. status-allow: event or source ordering

const std = @import("std");

const foundation = @import("foundation");
const net = @import("net");
const relay_tls = @import("relay_tls");
const c = @import("c_abi_shared");
const contract = @import("../contract.zig");

const Config = contract.GlowcapRelayConfig;
const Profile = contract.Profile;

pub fn create(
    comptime Payload: type,
    allocator: std.mem.Allocator,
    config: ?*const Config,
    slot: *?*Payload,
) i32 {
    slot.* = null;
    const cfg = config orelse return c.GLOWCAP_ERR_NULL_POINTER;
    if (cfg.abi_version != contract.GLOWCAP_RELAY_CONFIG_ABI_VERSION) {
        c.setLastError("relay runtime_new: unsupported config ABI version {d}", .{cfg.abi_version});
        return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    }
    if (cfg.struct_size != @sizeOf(Config)) {
        c.setLastError("relay runtime_new: config size {d}, expected {d}", .{
            cfg.struct_size,
            @sizeOf(Config),
        });
        return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    }
    const relay_url = c.sliceFromC(cfg.relay_url, cfg.relay_url_len) catch |err| {
        c.setLastError("relay runtime_new: invalid relay_url view: {s}", .{@errorName(err)});
        return c.marshalErrorToCode(err);
    };
    const register_url = c.sliceFromC(cfg.register_url, cfg.register_url_len) catch |err| {
        c.setLastError("relay runtime_new: invalid register_url view: {s}", .{@errorName(err)});
        return c.marshalErrorToCode(err);
    };
    if (relay_url.len == 0) {
        c.setLastError("relay runtime_new: relay_url must not be empty", .{});
        return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    }
    const relay_alias_url = c.sliceFromC(cfg.relay_alias_url, cfg.relay_alias_url_len) catch |err| {
        c.setLastError("relay runtime_new: invalid relay_alias_url view: {s}", .{@errorName(err)});
        return c.marshalErrorToCode(err);
    };
    const configuration: net.relay.Configuration = .{
        .relay_url = relay_url,
        .register_url = if (register_url.len == 0) null else register_url,
        .relay_alias_url = if (relay_alias_url.len == 0) null else relay_alias_url,
    };
    configuration.validate() catch {
        c.setLastError("relay runtime_new: invalid or mismatched relay URL", .{});
        return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    };
    const trust = relayTrust(cfg) orelse return c.GLOWCAP_ERR_INVALID_ARGUMENT;

    const payload = allocator.create(Payload) catch |err|
        return c.failInternal("relay runtime_new", err);
    payload.threaded = std.Io.Threaded.init(allocator, .{});
    payload.allocator = allocator;
    payload.references = .init(1);
    switch (payload.relay.init(
        payload.io(),
        allocator,
        configuration,
        trust,
    )) {
        .ready => {},
        .failed => |failure| {
            payload.threaded.deinit();
            allocator.destroy(payload);
            return failInitialization(failure);
        },
    }
    payload.runtime.init(payload) catch |err| {
        var failure = foundation.FailureChain.init(err);
        if (payload.relay.deinit()) |cleanup| failure.noteChain(cleanup);
        payload.threaded.deinit();
        allocator.destroy(payload);
        c.setLastErrorChain("relay runtime_new scheduler", failure);
        return c.GLOWCAP_ERR_INTERNAL;
    };
    payload.initProvider();
    slot.* = payload;
    return c.GLOWCAP_OK;
}

pub fn release(payload: anytype) ?foundation.FailureChain {
    if (payload.references.fetchSub(1, .acq_rel) != 1) return null;
    var failure = payload.runtime.deinit();
    if (payload.relay.deinit()) |cleanup| {
        if (failure) |*primary|
            primary.noteChain(cleanup)
        else
            failure = cleanup;
        // The callback lease is consumed, but the carrier refused its final
        // barrier. Keep every backing allocation pinned: freeing a busy TLS
        // owner would turn teardown failure into use-after-free in a survivor.
        return failure;
    }
    payload.threaded.deinit();
    payload.allocator.destroy(payload);
    return failure;
}

fn relayTrust(cfg: *const Config) ?relay_tls.Trust {
    return switch (cfg.trust) {
        contract.GLOWCAP_RELAY_TRUST_SYSTEM => if (cfg.trust_pem == null and cfg.trust_pem_len == 0)
            .system
        else invalid: {
            c.setLastError("relay runtime_new: system trust cannot carry PEM bytes", .{});
            break :invalid null;
        },
        contract.GLOWCAP_RELAY_TRUST_COPIED_PEM => copied: {
            const pem = c.sliceFromC(cfg.trust_pem, cfg.trust_pem_len) catch {
                c.setLastError("relay runtime_new: copied PEM has an invalid byte view", .{});
                break :copied null;
            };
            if (pem.len == 0) {
                c.setLastError("relay runtime_new: copied PEM must not be empty", .{});
                break :copied null;
            }
            break :copied .{ .copied_pem = pem };
        },
        else => invalid: {
            c.setLastError("relay runtime_new: unknown trust policy {d}", .{cfg.trust});
            break :invalid null;
        },
    };
}

fn failInitialization(failure: relay_tls.InitFailure) i32 {
    const chain = failure.chain();
    const code = switch (chain.cause) {
        error.InvalidTrustSnapshot => c.GLOWCAP_ERR_INVALID_ARGUMENT,
        error.SystemTrustUnavailable, error.InvalidSystemTrustStore => c.GLOWCAP_ERR_IO,
        error.InvalidRelayUrl => c.GLOWCAP_ERR_INVALID_ARGUMENT,
        else => c.GLOWCAP_ERR_INTERNAL,
    };
    switch (failure) {
        .tls => |tls| if (chain.secondaryName()) |secondary| {
            c.setLastError("relay TLS initialization ({s}): {s}; consequence: {s}; engine code {?d}", .{
                @tagName(tls.phase),
                chain.primaryName(),
                secondary,
                tls.detail.engine_code,
            });
        } else {
            c.setLastError("relay TLS initialization ({s}): {s}; engine code {?d}", .{
                @tagName(tls.phase),
                chain.primaryName(),
                tls.detail.engine_code,
            });
        },
        .relay => c.setLastErrorChain("relay runtime_new", chain.*),
    }
    return code;
}
