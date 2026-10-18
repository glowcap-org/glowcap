//! Open DataChannel byte-completion authority.
//!
//! The read, write, cancel, and terminal-failure choreography is the shared
//! hinted try-I/O machine in `net.completion`. This module binds it to the
//! sidecar peer's packet verbs and keeps what is WebRTC's own: the borrow
//! token, the signaling-authorized channel key, and per-publication seat
//! reservation.

const foundation = @import("foundation");
const net = @import("net");
const sidecar = @import("../sidecar.zig");

const completion = net.completion;
const crypto = foundation.crypto;
const Peer = sidecar.Peer;

pub const Entry = struct {
    peer: Peer,
    pending: completion.HintedPending = .{},
};

const Row = Entry;

pub fn Machine(comptime Self: type, comptime Fd: type) type {
    return struct {
        /// How the shared try-I/O machine reaches this sidecar. Every
        /// publication reserves its own seat right before it appends, so an
        /// admitted read or write holds none.
        const TryIoOps = struct {
            pub const Entry = Row;
            pub const holds_admission_seat = false;

            pub fn tryRead(entry: *Row, buf: []u8) completion.TryRead {
                if (entry.peer.tryReceivePacket(buf)) |n| {
                    return .{ .transferred = n };
                } else |err| return switch (err) {
                    error.WouldBlock => .would_block,
                    error.Closed => .closed,
                    error.BufferTooSmall, error.Failed => .{ .failed = error.WebRtcReadFailed },
                };
            }

            pub fn tryWrite(entry: *Row, bytes: []const u8) completion.TryWrite {
                if (entry.peer.trySendPacket(bytes)) |n| {
                    return .{ .transferred = n };
                } else |err| return switch (err) {
                    error.WouldBlock => .would_block,
                    error.BufferTooSmall, error.Closed, error.Failed => .{ .failed = error.WebRtcWriteFailed },
                };
            }

            pub fn closeOnFailure(entry: *Row) void {
                entry.peer.close();
            }

            pub fn borrowToken(index: u32) u32 {
                return index;
            }

            pub fn reserveSeats(backend: *Self, count: usize) !void {
                try backend.ready.ensureUnusedCapacity(backend.allocator, count);
            }

            pub fn publish(backend: *Self, item: completion.Completion) void {
                backend.ready.appendAssumeCapacity(item);
            }
        };
        const TryIo = completion.HintedTryIo(Self, TryIoOps);

        pub const entryPtr = TryIo.entryPtr;
        pub const completeRecv = TryIo.completeRecv;
        pub const completeSend = TryIo.completeSend;
        pub const submitRecv = TryIo.submitRecv;
        pub const submitSend = TryIo.submitSend;
        pub const submitCancel = TryIo.submitCancel;
        pub const failOpenConnection = TryIo.failOpenConnection;

        pub fn recycleBorrowed(self: *Self, comp: completion.Completion) void {
            self.buffer_pool.release(@intCast(comp.borrowed.token));
        }

        /// The signaling-authorized remote identity for `fd`'s connection
        /// (ADR-0105): the key the exchange was scoped to, which is the dialed
        /// designator on the offer leg and the adopted peer's `authorizeRemote` on
        /// the answer leg. Null when the signaling owner named no identity.
        pub fn verifiedChannelKey(self: *Self, fd: Fd) ?[crypto.peer_key_bytes]u8 {
            const entry = self.conns.getPtr(fd) orelse return null;
            const key = entry.peer.authorized_remote orelse return null;
            return key.bytes;
        }
    };
}
