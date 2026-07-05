//! The in-process netlayer (`inproc`): a second resident behind the netlayer
//! contract, with no sockets at all.
//!
//! With only tcp behind it, the [netlayer contract](netlayer.zig) could have
//! been accidentally socket-shaped; this resident proves it is not. A
//! `Network` is a switchboard: a listener binds to a designator, a dialer names
//! that designator, and the two are wired by a pair of in-process byte pipes —
//! one per direction — exposed as the same `*std.Io.Reader` / `*std.Io.Writer`
//! pair tcp produces. The driver dials and hosts it through the identical
//! `connectVia` / `acceptVia` path, with the same verified keyed handshake, and
//! nothing in the driver or core knows which transport it got. Two genuinely
//! different residents (tcp and inproc) are the shape that generalizes: the
//! QUIC/iroh resident (ADR-0055) registered as the third the same way, without
//! re-privileging any of them.
//!
//! This transport is for in-process testing and mocking: a full OCapN
//! conversation between two peers in one program, with no kernel transport and no
//! file descriptors, so a test exercises the protocol without socket timing or fd
//! limits. The pipes block the reading thread until the partner writes, which is
//! correct under a threaded `std.Io` (the handshake's two halves run on two
//! fibers); it is not built for high-fan-out production, where the completion loop
//! and a real transport carry the load. Pipe buffers are unbounded by design here
//! — a mock has a cooperative partner — so this is not an attack surface to bound
//! like a real netlayer's read path.
//!
//! Blocking uses `std.Io.Mutex` / `std.Io.Condition`, the io-aware primitives, so
//! one handshake half parks until the other produces bytes under whatever `std.Io`
//! backs the conversation (a threaded backend blocks the thread; a fiber backend
//! yields). The two places a vtable callback runs without an `io` in hand — the
//! transport-handle `close` and the listener `close` — use a tiny non-blocking
//! spinlock (`std.atomic.Mutex`) over short critical sections only (a refcount, a
//! map removal), never to wait.

const std = @import("std");

const foundation = @import("foundation");
const engine = @import("engine");
const model = @import("model");
const netlayer = @import("../netlayer.zig");
const connection = @import("../connection.zig");
const frame_stream = @import("../frame_stream.zig");
const stream_shim = @import("../stream_shim.zig");

const Io = std.Io;

/// A non-blocking spinlock for the short critical sections reached from vtable
/// `close` callbacks, which have no `io` to drive an `Io.Mutex`. Held only across
/// a refcount decrement or a hash-map removal, never across a wait.
const SpinLock = struct {
    inner: std.atomic.Mutex = .unlocked,
    fn lock(self: *SpinLock) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }
    fn unlock(self: *SpinLock) void {
        self.inner.unlock();
    }
};
const Connection = connection.Connection;
const Netlayer = netlayer.Netlayer;
const Listener = netlayer.Listener;
const Buffers = netlayer.Buffers;
// Aliased so the `Network` struct's `netlayer()` method does not shadow the
// `netlayer` module import when these error sets are named inside its body.
const DialError = netlayer.DialError;
const ListenError = netlayer.ListenError;
const AcceptError = netlayer.AcceptError;

/// The transport symbol this resident registers under and signs into
/// `op:start-session`. Matches the `pancake_inproc_*` C ABI family.
pub const transport_name = "inproc";

// ── The byte pipe ────────────────────────────────────────────────────────────

/// A one-directional in-process byte FIFO. One endpoint writes, the other reads;
/// a read blocks until bytes arrive or the writer closes (clean EOF). Thread-safe
/// because the two endpoints run on two fibers during the handshake.
const Channel = struct {
    allocator: std.mem.Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    not_empty: Io.Condition = .init,
    data: std.ArrayList(u8) = .empty,
    pos: usize = 0,
    closed: bool = false,

    fn write(self: *Channel, bytes: []const u8) std.mem.Allocator.Error!void {
        if (bytes.len == 0) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.data.appendSlice(self.allocator, bytes);
        self.not_empty.signal(self.io);
    }

    /// Block until at least one byte is available, then copy up to `dest.len`
    /// into `dest` and return the count. Returns 0 only at clean EOF: the writer
    /// closed and the buffer is drained.
    fn read(self: *Channel, dest: []u8) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.pos == self.data.items.len and !self.closed) self.not_empty.waitUncancelable(self.io, &self.mutex);
        const available = self.data.items.len - self.pos;
        if (available == 0) return 0;
        const n = @min(available, dest.len);
        @memcpy(dest[0..n], self.data.items[self.pos..][0..n]);
        self.pos += n;
        // Reclaim the drained prefix so a long conversation does not grow the
        // backing without bound.
        if (self.pos == self.data.items.len) {
            self.data.clearRetainingCapacity();
            self.pos = 0;
        }
        return n;
    }

    fn close(self: *Channel) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.closed = true;
        self.not_empty.broadcast(self.io);
    }

    fn deinit(self: *Channel) void {
        self.data.deinit(self.allocator);
    }
};

