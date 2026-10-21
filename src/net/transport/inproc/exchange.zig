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
//! exchange, link, sink. A nudge wakes the sink's owner, whose first act is to
//! take the link lock, so a nudge sent under that lock on one CPU hands the
//! holder's slice to a waiter spinning on it. Signaling therefore queues the
//! end under the locks and nudges after the link lock is released.
//! `Sink.nudging` counts the nudges in flight and `Sink.destroy` waits for
//! them, because the owner detaches every end under the link lock before
//! freeing the sink and a nudger past that lock still holds the pointer.
//! A nudge is owed only to a parked owner: the owner marks the sink parked
//! before it waits (`Sink.park`) and looking when it reaps (`Sink.look`),
//! and a writer that queues news for a looking owner sends nothing, since
//! that owner's next pass settles the queue. An owner that parks over news
//! it has not reaped nudges itself.

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
        const wake = self.stash(designator, link) catch |err| {
            link.destroy(self.allocator);
            return err;
        };
        if (wake) |target| target.nudgeQueued();
        return &link.ends[0];
    }

    /// Queue `link` for the listener at `designator` under the exchange and
    /// sink locks. Returns the listener's sink when its owner is parked and
    /// owed a nudge, counted here and sent once both locks are released.
    fn stash(self: *Exchange, designator: []const u8, link: *Link) error{ConnectionRefused}!?*Sink {
        self.lock.lock();
        defer self.lock.unlock();
        const listener = self.listeners.get(designator) orelse return error.ConnectionRefused;
        const target = listener.sink;
        target.lock.lock();
        defer target.lock.unlock();
        if (listener.stash_len >= self.max_pending_accepts) return error.ConnectionRefused;
        if (listener.stash_tail) |tail| tail.accept_next = link else listener.stash_head = link;
        listener.stash_tail = link;
        listener.stash_len += 1;
        listener.accept_queued = true;
        if (!target.parked) return null;
        target.parked = false;
        _ = target.nudging.fetchAdd(1, .monotonic);
        return target;
    }
};

pub const Listener = struct {
    designator: []u8,
    sink: *Sink,
    /// Dialed links not yet accepted, oldest first. Guarded by `sink.lock`. status-allow: pending state or quoted runtime label
    stash_head: ?*Link = null,
    stash_tail: ?*Link = null,
    stash_len: usize = 0,
    accept_queued: bool = false,

    /// The oldest dial's end, not yet bound to a row. status-allow: pending state or quoted runtime label
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
        const other = self.peer();
        const ring = &link.rings[other.index()];
        const was_full = ring.len == ring.buf.len;
        const n = ring.read(buf);
        const result: completion.TryRead = if (n != 0)
            .{ .transferred = n }
        else if (other.closed)
            .closed
        else
            .would_block;
        const wake = if (n != 0 and was_full) other.queueNews() else null;
        link.lock.unlock();
        if (wake) |sink| sink.nudgeQueued();
        return result;
    }

    pub fn write(self: *End, bytes: []const u8) completion.TryWrite {
        const link = self.link;
        link.lock.lock();
        const other = self.peer();
        if (other.closed) {
            link.lock.unlock();
            return .{ .failed = error.BrokenPipe };
        }
        const ring = &link.rings[self.index()];
        const was_empty = ring.len == 0;
        const n = ring.write(bytes);
        const wake = if (n != 0 and was_empty) other.queueNews() else null;
        link.lock.unlock();
        if (wake) |sink| sink.nudgeQueued();
        return if (n != 0) .{ .transferred = n } else .would_block;
    }

    /// Queue this end in its owner's sink, under the link lock. Returns the
    /// sink when its owner is parked and owed a nudge, which the caller sends
    /// after releasing the link lock.
    fn queueNews(self: *End) ?*Sink {
        const sink = self.sink orelse return null;
        return if (sink.enqueue(self)) sink else null;
    }

    /// Close this end, leave its owner's queue, and tell its peer. The link is
    /// freed with its second end.
    pub fn release(self: *End, allocator: std.mem.Allocator) void {
        const link = self.link;
        link.lock.lock();
        if (self.sink) |sink| sink.forget(self);
        self.closed = true;
        self.sink = null;
        const wake = self.peer().queueNews();
        link.refs -= 1;
        const last = link.refs == 0;
        link.lock.unlock();
        if (wake) |sink| sink.nudgeQueued();
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
    /// Nudges counted under a link or exchange lock and not yet sent. status-allow: pending state or quoted runtime label
    nudging: std.atomic.Value(u32) = .init(0),
    /// The owner is waiting on the wake channel, or about to, so the next
    /// writer that queues news owes it a nudge. Guarded by `lock`.
    parked: bool = false,

    pub fn create(allocator: std.mem.Allocator) !*Sink {
        const sink = try allocator.create(Sink);
        errdefer allocator.destroy(sink);
        sink.* = .{ .wake = try wake_channel.WakeChannel.open() };
        return sink;
    }

    /// Every end this sink owned has been released. A nudge counted before
    /// that release still holds this sink, so wait for it to land.
    pub fn destroy(self: *Sink, allocator: std.mem.Allocator) void {
        std.debug.assert(self.head == null and self.listener == null);
        while (self.nudging.load(.acquire) != 0) std.Thread.yield() catch std.atomic.spinLoopHint();
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

    /// The owner is about to wait on the wake channel. News queued since
    /// its last pass would otherwise wait for the next writer, so the owner
    /// nudges itself and the wait returns at once.
    pub fn park(self: *Sink) void {
        self.lock.lock();
        self.parked = true;
        const pending = self.len > 0 or if (self.listener) |listener| listener.accept_queued else false;
        self.lock.unlock();
        // The latch reaches the owner's next poll, which reports it.
        if (pending) _ = self.wake.nudge() catch |err| self.wake_failure.record(err);
    }

    /// The owner is reaping, so a writer that queues news owes no nudge.
    pub fn look(self: *Sink) void {
        self.lock.lock();
        self.parked = false;
        self.lock.unlock();
    }

    /// Queue `end` as having news. Returns whether the owner is parked and
    /// so owed a nudge, counted here and sent by the caller once the link
    /// lock is released. Called under that lock, which keeps this sink alive
    /// until the count lands. One nudge wakes the owner for every end queued
    /// before it reaps, so the first writer to find it parked sends it.
    fn enqueue(self: *Sink, end: *End) bool {
        self.lock.lock();
        if (!end.queued) {
            end.queued = true;
            end.prev = self.tail;
            end.next = null;
            if (self.tail) |tail| tail.next = end else self.head = end;
            self.tail = end;
            self.len += 1;
        }
        const owed = self.parked;
        self.parked = false;
        self.lock.unlock();
        if (owed) _ = self.nudging.fetchAdd(1, .monotonic);
        return owed;
    }

    /// Send one counted nudge, with no lock held: the owner it wakes takes
    /// the link lock first.
    fn nudgeQueued(self: *Sink) void {
        // The latch reaches the owner's next poll, which reports it.
        _ = self.wake.nudge() catch |err| self.wake_failure.record(err);
        _ = self.nudging.fetchSub(1, .release);
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
