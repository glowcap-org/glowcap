//! One netlayer resident for every TCP channel profile: plain `tcp`,
//! key-addressed `keyed-tcp`, and sealed `noise-tcp`.
//!
//! The three symbols share one socket realization and differ only in locator
//! posture. An address-designated profile publishes its bound `host:port` as
//! the designator. A key-designated profile uses the responder's Ed25519
//! public key as the designator and carries the bound socket address in the
//! locator's `direct-addresses` hint. The transport symbol stays distinct
//! because it selects channel semantics: `keyed-tcp` is cleartext, while
//! `noise-tcp` makes the owning core Host run the sealed channel. Those
//! semantics live in `driver_core`; nothing here differs by them.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const connection = @import("../../connection.zig");
const netlayer = @import("../../netlayer.zig");
const stream = @import("stream.zig");
const addressing = @import("addressing.zig");
const profile_listener = @import("listener.zig");

const Netlayer = netlayer.Netlayer;
const Buffers = netlayer.Buffers;
const Connection = connection.Connection;

/// Instantiate one TCP profile. Only a host-port transport with a dialable
/// address source is admitted; the designator scheme selects whether a listen
/// needs the Host's identity key.
pub fn Profile(comptime transport: model.transport.Known) type {
    const profile_meta = transport.metadata();
    if (profile_meta.dial_shape != .host_port or profile_meta.address_source == .none)
        @compileError("a TCP profile needs host-port dials and a dialable address source");
    const identity_required = profile_meta.designator_scheme == .key;

    return struct {
        pub const transport_name = profile_meta.symbol;

        /// Build this profile's locator without parsing or allocating. The
        /// address form takes the `host:port` designator; the key form takes
        /// the peer's canonical key designator, the caller-owned address hint,
        /// and the hint storage the returned locator borrows.
        pub const locator = LocatorBuilder.locator;

        const LocatorBuilder = if (identity_required) struct {
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
        } else struct {
            pub fn locator(designator: []const u8) model.PeerLocator {
                return .{ .transport = transport_name, .designator = designator, .hints = model.Hints.emptyFalse() };
            }
        };

        /// The resident's state: the host `std.Io` it dials and binds with.
        /// The caller owns a `Resident` at a stable address (the netlayer
        /// vtable's `ctx` points at it) for as long as the transport slice
        /// holds the netlayer.
        pub const Resident = struct {
            io: std.Io,
            stream_options: stream.StreamOptions = .{},

            /// This resident as a `Netlayer`. `self` must outlive every
            /// connection the netlayer mints.
            pub fn netlayer(self: *Resident) Netlayer {
                return .{ .ctx = self, .vtable = &resident_vtable };
            }
        };

        const resident_ctx = netlayer.ResidentContext(Resident);

        const resident_vtable: Netlayer.VTable = .{
            .profile = profile_meta,
            .dial = .{ .blocking = netlayer.adaptBlockingDial(residentDial) },
            .listen = netlayer.adaptListen(residentListen),
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
            const override = try options.decode(stream.OperationOptions);
            const stream_options = if (override) |value| value.stream else self.stream_options;
            const direct = netlayer.directAddrHint(loc.hints) orelse &.{};
            const address = addressing.resolveProfile(profile_meta, loc.designator, direct) catch
                return error.InvalidAddress;
            return stream.connectAddress(self.io, peer, address, bufs.read, bufs.write, stream_options) catch |err|
                stream.classifyConnect(err);
        }

        fn residentListen(
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            config: netlayer.ListenConfig,
        ) netlayer.ListenError!netlayer.ListenResult {
            const self = resident_ctx.of(ctx);
            const address = addressing.parseDesignator(config.designator) catch return error.InvalidAddress;
            const identity: ?foundation.crypto.PeerKey = if (identity_required)
                (config.identity orelse return error.InvalidAddress)
            else
                null;
            const stream_options = if (try config.options.decode(stream.OperationOptions)) |value|
                value.stream
            else
                self.stream_options;
            const box = allocator.create(ListenerBox) catch return error.OutOfMemory;
            errdefer allocator.destroy(box);
            box.* = .{
                .listener = profile_listener.Listener.bind(transport, self.io, address, identity) catch
                    return error.BindFailed,
                .stream_options = stream_options,
                .allocator = allocator,
            };
            return .{ .ready = ListenerShell.listener(box) };
        }

        /// A heap-pinned profile listener, freed by the contract listener's
        /// `close`.
        const ListenerBox = struct {
            listener: profile_listener.Listener,
            stream_options: stream.StreamOptions,
            allocator: std.mem.Allocator,
        };

        const ListenerShell = netlayer.ListenerShell(struct {
            pub const State = ListenerBox;
            pub const metadata = profile_meta;

            pub fn accept(box: *ListenerBox, peer: *engine.Peer, bufs: Buffers) netlayer.AcceptError!Connection {
                var raw = box.listener.acceptRaw(bufs.read, bufs.write, box.stream_options) catch |err|
                    return stream.classifyAccept(err);
                errdefer raw.close();
                return stream.connectionOverRaw(peer, raw);
            }

            pub fn waitAcceptable(box: *ListenerBox, timeout_ms: i32) netlayer.AcceptError!bool {
                return box.listener.waitAcceptable(timeout_ms);
            }

            pub fn localLocator(box: *ListenerBox, allocator: std.mem.Allocator) netlayer.ListenError!model.PeerLocator {
                return box.listener.localLocator(allocator);
            }

            pub fn canonicalizeLocator(
                box: *ListenerBox,
                allocator: std.mem.Allocator,
                candidate: model.PeerLocator,
            ) netlayer.ListenError!model.PeerLocator {
                return box.listener.canonicalizeLocator(allocator, candidate);
            }

            pub fn readinessFd(box: *ListenerBox) i32 {
                return box.listener.readinessFd();
            }

            pub fn close(box: *ListenerBox) ?netlayer.ListenerCloseFailure {
                box.listener.deinit();
                box.allocator.destroy(box);
                return null;
            }
        });
    };
}
