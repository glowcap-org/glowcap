//! What a registered descriptor waits to do, for the readiness backends
//! (epoll, kqueue) that turn a readiness edge into one completion. io_uring
//! tracks this in the kernel; these backends track it here, one row per fd.

const completion = @import("loop.zig");

/// Read and write are tracked separately because one connection can have a
/// recv and a send outstanding at the same time. Tagged unions carry the op
/// kind so poll sites cannot misread a recv as an accept or a send as a
/// connect.
pub const Pending = struct {
    pub const Send = struct { ud: u64, bytes: []const u8 };

    read: union(enum) {
        idle,
        recv: u64,
        accept: u64,
        poll: u64,
    } = .idle,
    write: union(enum) {
        idle,
        send: Send,
        connect: u64,
        poll: u64,
    } = .idle,

    /// The completions a close owes for every operation still armed on this
    /// row. The completion loop counts ops in flight and defers a
    /// connection's teardown until each one retires, so every submitted op
    /// must yield a completion. io_uring posts a cancellation for a recv or
    /// send still pending when its fd closes; a readiness backend drops the
    /// fd from its kernel set and must synthesize them, or a close while a
    /// recv is armed strands the connection slot forever. Appends at most
    /// `max_cancellations`, which the caller reserved before touching state.
    pub fn cancelInto(self: Pending, ready: *completion.ReadyQueue) void {
        switch (self.read) {
            .idle => {},
            .recv, .accept, .poll => |ud| ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1 }),
        }
        switch (self.write) {
            .idle => {},
            .send => |send| ready.appendAssumeCapacity(.{ .user_data = send.ud, .result = -1 }),
            .connect, .poll => |ud| ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1 }),
        }
    }

    pub const max_cancellations = 2;
};
