//! The in-process switchboard behind the `inproc` completion adapter.
//!
//! An `Exchange` maps designators to listeners. A dial hands the listener one
//! `Link`: a single allocation holding a bounded ring per direction, so a
//! writer that outruns its reader sees would-block rather than growing a
//! buffer. The rings are this transport's only buffers, the in-process
//! counterpart of a socket's kernel buffers.
//!
//! Each backend owns a `Sink`: an intrusive queue of its link ends with news
//! and a wake channel its platform backend polls. Signaling an end links it
//! into its owner's sink and nudges the wake channel, so it never allocates
//! and works across threads. A link's rings and ends are guarded by the link's
//! lock and a sink's queue by the sink's lock. Locks are taken in the order
//! exchange, link, sink. The wake channel's send never blocks, so a nudge may
//! run under either lock. That is what keeps a sink alive while it is
//! signaled, because its owner detaches every end under the link lock before
//! freeing it.

const std = @import("std");

const completion = @import("../../completion/loop.zig");
const wake_channel = @import("../../wake_channel.zig");
const SpinLock = @import("../../sync.zig").SpinLock;

pub const Exchange = struct {
    allocator: std.mem.Allocator,
    /// Bytes each direction of a link buffers before its writer would block.
    ring_bytes: usize = 16 << 10,
    /// Dials a listener may hold before it accepts them.
    max_pending_accepts: usize = 128,
    lock: SpinLock = .{},
    listeners: std.StringHashMapUnmanaged(*Listener) = .empty,

    pub fn init(allocator: std.mem.Allocator) Exchange {
        return .{ .allocator = allocator };
    }

    /// Every backend that served through this exchange is gone by now.
    pub fn deinit(self: *Exchange) void {
        std.debug.assert(self.listeners.count() == 0);
        self.listeners.deinit(self.allocator);
    }

    /// Register `sink` as the listener for `designator`.
    pub fn listen(self: *Exchange, designator: []const u8, sink: *Sink) !*Listener {
        const listener = try self.allocator.create(Listener);
        errdefer self.allocator.destroy(listener);
        listener.* = .{ .designator = try self.allocator.dupe(u8, designator), .sink = sink };
        errdefer self.allocator.free(listener.designator);
        self.lock.lock();
        defer self.lock.unlock();
        const slot = try self.listeners.getOrPut(self.allocator, listener.designator);
        if (slot.found_existing) return error.AddressInUse;
        slot.value_ptr.* = listener;
        sink.lock.lock();
        sink.listener = listener;
        sink.lock.unlock();
        return listener;
    }

    /// Withdraw `listener`. Dials it never accepted see their peer close.
    pub fn unlisten(self: *Exchange, listener: *Listener) void {
        {
            self.lock.lock();
            defer self.lock.unlock();
            std.debug.assert(self.listeners.remove(listener.designator));
        }
        const sink = listener.sink;
        sink.lock.lock();
        sink.listener = null;
        var link = listener.stash_head;
        sink.lock.unlock();
        while (link) |item| {
            link = item.accept_next;
            item.ends[1].release(self.allocator);
        }
        self.allocator.free(listener.designator);
        self.allocator.destroy(listener);
    }

    /// Dial `designator` from `sink`, whose connection row is `row`. The
    /// returned end is open and writable. The listener accepts the other.
    pub fn connect(self: *Exchange, designator: []const u8, sink: *Sink, row: u32) !*End {
        const link = try Link.create(self.allocator, self.ring_bytes);
        link.ends[0].sink = sink;
        link.ends[0].row = row;
        self.lock.lock();
        defer self.lock.unlock();
        const listener = self.listeners.get(designator) orelse {
            link.destroy(self.allocator);
            return error.ConnectionRefused;
        };
        const target = listener.sink;
        target.lock.lock();
        defer target.lock.unlock();
        if (listener.stash_len >= self.max_pending_accepts) {
            link.destroy(self.allocator);
            return error.ConnectionRefused;
        }
        if (listener.stash_tail) |tail| tail.accept_next = link else listener.stash_head = link;
        listener.stash_tail = link;
        listener.stash_len += 1;
        listener.accept_queued = true;
        target.nudge();
        return &link.ends[0];
    }
};

