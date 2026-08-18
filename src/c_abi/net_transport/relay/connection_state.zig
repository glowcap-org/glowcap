//! One C relay connection's transport state. The runtime owns admission and
//! lookup; this subject owns I/O serialization, terminal event publication,
//! explicit release, and the claim-once exact failure latch.

const std = @import("std");
const foundation = @import("foundation");
const net = @import("net");
const c = @import("c_abi_shared");

const events = c.multiplexed_transport;
const close_timeout_ms: i64 = 5_000;

fn pollEvents(revents: c_short) u32 {
    const fatal = revents & (std.posix.POLL.ERR | std.posix.POLL.NVAL) != 0;
    const hung_up = revents & std.posix.POLL.HUP != 0;
    var published: u32 = 0;
    if (revents & std.posix.POLL.IN != 0 or hung_up)
        published |= events.PANCAKE_MULTIPLEXED_EV_READABLE;
    if (fatal or hung_up)
        published |= events.PANCAKE_MULTIPLEXED_EV_CLOSED;
    return published;
}

pub const State = struct {
    id: u64,
    raw: net.relay.RawConnection,
    io_mutex: net.sync.SpinLock = .{},
    events: std.atomic.Value(u32) = .init(0),
    closed: std.atomic.Value(bool) = .init(false),
    release_requested: std.atomic.Value(bool) = .init(false),
    release_complete: std.atomic.Value(bool) = .init(false),
    raw_closed: bool = false,
    close_deadline_ms: ?i64 = null,
    close_events: c_short = 0,
    failure_mutex: net.sync.SpinLock = .{},
    failure: ?foundation.FailureChain = null,

    pub fn noteFailure(self: *State, later: foundation.FailureChain) void {
        self.failure_mutex.lock();
        defer self.failure_mutex.unlock();
        if (self.failure) |*failure| failure.noteChain(later) else self.failure = later;
    }

    pub fn claimFailure(self: *State) ?foundation.FailureChain {
        self.failure_mutex.lock();
        defer self.failure_mutex.unlock();
        const failure = self.failure;
        self.failure = null;
        return failure;
    }

    /// Apply one poll edge under the connection's I/O lock. The caller owns
    /// the runtime wake after this returns true.
    pub fn reactLocked(self: *State, revents: c_short) bool {
        if (self.raw_closed or self.closed.load(.acquire) or
            self.release_requested.load(.acquire)) return false;
        if (revents & std.posix.POLL.OUT != 0 and self.raw.hasPendingWrite()) {
            const flushed = self.raw.flushPending();
            if (flushed == -1) {
                self.noteFailure(self.raw.takeFailure() orelse .init(error.ConnectionLost));
                self.closed.store(true, .release);
                _ = self.events.fetchOr(events.PANCAKE_MULTIPLEXED_EV_CLOSED, .acq_rel);
                return true;
            }
            if (!self.raw.hasPendingWrite())
                _ = self.events.fetchOr(events.PANCAKE_MULTIPLEXED_EV_WRITABLE, .acq_rel);
        }
        const fatal = revents & (std.posix.POLL.ERR | std.posix.POLL.NVAL) != 0;
        const hung_up = revents & std.posix.POLL.HUP != 0;
        if (fatal) {
            self.noteFailure(self.raw.takeFailure() orelse .init(error.ConnectionLost));
            self.closed.store(true, .release);
        } else if (hung_up) {
            // A socket hangup is byte-stream EOF, not by itself a transport
            // failure. Publish READABLE with CLOSED so HostRuntime drains the
            // buffered tail and observes the zero read before retiring the
            // wire. ERR/NVAL remain fault-only terminal edges.
            self.closed.store(true, .release);
        }
        const published = pollEvents(revents);
        if (published == 0) return false;
        _ = self.events.fetchOr(published, .acq_rel);
        return true;
    }

    /// Poll interest while an explicit close owns the connection. Zero is
    /// valid only before the reactor has admitted the first close step.
    pub fn releasePollEventsLocked(self: *const State) c_short {
        return self.close_events;
    }

    /// Advance WebSocket close, peer acknowledgement, and carrier shutdown
    /// under the connection's I/O lock. The deadline is owned here rather than
    /// by a binding or caller so every explicit release settles exactly once.
    pub fn advanceRelease(self: *State, io: std.Io) bool {
        self.io_mutex.lock();
        defer self.io_mutex.unlock();
        if (self.raw_closed) return true;
        if (self.closed.load(.acquire)) {
            self.closeLocked();
            return true;
        }
        const now = net.clock.nowMs(io);
        const deadline = self.close_deadline_ms orelse started: {
            const value = now +| close_timeout_ms;
            self.close_deadline_ms = value;
            break :started value;
        };
        if (now >= deadline) {
            self.noteFailure(.init(error.CloseTimedOut));
            self.closeLocked();
            return true;
        }
        self.close_events = switch (self.raw.tryClose()) {
            .complete => {
                self.closeLocked();
                return true;
            },
            .failed => {
                self.noteFailure(self.raw.takeFailure() orelse .init(error.CloseFailed));
                self.closeLocked();
                return true;
            },
            .wait_read => std.posix.POLL.IN,
            .wait_write => std.posix.POLL.OUT,
        };
        return false;
    }

    /// Abortively release the raw stream while retaining the exact chain for
    /// the operation's later readiness-backed claim. Caller holds the runtime
    /// ownership lock.
    pub fn closeAndRetain(self: *State) void {
        self.io_mutex.lock();
        defer self.io_mutex.unlock();
        self.closeLocked();
    }

    fn closeLocked(self: *State) void {
        if (self.raw_closed) return;
        if (self.raw.takeFailure()) |failure| self.noteFailure(failure);
        if (self.raw.close()) |failure| self.noteFailure(failure);
        self.raw_closed = true;
    }
};
