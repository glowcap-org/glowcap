//! Normalize locator exchange across the stream and multiplexed provider ABIs.
//! Their I/O ownership models differ, but both synchronously project the same
//! OCapN peer locator through the same sink contract.

const std = @import("std");

const model = @import("model");
const net = @import("net");
const shared = @import("c_abi_shared");

const PANCAKE_OK = shared.PANCAKE_OK;
const PANCAKE_ERR_NULL_POINTER = shared.PANCAKE_ERR_NULL_POINTER;
const PANCAKE_ERR_INVALID_ARGUMENT = shared.PANCAKE_ERR_INVALID_ARGUMENT;

/// Own the result of one provider's synchronous locator projection. The
/// provider may keep every view on its stack: `receive` validates and clones
/// the complete locator before returning to it.
const Capture = struct {
    allocator: std.mem.Allocator,
    locator: ?model.PeerLocator = null,
    called: bool = false,

    fn receive(raw: ?*anyopaque, view: ?*const shared.PancakeLocatorView) callconv(.c) i32 {
        const self: *Capture = @ptrCast(@alignCast(raw orelse return PANCAKE_ERR_NULL_POINTER));
        if (self.called) return PANCAKE_ERR_INVALID_ARGUMENT;
        self.called = true;
        const borrowed_view = view orelse return PANCAKE_ERR_NULL_POINTER;
        self.locator = shared.locator_adapter.cloneView(self.allocator, borrowed_view) catch |err|
            return shared.locatorAdapterErrorCode(err);
        return PANCAKE_OK;
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
/// use their listener handle as `ctx`; multiplexed providers use their
/// listener context. The callback ABI is otherwise identical.
pub const Listener = struct {
    ctx: ?*anyopaque,
    transport: []const u8,
    local: shared.PancakeTransportListenerLocatorFn,
    canonicalize: shared.PancakeTransportListenerAdvertiseFn,

    fn invoke(
        self: Listener,
        proposed: ?*const shared.PancakeLocatorView,
        result: *Capture,
    ) i32 {
        return if (proposed) |view|
            self.canonicalize(self.ctx, view, result, Capture.receive)
        else
            self.local(self.ctx, result, Capture.receive);
    }

    fn capture(
        self: Listener,
        allocator: std.mem.Allocator,
        proposed: ?model.PeerLocator,
    ) net.netlayer.ListenError!model.PeerLocator {
        var hint_stack: [shared.locator_adapter.inline_hint_capacity]shared.PancakeLocatorHintView = undefined;
        var projection: ?shared.locator_adapter.Projection = if (proposed) |locator|
            shared.locator_adapter.Projection.init(allocator, locator, &hint_stack) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidAddress,
            }
        else
            null;
        defer if (projection) |*value| value.deinit(allocator);

        var result: Capture = .{ .allocator = allocator };
        defer result.deinit();
        const code = self.invoke(if (projection) |*value| &value.view else null, &result);
        switch (code) {
            PANCAKE_OK => {},
            shared.PANCAKE_ERR_INTERNAL => return error.OutOfMemory,
            else => return error.InvalidAddress,
        }
        return result.take(self.transport);
    }

    pub fn localLocator(
        self: Listener,
        allocator: std.mem.Allocator,
    ) net.netlayer.ListenError!model.PeerLocator {
        return self.capture(allocator, null);
    }

    pub fn canonicalizeLocator(
        self: Listener,
        allocator: std.mem.Allocator,
        proposed: model.PeerLocator,
    ) net.netlayer.ListenError!model.PeerLocator {
        return self.capture(allocator, proposed);
    }
};