/// The two pipes of one connection plus a reference count. Each endpoint releases
/// once on close; the channels and this record free when both are gone, so a
/// partner still draining buffered bytes after the other side closed reads them
/// before the storage disappears.
const Duplex = struct {
    allocator: std.mem.Allocator,
    dial_to_listen: Channel,
    listen_to_dial: Channel,
    refs_lock: SpinLock = .{},
    refs: usize = 2,

    fn create(allocator: std.mem.Allocator, io: Io) std.mem.Allocator.Error!*Duplex {
        const self = try allocator.create(Duplex);
        self.* = .{
            .allocator = allocator,
            .dial_to_listen = .{ .allocator = allocator, .io = io },
            .listen_to_dial = .{ .allocator = allocator, .io = io },
        };
        return self;
    }

    fn release(self: *Duplex) void {
        self.refs_lock.lock();
        self.refs -= 1;
        const remaining = self.refs;
        self.refs_lock.unlock();
        if (remaining == 0) {
            self.dial_to_listen.deinit();
            self.listen_to_dial.deinit();
            self.allocator.destroy(self);
        }
    }
};

// ── The stream over the pipes ────────────────────────────────────────────────

/// The pipe as a `stream_shim` byte source: a blocking channel read that ends
/// cleanly at the writer's close, and a write whose only fault is the pipe
/// failing to allocate.
const ChannelSource = struct {
    chan: *Channel,

    pub fn readSome(self: ChannelSource, dest: []u8) Io.Reader.Error!usize {
        const n = self.chan.read(dest);
        if (n == 0) return error.EndOfStream;
        return n;
    }

    pub fn writeAll(self: ChannelSource, bytes: []const u8) Io.Writer.Error!void {
        self.chan.write(bytes) catch return error.WriteFailed;
    }

    pub fn flush(self: ChannelSource) Io.Writer.Error!void {
        _ = self; // The pipe buffers nothing outside the channel; no flush step.
    }
};

const Shim = stream_shim.Shim(ChannelSource);
const StreamReader = Shim.Reader;
const StreamWriter = Shim.Writer;

/// One end of a connection, pinned so the `Connection`'s borrowed reader/writer
/// interfaces hold a stable address (the vtable recovers the concrete stream from
/// `&interface` by field offset, exactly as tcp's `TcpStream` does). Closing it
/// signals EOF to the partner and releases the shared duplex.
const Endpoint = struct {
    allocator: std.mem.Allocator,
    duplex: *Duplex,
    reader: StreamReader,
    writer: StreamWriter,

    fn create(
        allocator: std.mem.Allocator,
        duplex: *Duplex,
        read_chan: *Channel,
        write_chan: *Channel,
        bufs: Buffers,
    ) std.mem.Allocator.Error!*Endpoint {
        const self = try allocator.create(Endpoint);
        self.* = .{
            .allocator = allocator,
            .duplex = duplex,
            .reader = StreamReader.init(.{ .chan = read_chan }, bufs.read),
            .writer = StreamWriter.init(.{ .chan = write_chan }, bufs.write),
        };
        return self;
    }

    fn intoConnection(self: *Endpoint, io: Io, peer: *engine.Peer) Connection {
        return Connection.init(io, peer, &self.reader.interface, &self.writer.interface, .{
            .ctx = self,
            .close_fn = close,
            .socket_handle_fn = socketHandle,
        });
    }

    fn close(ctx: *anyopaque) void {
        const self: *Endpoint = @ptrCast(@alignCast(ctx));
        // Closing our write side gives the partner's reader a clean EOF.
        self.writer.source.chan.close();
        const duplex = self.duplex;
        self.allocator.destroy(self);
        duplex.release();
    }

    fn socketHandle(ctx: *anyopaque) ?Io.net.Socket.Handle {
        _ = ctx;
        return null; // No fd: this transport multiplexes in process, not via poll.
    }

    /// Build a peer-less `InprocFrameStream` over this endpoint, the host-driven
    /// frame boundary the C ABI sits on, where the host owns the peer. The mirror
    /// of `intoConnection` for the frame-stream path.
    fn intoFrameStream(self: *Endpoint, io: Io, allocator: std.mem.Allocator, codec_id: model.CodecId, max_frame_bytes: usize) InprocFrameStream {
        return .{
            .endpoint = self,
            .io = io,
            .codec_id = codec_id,
            .max_frame_bytes = max_frame_bytes,
            .allocator = allocator,
        };
    }
};

