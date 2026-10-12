//! Row representation and target vocabulary for the foreign stream adapter.
//!
//! `completion.zig` owns every transition. This leaf holds only the shapes it
//! moves between: a connection row with its armed polls, the provider
//! listener row, and the dial, listen, and address unions.

const model = @import("model");
const completion = @import("../../completion/loop.zig");
const provider_mod = @import("provider.zig");

const Provider = provider_mod.Provider;

pub fn Types(comptime Platform: type, comptime Namespace: type) type {
    return struct {
        pub const ListenerAddress = union(enum) {
            platform: Platform.ListenerAddress,
            external,
        };
        pub const ConnectTarget = union(enum) {
            /// Borrowed for the duration of `startDial`.
            external: model.PeerLocator,
            platform: Platform.ConnectTarget,
        };

        /// The listener handle. Connection rows start at one.
        pub const listen_fd: Platform.Fd = Namespace.fdFromComptimeId(0);

        pub const Op = enum(u3) { read_poll, write_poll, start_poll, cancel };
        pub const Identity = Namespace.RowIdentity(Op);

        pub const Phase = union(enum) {
            connecting: *anyopaque,
            open: *anyopaque,
            /// The dial failed. The loop still owns the handle until it closes.
            failed,
        };

        pub const Entry = struct {
            provider: *const Provider,
            phase: Phase,
            /// The readiness descriptor of the attempt or the connection.
            fd: i32,
            connect_ud: ?u64 = null,
            close_ud: ?u64 = null,
            closing: bool = false,
            pending: completion.HintedPending = .{},
            read_poll: bool = false,
            write_poll: bool = false,
            start_poll: bool = false,
            /// Cancellations submitted for this row's polls, not yet retired.
            cancels: u2 = 0,

            pub fn quiet(entry: *const Entry) bool {
                return !entry.read_poll and !entry.write_poll and !entry.start_poll and entry.cancels == 0;
            }
        };

        pub const ListenerRow = struct {
            provider: *const Provider,
            phase: union(enum) { starting: *anyopaque, listening: *anyopaque },
            fd: i32,
            accept_ud: ?u64 = null,
            /// Waiting for a starting listener to finish its setup.
            ready_ud: ?u64 = null,
            close_ud: ?u64 = null,
            closing: bool = false,
            poll: bool = false,
            cancels: u2 = 0,
        };

        /// A provider listener names its provider by transport symbol and is
        /// borrowed for the call. One backend holds one provider listener.
        pub const ListenTarget = union(enum) {
            platform: Platform.ListenTarget,
            provider: struct { transport: []const u8, designator: []const u8, identity: ?provider_mod.PeerKey = null },
        };
    };
}
