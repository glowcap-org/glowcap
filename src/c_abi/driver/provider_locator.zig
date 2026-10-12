//! Normalize locator exchange across the stream and multiplexed provider ABIs.
//! Their I/O ownership models differ, but both synchronously project the same
//! OCapN peer locator through the same sink contract.

const std = @import("std");

const model = @import("model");
const net = @import("net");
const shared = @import("c_abi_shared");
const provider_failure = @import("provider_failure.zig");

const GLOWCAP_OK = shared.GLOWCAP_OK;
const GLOWCAP_ERR_NULL_POINTER = shared.GLOWCAP_ERR_NULL_POINTER;
const GLOWCAP_ERR_INVALID_ARGUMENT = shared.GLOWCAP_ERR_INVALID_ARGUMENT;

/// Own the result of one provider's synchronous locator projection. The
/// provider may keep every view on its stack: `receive` validates and clones
/// the complete locator before returning to it.
const Capture = struct {
    allocator: std.mem.Allocator,
    locator: ?model.PeerLocator = null,
    called: bool = false,
    failure: ?anyerror = null,

    fn receive(raw: ?*anyopaque, view: ?*const shared.GlowcapLocatorView) callconv(.c) i32 {
        const self: *Capture = @ptrCast(@alignCast(raw orelse return GLOWCAP_ERR_NULL_POINTER));
        if (self.called) return GLOWCAP_ERR_INVALID_ARGUMENT;
        self.called = true;
        const borrowed_view = view orelse return GLOWCAP_ERR_NULL_POINTER;
        self.locator = shared.locator_adapter.cloneView(self.allocator, borrowed_view) catch |err| {
            self.failure = if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidAddress;
            return shared.locatorAdapterErrorCode(err);
        };
        return GLOWCAP_OK;
    }

    fn take(self: *Capture, expected_transport: []const u8) net.netlayer.ListenError!model.PeerLocator {
        const locator = self.locator orelse return error.InvalidAddress;
        if (!std.mem.eql(u8, locator.transport, expected_transport)) return error.InvalidAddress;
        self.locator = null;
        return locator;
    }

    fn deinit(self: *Capture) void {
        if (self.locator) |locator| model.freePeerLocator(self.allocator, locator);
    }
};

/// The execution-model-neutral listener locator contract. Stream providers
/// use their listener handle as `ctx`. Multiplexed providers use their
/// listener context. The callback ABI is otherwise identical.
pub const Listener = struct {
    ctx: ?*anyopaque,
    transport: []const u8,
    local: shared.GlowcapTransportListenerLocatorFn,
    canonicalize: shared.GlowcapTransportListenerAdvertiseFn,

    fn invoke(
        self: Listener,
        proposed: ?*const shared.GlowcapLocatorView,
        result: *Capture,
        report: *shared.GlowcapProviderFailure,
    ) i32 {
        return if (proposed) |view|
            self.canonicalize(self.ctx, view, result, Capture.receive, report)
        else
            self.local(self.ctx, result, Capture.receive, report);
    }

    pub const Outcome = net.netlayer.ListenerLocatorOutcome;

    fn capture(
        self: Listener,
        allocator: std.mem.Allocator,
        proposed: ?model.PeerLocator,
    ) Outcome {
        var hint_stack: [shared.locator_adapter.inline_hint_capacity]shared.GlowcapLocatorHintView = undefined;
        var projection: ?shared.locator_adapter.Projection = if (proposed) |locator|
            shared.locator_adapter.Projection.init(allocator, locator, &hint_stack) catch |err| switch (err) {
                error.OutOfMemory => return .{ .failed = .init(error.OutOfMemory) },
                else => return .{ .failed = .init(error.InvalidAddress) },
            }
        else
            null;
        defer if (projection) |*value| value.deinit(allocator);

        var result: Capture = .{ .allocator = allocator };
        defer result.deinit();
        var report = shared.transport_provider.emptyProviderFailure();
        const code = self.invoke(if (projection) |*value| &value.view else null, &result, &report);
        if (code != GLOWCAP_OK) {
            if (result.failure) |failure| {
                if (!provider_failure.isEmpty(report))
                    return .{ .failed = .init(error.ProviderContract) };
                return .{ .failed = .init(failure) };
            }
            const failure = provider_failure.chain(code, report) catch
                return .{ .failed = .init(error.ProviderContract) };
            return .{ .failed = failure };
        }
        if (!provider_failure.isEmpty(report))
            return .{ .failed = .init(error.ProviderContract) };
        const locator = result.take(self.transport) catch |err|
            return .{ .failed = .init(err) };
        return .{ .locator = locator };
    }

    pub fn localLocatorOutcome(self: Listener, allocator: std.mem.Allocator) Outcome {
        return self.capture(allocator, null);
    }

    pub fn canonicalizeLocatorOutcome(
        self: Listener,
        allocator: std.mem.Allocator,
        proposed: model.PeerLocator,
    ) Outcome {
        return self.capture(allocator, proposed);
    }
};