/// The in-process sibling of `net.FrameStream`: read or write one whole
/// frame over an inproc `Endpoint`'s pipes, with the host owning the peer. The
/// frame operations are the same shared `readFrameFrom` / `writeFrameTo` the tcp
/// `FrameStream` drives, so the framing parser and spill logic do not fork by
/// transport. There is no socket and no read fault: a read ends only at the
/// partner's clean EOF, and a write fails only if the in-process pipe cannot
/// allocate.
pub const InprocFrameStream = struct {
    endpoint: *Endpoint,
    io: Io,
    codec_id: model.CodecId,
    max_frame_bytes: usize,
    /// Allocates the spill and the owned frames `readFrame` lifts out; the
    /// read/write buffers stay caller-owned (borrowed into the endpoint).
    allocator: std.mem.Allocator,
    spill: frame_stream.Spill = .{},

    /// Block for one whole `codec_id` frame as an owned `Frame`; `Closed` on the
    /// partner's graceful EOF.
    pub fn readFrame(self: *InprocFrameStream) frame_stream.FrameError!foundation.Frame {
        return frame_stream.readFrameFrom(&self.endpoint.reader.interface, self.allocator, self.codec_id, self.max_frame_bytes, &self.spill);
    }

    /// Write one frame's borrowed bytes into the partner's pipe.
    pub fn writeFrame(self: *InprocFrameStream, bytes: []const u8) frame_stream.FrameError!void {
        return frame_stream.writeFrameTo(&self.endpoint.writer.interface, bytes);
    }

    pub fn deinit(self: *InprocFrameStream) void {
        self.spill.deinit(self.allocator);
        Endpoint.close(self.endpoint);
    }
};

// ── The switchboard ──────────────────────────────────────────────────────────