pub const Listener = struct {
    designator: []u8,
    sink: *Sink,
    /// Dialed links not yet accepted, oldest first. Guarded by `sink.lock`.
    stash_head: ?*Link = null,
    stash_tail: ?*Link = null,
    stash_len: usize = 0,
    accept_queued: bool = false,

    /// The oldest dial's end, not yet bound to a row.
    pub fn take(self: *Listener) ?*End {
        self.sink.lock.lock();
        defer self.sink.lock.unlock();
        const link = self.stash_head orelse return null;
        self.stash_head = link.accept_next;
        if (self.stash_head == null) self.stash_tail = null;
        self.stash_len -= 1;
        link.accept_next = null;
        return &link.ends[1];
    }
};

const Ring = struct {
    buf: []u8,
    head: usize = 0,
    len: usize = 0,

    fn write(self: *Ring, bytes: []const u8) usize {
        const n = @min(bytes.len, self.buf.len - self.len);
        const start = (self.head + self.len) % self.buf.len;
        const first = @min(n, self.buf.len - start);
        @memcpy(self.buf[start..][0..first], bytes[0..first]);
        @memcpy(self.buf[0 .. n - first], bytes[first..n]);
        self.len += n;
        return n;
    }

    fn read(self: *Ring, out: []u8) usize {
        const n = @min(out.len, self.len);
        const first = @min(n, self.buf.len - self.head);
        @memcpy(out[0..first], self.buf[self.head..][0..first]);
        @memcpy(out[first..n], self.buf[0 .. n - first]);
        self.head = (self.head + n) % self.buf.len;
        self.len -= n;
        return n;
    }
};

/// One end of a link. `sink`, `row` and `closed` are guarded by the link's
/// lock. `queued`, `prev` and `next` by the sink's lock.
pub const End = struct {
    link: *Link,
    sink: ?*Sink = null,
    row: u32 = 0,
    closed: bool = false,
    queued: bool = false,
    prev: ?*End = null,
    next: ?*End = null,

    fn index(self: *const End) u1 {
        return if (self == &self.link.ends[0]) 0 else 1;
    }

    fn peer(self: *End) *End {
        return &self.link.ends[1 - self.index()];
    }

    /// Give an accepted end its owner. Bytes or a close may already wait.
    pub fn bind(self: *End, sink: *Sink, row: u32) void {
        self.link.lock.lock();
        defer self.link.lock.unlock();
        self.sink = sink;
        self.row = row;
    }

    pub fn read(self: *End, buf: []u8) completion.TryRead {
        const link = self.link;
        link.lock.lock();
        defer link.lock.unlock();
        const other = self.peer();
        const ring = &link.rings[other.index()];
        const was_full = ring.len == ring.buf.len;
        const n = ring.read(buf);
        if (n == 0) return if (other.closed) .closed else .would_block;
        if (was_full) if (other.sink) |sink| sink.signal(other);
        return .{ .transferred = n };
    }

    pub fn write(self: *End, bytes: []const u8) completion.TryWrite {
        const link = self.link;
        link.lock.lock();
        defer link.lock.unlock();
        const other = self.peer();
        if (other.closed) return .{ .failed = error.BrokenPipe };
        const ring = &link.rings[self.index()];
        const was_empty = ring.len == 0;
        const n = ring.write(bytes);
        if (n == 0) return .would_block;
        if (was_empty) if (other.sink) |sink| sink.signal(other);
        return .{ .transferred = n };
    }

    /// Close this end, leave its owner's queue, and tell its peer. The link is
    /// freed with its second end.
    pub fn release(self: *End, allocator: std.mem.Allocator) void {
        const link = self.link;
        link.lock.lock();
        if (self.sink) |sink| sink.forget(self);
        self.closed = true;
        self.sink = null;
        const other = self.peer();
        if (other.sink) |sink| sink.signal(other);
        link.refs -= 1;
        const last = link.refs == 0;
        link.lock.unlock();
        if (last) link.destroy(allocator);
    }
};

