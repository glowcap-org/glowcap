//! One foreign stream provider table on its own external completion resident
//! (ADR-0193, ADR-0202). The table keeps the stream contract
//! `stream_completion` checks. HostRuntime sees one multiplexed resident.

const std = @import("std");
const model = @import("model");
const net = @import("net");
const driver = @import("driver");
const shared = @import("c_abi_shared");
const foundation = @import("foundation");
const owner_mod = @import("owner.zig");
const validation = @import("validation.zig");
const stream_completion = @import("stream_completion.zig");

const external = net.external_completion;
const Owner = owner_mod.Owner;
const Backend = external.CompletionBackend(net.Backend);
const Resident = net.completion_resident.Resident(Backend, external.ResidentPolicy(Backend, external.PlatformRefused(net.Backend)));

pub const Adapter = struct {
    owner: *Owner,
    stream: stream_completion.StreamProvider,
    /// The one provider row the backend serves. The backend borrows it.
    providers: [1]external.Provider,
    resident: Resident,

    /// The runtime retires every wire and listener before packages release,
    /// so only cancellations remain owed here.
    const drain_ms = 2_000;

    pub fn multiplexedResident(self: *Adapter) net.MultiplexedResident {
        return self.resident.resident();
    }

    /// A resident whose owed operations outlive the bound still borrows its
    /// staging, so it stays allocated and the cause is reported.
    pub fn deinit(self: *Adapter) ?driver.OperationFailure {
        self.resident.closeAndDrain(drain_ms) catch |err| return .fromError(err);
        self.resident.deinit();
        const allocator = self.owner.allocator;
        allocator.free(self.stream.transport);
        allocator.destroy(self);
        return null;
    }

    fn violation(ctx: *anyopaque, message: []const u8) void {
        const self: *Adapter = @ptrCast(@alignCast(ctx));
        self.owner.failContract(message);
    }

    fn teardown(ctx: *anyopaque, failure: foundation.FailureChain) void {
        const self: *Adapter = @ptrCast(@alignCast(ctx));
        self.owner.runtime.reportUnhandledFailure(.fromChain(failure));
    }
};

pub fn prepare(
    owner: *Owner,
    profile: model.transport.Metadata,
    table_ptr: *const shared.GlowcapStreamTransport,
) !*Adapter {
    try validation.tablePrefix(shared.GlowcapStreamTransport, table_ptr, shared.transport_provider.GLOWCAP_STREAM_TRANSPORT_ABI_VERSION, "stream");
    const table = table_ptr.*;
    const dial_any = table.start_connect != null or table.finish_connect != null or table.cancel_connect != null;
    const dial = try validation.operationGroup(dial_any, table.start_connect != null and
        table.finish_connect != null and table.cancel_connect != null, "stream dial");
    const listen_completion_any = table.finish_listen != null or table.cancel_listen != null;
    _ = try validation.operationGroup(listen_completion_any, table.finish_listen != null and
        table.cancel_listen != null, "stream listen completion");
    const listen_operation = table.listen != null;
    const listen_any = listen_operation or table.finish_listen != null or table.cancel_listen != null or
        table.listener_wait_acceptable != null or table.listener_readiness_fd != null or
        table.listener_locator != null or table.listener_advertise != null or
        table.listener_restoration_state != null or
        table.accept != null or table.listener_close != null;
    const listen = try validation.operationGroup(listen_any, listen_operation and
        table.listener_wait_acceptable != null and
        table.listener_readiness_fd != null and table.listener_locator != null and
        table.listener_advertise != null and table.accept != null and table.listener_close != null, "stream listen");
    if ((!dial and !listen) or table.try_read == null or table.try_write == null or table.conn_close == null or table.conn_take_failure == null) {
        shared.setLastError("driver: stream provider has no operation group or connection callbacks", .{});
        return error.InvalidArgument;
    }
    const allocator = owner.allocator;
    const transport = try allocator.dupe(u8, profile.symbol);
    errdefer allocator.free(transport);
    const adapter = try allocator.create(Adapter);
    errdefer allocator.destroy(adapter);
    adapter.owner = owner;
    adapter.stream = .{
        .allocator = allocator,
        .transport = transport,
        .table = table,
        .sink = .{ .ctx = adapter, .violation = Adapter.violation, .teardown = Adapter.teardown },
    };
    adapter.providers = .{adapter.stream.provider()};
    const sizing: driver.Transports.Sizing = .{};
    const platform = try net.Backend.init(allocator, sizing.queue_entries, sizing.read_buffers, sizing.read_buffer_bytes);
    adapter.resident = try Resident.init(allocator, try Backend.initWithPlatform(
        allocator,
        .{ .providers = &adapter.providers },
        platform,
        sizing.read_buffers,
        sizing.read_buffer_bytes,
    ), .{});
    return adapter;
}