/// The in-process network: the shared state behind one or more `inproc` netlayer
/// residents. Listeners register by designator; dialers resolve against it. One
/// network per test (or per process region); pass `network.netlayer()` into the
/// `[]const net.netlayer.Netlayer` transport slice beside tcp. The network must
/// outlive every connection and listener it mints.
pub const Network = struct {
    allocator: std.mem.Allocator,
    io: Io,
    lock: SpinLock = .{},
    listeners: std.StringHashMapUnmanaged(*InprocListener) = .empty,

    pub fn init(allocator: std.mem.Allocator, io: Io) Network {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *Network) void {
        // Listeners are freed by their own `close`; this only drops the index.
        self.listeners.deinit(self.allocator);
    }

    /// This network as a `net.netlayer.Netlayer` for the transport slice.
    pub fn netlayer(self: *Network) Netlayer {
        return .{ .ctx = self, .vtable = &netlayer_vtable };
    }

    /// Dial `designator` and return a peer-less `InprocFrameStream` — the
    /// host-driven frame boundary the C ABI sits on. The frame-stream sibling of
    /// the driver-path `dial`; `read_buf` / `write_buf` are caller-owned and
    /// borrowed into the connection for its life.
    pub fn connectFrameStream(
        self: *Network,
        designator: []const u8,
        codec_id: model.CodecId,
        max_frame_bytes: usize,
        read_buf: []u8,
        write_buf: []u8,
    ) DialError!InprocFrameStream {
        const dialer = try self.dialEndpoint(designator, .{ .read = read_buf, .write = write_buf });
        return dialer.intoFrameStream(self.io, self.allocator, codec_id, max_frame_bytes);
    }

    /// Bind a frame-level listener on `designator`, returning the raw
    /// `*InprocListener` whose `acceptFrameStream` yields peer-less streams (the
    /// C ABI listener handle). The driver-path `listen` wraps the same listener in
    /// the netlayer vtable; this hands it back directly. Close with
    /// `InprocListener.close`.
    pub fn bindFrame(self: *Network, allocator: std.mem.Allocator, designator: []const u8) ListenError!*InprocListener {
        return self.createListener(allocator, designator);
    }

    /// Create, register, and return a bound listener. Shared by the driver-path
    /// `listen` (which wraps it in the netlayer vtable) and `bindFrame` (which
    /// returns it directly), so binding and registration live in one place.
    fn createListener(self: *Network, allocator: std.mem.Allocator, designator: []const u8) ListenError!*InprocListener {
        if (designator.len == 0) return error.InvalidAddress;
        const ml = allocator.create(InprocListener) catch return error.OutOfMemory;
        errdefer allocator.destroy(ml);
        const owned = allocator.dupe(u8, designator) catch return error.OutOfMemory;
        errdefer allocator.free(owned);
        ml.* = .{ .network = self, .allocator = allocator, .designator = owned };
        try self.register(owned, ml);
        return ml;
    }

    /// Dial `designator`, wire a fresh duplex to the bound listener, and return
    /// the dialer's pinned `Endpoint`. The shared core of the driver-path `dial`
    /// and the frame-stream `connectFrameStream`; the concurrency (pinning the
    /// listener across the dial, arming the co-owned duplex) lives here once.
    fn dialEndpoint(self: *Network, designator: []const u8, bufs: Buffers) DialError!*Endpoint {
        // Acquire pins the listener for this whole dial: a concurrent
        // `listenerClose` waits for the pin to drop before freeing the listener,
        // so the `enqueue` below never races a destroyed mutex or pending list.
        const listener = self.acquire(designator) orelse return error.ConnectionLost;
        defer self.releaseDial(listener);

        const duplex = try Duplex.create(self.allocator, self.io);
        var duplex_armed = false;
        errdefer if (!duplex_armed) {
            duplex.dial_to_listen.deinit();
            duplex.listen_to_dial.deinit();
            self.allocator.destroy(duplex);
        };

        // The dialer writes the dial→listen pipe and reads the listen→dial pipe.
        const dialer = try Endpoint.create(self.allocator, duplex, &duplex.listen_to_dial, &duplex.dial_to_listen, bufs);
        errdefer self.allocator.destroy(dialer);

        // Hand the listener the duplex; it builds its own endpoint with its own
        // buffers on accept. Once enqueued, the duplex is co-owned and must not be
        // torn down by this errdefer.
        try listener.enqueue(duplex);
        duplex_armed = true;
        return dialer;
    }

    /// Look up a bound listener and pin it against teardown in the same
    /// critical section: the listener's `dialing` count is incremented under
    /// the network lock, and `listenerClose` waits for it to reach zero before
    /// freeing anything, so the returned pointer stays alive for the dial in
    /// flight. Every successful acquire must be paired with `releaseDial`.
    fn acquire(self: *Network, designator: []const u8) ?*InprocListener {
        self.lock.lock();
        defer self.lock.unlock();
        const listener = self.listeners.get(designator) orelse return null;
        listener.dialing += 1;
        return listener;
    }

    /// Drop a dial's pin on `listener` and wake a `listenerClose` parked on
    /// it. The decrement happens under the network lock (the counter's guard)
    /// while the listener mutex is held, so the close path — which rechecks
    /// the counter under both — cannot free the listener until this returns.
    fn releaseDial(self: *Network, listener: *InprocListener) void {
        const io = self.io;
        listener.mutex.lockUncancelable(io);
        self.lock.lock();
        listener.dialing -= 1;
        self.lock.unlock();
        listener.dial_drained.signal(io);
        listener.mutex.unlock(io);
    }

    fn register(self: *Network, designator: []const u8, listener: *InprocListener) error{ BindFailed, OutOfMemory }!void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.listeners.contains(designator)) return error.BindFailed;
        self.listeners.put(self.allocator, designator, listener) catch return error.OutOfMemory;
    }

    fn unregister(self: *Network, designator: []const u8) void {
        self.lock.lock();
        defer self.lock.unlock();
        _ = self.listeners.remove(designator);
    }
};