const Link = struct {
    lock: SpinLock = .{},
    /// `rings[i]` carries the bytes end `i` writes.
    rings: [2]Ring,
    ends: [2]End,
    refs: u2 = 2,
    accept_next: ?*Link = null,
    storage: []u8,

    fn create(allocator: std.mem.Allocator, ring_bytes: usize) !*Link {
        const storage = try allocator.alloc(u8, ring_bytes * 2);
        errdefer allocator.free(storage);
        const link = try allocator.create(Link);
        link.* = .{
            .rings = .{ .{ .buf = storage[0..ring_bytes] }, .{ .buf = storage[ring_bytes..] } },
            .ends = undefined,
            .storage = storage,
        };
        link.ends = .{ .{ .link = link }, .{ .link = link } };
        return link;
    }

    fn destroy(self: *Link, allocator: std.mem.Allocator) void {
        allocator.free(self.storage);
        allocator.destroy(self);
    }
};

pub const Sink = struct {
    lock: SpinLock = .{},
    head: ?*End = null,
    tail: ?*End = null,
    len: usize = 0,
    listener: ?*Listener = null,
    wake: wake_channel.WakeChannel,
    wake_failure: wake_channel.FailureLatch = .{},

    pub fn create(allocator: std.mem.Allocator) !*Sink {
        const sink = try allocator.create(Sink);
        errdefer allocator.destroy(sink);
        sink.* = .{ .wake = try wake_channel.WakeChannel.open() };
        return sink;
    }

    /// Every end this sink owned has been released.
    pub fn destroy(self: *Sink, allocator: std.mem.Allocator) void {
        std.debug.assert(self.head == null and self.listener == null);
        self.wake.deinit();
        allocator.destroy(self);
    }

    /// How many ends had news when the owner started a pass, and whether a
    /// dial is waiting to be accepted.
    pub fn startPass(self: *Sink) struct { ends: usize, accept: bool } {
        self.lock.lock();
        defer self.lock.unlock();
        const accept = if (self.listener) |listener| blk: {
            const queued = listener.accept_queued;
            listener.accept_queued = false;
            break :blk queued;
        } else false;
        return .{ .ends = self.len, .accept = accept };
    }

    /// Unlink the oldest end with news, or null when there is none.
    pub fn pop(self: *Sink) ?*End {
        self.lock.lock();
        defer self.lock.unlock();
        const end = self.head orelse return null;
        self.unlink(end);
        return end;
    }

    fn signal(self: *Sink, end: *End) void {
        self.lock.lock();
        if (!end.queued) {
            end.queued = true;
            end.prev = self.tail;
            end.next = null;
            if (self.tail) |tail| tail.next = end else self.head = end;
            self.tail = end;
            self.len += 1;
        }
        self.lock.unlock();
        self.nudge();
    }

    fn nudge(self: *Sink) void {
        // The latch reaches the owner's next poll, which reports it.
        _ = self.wake.nudge() catch |err| self.wake_failure.record(err);
    }

    fn forget(self: *Sink, end: *End) void {
        self.lock.lock();
        defer self.lock.unlock();
        if (end.queued) self.unlink(end);
    }

    fn unlink(self: *Sink, end: *End) void {
        if (end.prev) |prev| prev.next = end.next else self.head = end.next;
        if (end.next) |next| next.prev = end.prev else self.tail = end.prev;
        end.queued = false;
        end.prev = null;
        end.next = null;
        self.len -= 1;
    }
};
