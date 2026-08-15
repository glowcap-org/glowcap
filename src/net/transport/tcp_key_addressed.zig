//! The key-addressed TCP profile shared by `tcp.keyed` and `tcp.noise`.
//!
//! Both profiles use the responder's Ed25519 public key as their designator and
//! carry the bound socket address in the locator's `direct-addresses` hint.
//! They intentionally share one socket-resident implementation. The transport
//! symbol remains distinct because it selects channel semantics: `keyed-tcp` is cleartext,
//! while `noise-tcp` makes the owning core Host run the sealed channel.

const std = @import("std");

const model = @import("model");
const engine = @import("engine");
const connection = @import("../connection.zig");
const netlayer = @import("../netlayer.zig");
const tcp = @import("tcp_plain.zig");
const addressing = @import("tcp_addressing.zig");
const profile_listener = @import("tcp_listener.zig");

const Netlayer = netlayer.Netlayer;
const NetLayerListener = netlayer.Listener;
const Buffers = netlayer.Buffers;
const Connection = connection.Connection;

/// Instantiate one key-addressed profile backed by TCP. Only the two transport
/// symbols whose locator and socket behavior are identical are admitted here;
/// their different channel semantics remain in `driver_core`.
pub fn Profile(comptime transport: model.transport.Known) type {
    const metadata = transport.metadata();
    if (metadata.designator_scheme != .key or metadata.address_source != .direct_addresses_hint)
        @compileError("a key-addressed TCP profile needs key designators and direct-addresses hints");

    return struct {
        pub const transport_name = metadata.symbol;

        /// Build a key-addressed locator without parsing or allocating.
        /// `designator` is the peer's canonical key designator and
        /// `direct_addresses` is the caller-owned address hint. The returned
        /// locator borrows all three inputs, including `hint_storage`, until
        /// the dial path has copied or retained the locator.
        pub fn locator(
            designator: []const u8,
            direct_addresses: []const u8,
            hint_storage: *[1]model.HintEntry,
        ) model.PeerLocator {
            return .{
                .transport = transport_name,
                .designator = designator,
                .hints = model.Hints.forDirectAddresses(direct_addresses, hint_storage),
            };
        }

        pub const Resident = struct {
            io: std.Io,
            stream_options: tcp.StreamOptions = .{},

            pub fn netlayer(self: *Resident) Netlayer {
                return .{ .ctx = self, .vtable = &resident_vtable };
            }
        };

        const resident_ctx = netlayer.ResidentContext(Resident);

        const resident_vtable: Netlayer.VTable = .{
            .profile = metadata,
            .dial = .{ .blocking = residentDial },
            .listen = residentListen,
            .io = resident_ctx.io,
        };

        fn residentDial(
            ctx: *anyopaque,
            peer: *engine.Peer,
            loc: model.PeerLocator,
            bufs: Buffers,
            options: netlayer.OperationOptions,
        ) netlayer.DialError!Connection {
            const self = resident_ctx.of(ctx);
            const override = try options.decode(tcp.OperationOptions);
            const stream_options = if (override) |value| value.stream else self.stream_options;
            const direct = netlayer.directAddrHint(loc.hints) orelse &.{};
            const address = addressing.resolveProfile(metadata, loc.designator, direct) catch
                return error.InvalidAddress;
            return tcp.connectAddress(self.io, peer, address, bufs.read, bufs.write, stream_options) catch |err|
                tcp.classifyConnect(err);
        }

        fn residentListen(
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            config: netlayer.ListenConfig,
        ) netlayer.ListenStartOutcome {
            return .{ .admitted = residentListenFallible(ctx, allocator, config) catch |err|
                return .{ .failed = .init(err) } };
        }

        fn residentListenFallible(
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            config: netlayer.ListenConfig,
        ) netlayer.ListenError!netlayer.ListenResult {
            const self = resident_ctx.of(ctx);
            const address = addressing.parseDesignator(config.designator) catch return error.InvalidAddress;
            const public_key = config.identity orelse return error.InvalidAddress;
            const box = allocator.create(ListenerBox) catch return error.OutOfMemory;
            errdefer allocator.destroy(box);
            box.* = .{
                .listener = profile_listener.Listener.bind(transport, self.io, address, public_key) catch
                    return error.BindFailed,
                .stream_options = if (try config.options.decode(tcp.OperationOptions)) |value|
                    value.stream
                else
                    self.stream_options,
                .allocator = allocator,
            };
            return .{ .ready = .{ .ctx = box, .vtable = &listener_vtable } };
        }

        const ListenerBox = struct {
            listener: profile_listener.Listener,
            stream_options: tcp.StreamOptions,
            allocator: std.mem.Allocator,
        };

        const listener_vtable: NetLayerListener.VTable = .{
            .transport_name = transport_name,
            .designator_scheme = metadata.designator_scheme,
            .sealed_channel = metadata.sealed_channel,
            .accept = listenerAccept,
            .waitAcceptable = listenerWaitAcceptable,
            .localLocator = listenerLocalLocator,
            .canonicalizeLocator = listenerCanonicalizeLocator,
            .readiness_fd = listenerReadinessFd,
            .close = listenerClose,
        };

        fn listenerAccept(ctx: *anyopaque, peer: *engine.Peer, bufs: Buffers) netlayer.AcceptError!Connection {
            const box: *ListenerBox = @ptrCast(@alignCast(ctx));
            var raw = box.listener.acceptRaw(bufs.read, bufs.write, box.stream_options) catch |err|
                return tcp.classifyAccept(err);
            errdefer raw.close();
            return tcp.connectionOverRaw(peer, raw);
        }

        fn listenerWaitAcceptable(ctx: *anyopaque, timeout_ms: i32) netlayer.AcceptError!bool {
            const box: *ListenerBox = @ptrCast(@alignCast(ctx));
            return box.listener.waitAcceptable(timeout_ms);
        }

        fn listenerLocalLocator(ctx: *anyopaque, allocator: std.mem.Allocator) netlayer.ListenError!model.PeerLocator {
            const box: *ListenerBox = @ptrCast(@alignCast(ctx));
            return box.listener.localLocator(allocator);
        }

        fn listenerCanonicalizeLocator(
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            candidate: model.PeerLocator,
        ) netlayer.ListenError!model.PeerLocator {
            const box: *ListenerBox = @ptrCast(@alignCast(ctx));
            return box.listener.canonicalizeLocator(allocator, candidate);
        }

        fn listenerReadinessFd(ctx: *anyopaque) i32 {
            const box: *ListenerBox = @ptrCast(@alignCast(ctx));
            return box.listener.readinessFd();
        }

        fn listenerClose(ctx: *anyopaque) ?netlayer.ListenerCloseFailure {
            const box: *ListenerBox = @ptrCast(@alignCast(ctx));
            box.listener.deinit();
            box.allocator.destroy(box);
            return null;
        }
    };
}
