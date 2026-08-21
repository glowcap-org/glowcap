//! Fixed provider-table and profile admission.
//!
//! This leaf validates borrowed C shapes without owning a package, adapter, or
//! runtime fact. Successful values remain borrowed until the registry copies
//! the policy it installs.

const std = @import("std");

const model = @import("model");
const net = @import("net");
const shared = @import("c_abi_shared");

const untouched_listen_state = std.math.maxInt(u32);

pub fn projectOperationOptions(
    options: net.OperationOptions,
    storage: *shared.PancakeTransportOperationOptions,
) ?*const shared.PancakeTransportOperationOptions {
    const data = options.data orelse return null;
    storage.* = .{ .data = data, .size = options.size };
    return storage;
}

pub fn multiplexedIoResultValid(result: isize, capacity: usize) bool {
    if (result == -1 or result == shared.PANCAKE_MULTIPLEXED_WOULD_BLOCK) return true;
    if (result < 0) return false;
    return @as(usize, @intCast(result)) <= capacity;
}

pub fn emptyListenResult() shared.PancakeListenResult {
    return .{
        .state = untouched_listen_state,
        .listener = null,
        .attempt = null,
        .readiness_fd = -1,
    };
}

pub fn listenResultUntouched(result: shared.PancakeListenResult) bool {
    return result.state == untouched_listen_state and
        result.listener == null and result.attempt == null and result.readiness_fd == -1;
}

pub fn operationGroup(any: bool, complete: bool, kind: []const u8) !bool {
    if (any != complete) {
        shared.setLastError("driver: provider has a partial {s} operation group", .{kind});
        return error.InvalidArgument;
    }
    return complete;
}

pub fn implementationTable(comptime T: type, raw: *const anyopaque, kind: []const u8) !*const T {
    if (@intFromPtr(raw) % @alignOf(T) != 0) {
        shared.setLastError("driver: {s} provider table is misaligned", .{kind});
        return error.InvalidArgument;
    }
    return @ptrCast(@alignCast(raw));
}

pub fn tablePrefix(comptime T: type, table: *const T, version: u32, kind: []const u8) !void {
    if (table.abi_version != version or table.struct_size < @sizeOf(T)) {
        shared.setLastError("driver: {s} provider has an unsupported ABI", .{kind});
        return error.InvalidArgument;
    }
}

pub fn transportProfile(profile: *const shared.PancakeTransportProfile) !model.transport.Metadata {
    if (profile.abi_version != shared.transport_provider.PANCAKE_TRANSPORT_PROFILE_ABI_VERSION or
        profile.struct_size < @sizeOf(shared.PancakeTransportProfile))
    {
        shared.setLastError("driver: provider profile has an unsupported ABI", .{});
        return error.InvalidArgument;
    }
    const name_ptr = profile.transport_name orelse {
        shared.setLastError("driver: provider transport_name must be set", .{});
        return error.InvalidArgument;
    };
    if (profile.transport_name_len == 0) {
        shared.setLastError("driver: provider transport_name must be nonempty", .{});
        return error.InvalidArgument;
    }
    const scheme: net.netlayer.DesignatorScheme = switch (profile.designator_scheme) {
        shared.transport_provider.PANCAKE_DESIGNATOR_SCHEME_ADDRESS => .address,
        shared.transport_provider.PANCAKE_DESIGNATOR_SCHEME_KEY => .key,
        else => {
            shared.setLastError("driver: provider has an invalid designator_scheme", .{});
            return error.InvalidArgument;
        },
    };
    const sealed_channel = switch (profile.sealed_channel) {
        shared.transport_provider.PANCAKE_SEALED_CHANNEL_NONE => false,
        shared.transport_provider.PANCAKE_SEALED_CHANNEL_NOISE_XK => true,
        else => {
            shared.setLastError("driver: provider has an invalid sealed_channel", .{});
            return error.InvalidArgument;
        },
    };
    const wire_framing: model.transport.WireFraming = switch (profile.wire_framing) {
        shared.transport_provider.PANCAKE_WIRE_FRAMING_BYTE_STREAM => .byte_stream,
        shared.transport_provider.PANCAKE_WIRE_FRAMING_MESSAGE => .message,
        else => {
            shared.setLastError("driver: provider has an invalid wire_framing", .{});
            return error.InvalidArgument;
        },
    };
    return .{
        .symbol = name_ptr[0..profile.transport_name_len],
        .designator_scheme = scheme,
        .sealed_channel = sealed_channel,
        .wire_framing = wire_framing,
        .max_packet_bytes = profile.max_packet_bytes,
    };
}