const netlayer_vtable = Netlayer.VTable{
    .transport_name = transport_name,
    .dial = dial,
    .listen = listen,
};

fn dial(
    ctx: *anyopaque,
    peer: *engine.Peer,
    loc: model.PeerLocator,
    bufs: Buffers,
) netlayer.DialError!Connection {
    const self: *Network = @ptrCast(@alignCast(ctx));
    const dialer = try self.dialEndpoint(loc.designator, bufs);
    return dialer.intoConnection(self.io, peer);
}

fn listen(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    config: netlayer.ListenConfig,
) netlayer.ListenError!Listener {
    const self: *Network = @ptrCast(@alignCast(ctx));
    const ml = try self.createListener(allocator, config.designator);
    return .{ .ctx = ml, .vtable = &listener_vtable };
}

const listener_vtable = Listener.VTable{
    .transport_name = transport_name,
    .accept = listenerAccept,
    .localDesignator = listenerLocalDesignator,
    .close = listenerClose,
};

/// A bound in-process listener: a queue of dialed-but-not-yet-accepted duplexes,
/// drained by `accept`.
pub const InprocListener = struct {
    network: *Network,
    allocator: std.mem.Allocator,
    designator: []u8,
    mutex: Io.Mutex = .init,
    arrived: Io.Condition = .init,
    /// Accepters currently parked inside `listenerAccept`'s wait. `listenerClose`
    /// must not free this listener while any of them could still reacquire the
    /// mutex or read the pending list, so it waits on `drained` until this
    /// returns to zero before tearing anything down.
    waiters: usize = 0,
    /// Signaled by the last parked accepter to leave the wait, releasing a
    /// closing `listenerClose` to free the listener.
    drained: Io.Condition = .init,
    /// Dials currently pinning this listener (between `Network.acquire` and
    /// `releaseDial`), guarded by the *network* lock so the pin is atomic with
    /// the registry lookup. `listenerClose` unregisters first — no new pin can
    /// form — then waits for this to reach zero before freeing anything.
    dialing: usize = 0,
    /// Signaled by `Network.releaseDial` when a pinning dial finishes,
    /// releasing a closing `listenerClose` to free the listener.
    dial_drained: Io.Condition = .init,
    pending: std.ArrayList(*Duplex) = .empty,
    closed: bool = false,

    fn enqueue(self: *InprocListener, duplex: *Duplex) error{ ConnectionLost, OutOfMemory }!void {
        const io = self.network.io;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        // A pinned dial can land after `listenerClose` swept the pending
        // list; admitting it would strand a duplex no accept ever drains, so
        // a closed listener refuses the connection instead.
        if (self.closed) return error.ConnectionLost;
        try self.pending.append(self.allocator, duplex);
        self.arrived.signal(io);
    }

    /// Block until a dialed duplex is queued and dequeue it, or return
    /// `ConnectionLost` if the listener closes with nothing pending. The shared
    /// accept-wait core of both the driver-path `accept` and the frame-stream
    /// `acceptFrameStream`, so the parked-waiter / close handshake lives once.
    fn waitForDuplex(self: *InprocListener) netlayer.AcceptError!*Duplex {
        const io = self.network.io;
        self.mutex.lockUncancelable(io);
        while (self.pending.items.len == 0 and !self.closed) {
            self.waiters += 1;
            self.arrived.waitUncancelable(io, &self.mutex);
            self.waiters -= 1;
            // A closing `listenerClose` parks until every waiter has left the
            // wait and re-checked `closed` under the mutex; the last one out
            // releases it.
            if (self.waiters == 0) self.drained.signal(io);
        }
        if (self.pending.items.len == 0) {
            self.mutex.unlock(io);
            return error.ConnectionLost; // closed with nothing pending
        }
        const duplex = self.pending.orderedRemove(0);
        self.mutex.unlock(io);
        return duplex;
    }

    /// Block for the next dialer and return a peer-less `InprocFrameStream` — the
    /// frame-stream sibling of the driver-path accept, for the C ABI listener.
    /// `read_buf` / `write_buf` are caller-owned and borrowed for the stream's life.
    pub fn acceptFrameStream(
        self: *InprocListener,
        allocator: std.mem.Allocator,
        codec_id: model.CodecId,
        max_frame_bytes: usize,
        read_buf: []u8,
        write_buf: []u8,
    ) netlayer.AcceptError!InprocFrameStream {
        const duplex = try self.waitForDuplex();
        const ep = acceptEndpoint(self.allocator, duplex, .{ .read = read_buf, .write = write_buf }) catch return error.OutOfMemory;
        return ep.intoFrameStream(self.network.io, allocator, codec_id, max_frame_bytes);
    }

    /// Stop accepting and free the listener. The frame-path name for the same
    /// teardown the driver-path contract reaches through the listener vtable's
    /// `close`.
    pub fn close(self: *InprocListener) void {
        listenerClose(self);
    }
};

