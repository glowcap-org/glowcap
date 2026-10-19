//! The transports one HostRuntime serves, as one value (ADR-0018).
//!
//! First-party stream symbols run on one `net.StreamStack` resident the
//! runtime builds and owns as a provider package. Residents the caller owns
//! (iroh, WebRTC) register beside it. Nothing is on by default: a symbol the
//! value does not name is refused as an unknown transport.

const std = @import("std");
const builtin = @import("builtin");

const model = @import("model");
const net = @import("net");

const provider_package = @import("provider_package.zig");
const runtime = @import("../host_runtime.zig");
const HostRuntime = runtime.HostRuntime;
const OperationFailure = @import("../operation_failure.zig").OperationFailure;

const stack_supported = builtin.os.tag == .linux or builtin.os.tag.isDarwin();
const Stack = if (stack_supported) net.StreamStack else void;

pub const Transports = struct {
    /// The first-party symbols the runtime's stream stack serves: `tcp`,
    /// `keyed-tcp`, `noise-tcp`, `keyed-relay`, `noise-relay`, `onion`, and
    /// `inproc`. The Host seals the Noise symbols (ADR-0041).
    symbols: []const model.transport.Known = &.{},
    /// The relay `keyed-relay` and `noise-relay` dial and register at.
    relay: ?RelayOptions = null,
    /// Tor's endpoints for `onion`.
    onion: ?OnionConfig = null,
    /// The switchboard `inproc` dials and listens through. Borrowed for the
    /// runtime's life.
    inproc: ?*net.inproc_completion.Exchange = null,
    /// Residents the caller owns and keeps stable for the runtime's life.
    residents: []const provider_package.Registration = &.{},
    stack: Sizing = .{},

    pub const RelayOptions = if (stack_supported) Stack.RelayOptions else noreturn;
    pub const OnionConfig = if (stack_supported) Stack.OnionConfig else noreturn;

    /// The stream stack's completion queue and shared read pool.
    pub const Sizing = struct {
        queue_entries: u16 = 64,
        read_buffers: u16 = 16,
        read_buffer_bytes: u32 = 16 << 10,
    };
};

/// Register everything `transports` names on a runtime that has none yet.
pub fn install(self: *HostRuntime, transports: Transports) !void {
    if (transports.symbols.len != 0) try installStack(self, transports);
    if (transports.residents.len == 0) return;
    const indices = try self.allocator.alloc(usize, transports.residents.len);
    defer self.allocator.free(indices);
    try self.addProviders(transports.residents, indices);
}

fn installStack(self: *HostRuntime, transports: Transports) !void {
    if (!stack_supported) return error.UnknownTransport else return installSupported(self, transports);
}

fn installSupported(self: *HostRuntime, transports: Transports) !void {
    for (transports.symbols) |symbol| switch (symbol) {
        .tcp, .keyed_tcp, .noise_tcp, .keyed_relay, .noise_relay, .onion, .inproc => {},
        .iroh, .webrtc, .id => return error.UnknownTransport,
    };
    const owned = try StackOwner.create(self.allocator, transports);
    var owned_live = true;
    errdefer if (owned_live) if (StackOwner.release(owned)) |failure| self.noteTerminalOperationFailure(failure);

    const registrations = try self.allocator.alloc(HostRuntime.ProviderRegistration, transports.symbols.len);
    defer self.allocator.free(registrations);
    const indices = try self.allocator.alloc(usize, transports.symbols.len);
    defer self.allocator.free(indices);
    const resident = owned.resident.resident();
    for (transports.symbols, registrations) |symbol, *registration|
        registration.* = .{ .profile = symbol.metadata(), .resident = resident };
    const installed = try self.addProviderPackage(.{
        .registrations = registrations,
        .owner = .{ .ctx = owned, .same_configuration = StackOwner.sameConfiguration, .release = StackOwner.releaseOpaque },
    }, indices);
    // A runtime with no transports yet has no package to overlap.
    std.debug.assert(installed);
    owned_live = false;
}

/// The heap home of the runtime's stream stack, which the runtime's provider
/// rows borrow.
const StackOwner = struct {
    allocator: std.mem.Allocator,
    resident: Stack.Resident,

    /// The runtime closed every carrier and listener before packages
    /// release, so only cancellations remain owed here.
    const drain_ms = 2_000;

    fn create(allocator: std.mem.Allocator, transports: Transports) !*StackOwner {
        const owned = try allocator.create(StackOwner);
        errdefer allocator.destroy(owned);
        const backend = try Stack.initBackend(allocator, .{
            .queue_entries = transports.stack.queue_entries,
            .read_buffers = transports.stack.read_buffers,
            .read_buffer_bytes = transports.stack.read_buffer_bytes,
            .relay = transports.relay,
            .onion = transports.onion,
            .inproc = .{ .exchange = transports.inproc },
        });
        owned.* = .{
            .allocator = allocator,
            .resident = try Stack.Resident.init(allocator, backend, .{}),
        };
        return owned;
    }

    fn sameConfiguration(_: *anyopaque, _: *anyopaque) anyerror!bool {
        return false;
    }

    fn releaseOpaque(ctx: *anyopaque) ?OperationFailure {
        return release(@ptrCast(@alignCast(ctx)));
    }

    fn release(self: *StackOwner) ?OperationFailure {
        // tolerant: a stack whose owed operations outlive the bound still
        // borrows its staging, so it stays allocated and the cause is reported.
        self.resident.closeAndDrain(drain_ms) catch |err| return OperationFailure.fromError(err);
        self.resident.deinit();
        self.allocator.destroy(self);
        return null;
    }
};