/// Build the listener's endpoint over an accepted duplex (it writes the
/// listen-to-dial pipe and reads the dial-to-listen pipe, the mirror of the dialer).
/// On allocation failure the duplex is torn down so the dialer gets EOF. Shared
/// by the driver-path `accept` and the frame-stream `acceptFrameStream`.
fn acceptEndpoint(allocator: std.mem.Allocator, duplex: *Duplex, bufs: Buffers) std.mem.Allocator.Error!*Endpoint {
    return Endpoint.create(allocator, duplex, &duplex.dial_to_listen, &duplex.listen_to_dial, bufs) catch {
        duplex.dial_to_listen.close();
        duplex.listen_to_dial.close();
        duplex.release();
        return error.OutOfMemory;
    };
}

fn listenerAccept(ctx: *anyopaque, peer: *engine.Peer, bufs: Buffers) netlayer.AcceptError!Connection {
    const self: *InprocListener = @ptrCast(@alignCast(ctx));
    const duplex = try self.waitForDuplex();
    const ep = acceptEndpoint(self.allocator, duplex, bufs) catch return error.OutOfMemory;
    return ep.intoConnection(self.network.io, peer);
}

/// Read the pin count under its guard (the network lock). Called by
/// `listenerClose`'s wait loop while it holds the listener mutex; lock order is
/// listener mutex, then network lock, everywhere both are held.
fn dialsPinned(self: *InprocListener) bool {
    self.network.lock.lock();
    defer self.network.lock.unlock();
    return self.dialing > 0;
}

fn listenerLocalDesignator(ctx: *anyopaque, out: []u8) []const u8 {
    const self: *InprocListener = @ptrCast(@alignCast(ctx));
    // The contract forbids truncation: a partial designator is not a dialable
    // address, so an `out` too small yields the empty defect slice instead.
    if (out.len < self.designator.len) return out[0..0];
    @memcpy(out[0..self.designator.len], self.designator);
    return out[0..self.designator.len];
}

fn listenerClose(ctx: *anyopaque) void {
    const self: *InprocListener = @ptrCast(@alignCast(ctx));
    const io = self.network.io;
    self.network.unregister(self.designator);

    self.mutex.lockUncancelable(io);
    self.closed = true;
    // A dialer parked on a never-accepted duplex gets EOF, and its endpoint slot
    // is released on its behalf since this listener will never build it. The
    // list is only emptied here, not freed: a woken accepter still reads it.
    for (self.pending.items) |duplex| {
        duplex.dial_to_listen.close();
        duplex.listen_to_dial.close();
        duplex.release();
    }
    self.pending.clearRetainingCapacity();
    // Wake every parked accepter, then wait until each has left the wait and
    // observed `closed` under the mutex. Freeing the listener any earlier
    // would destroy the very mutex and pending list a woken accepter is about
    // to reacquire and read.
    self.arrived.broadcast(io);
    while (self.waiters > 0) self.drained.waitUncancelable(io, &self.mutex);
    // Then wait out every dial that pinned this listener through
    // `Network.acquire`. The registry entry is already gone, so no new pin
    // can form and the count only falls; each pinned dial either enqueued
    // before this close swept the pending list, or finds `closed` set and is
    // refused. Freeing earlier would destroy the listener under a dial that
    // already holds its pointer.
    while (dialsPinned(self)) self.dial_drained.waitUncancelable(io, &self.mutex);
    self.mutex.unlock(io);

    self.pending.deinit(self.allocator);
    self.allocator.free(self.designator);
    self.allocator.destroy(self);
}
