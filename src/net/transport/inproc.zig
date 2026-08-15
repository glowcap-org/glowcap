//! The in-process netlayer (`inproc`): a second resident behind the netlayer
//! contract, with no sockets at all.
//!
//! A `Network` is a switchboard. A listener binds to a designator, a dialer
//! names that designator, and the two are wired by a pair of in-process byte
//! pipes, one per direction, exposed as the same `*std.Io.Reader` /
//! `*std.Io.Writer` pair every other resident produces. The driver dials and
//! hosts it through the identical `connectVia` / `acceptVia` path, with the same
//! verified keyed handshake, and nothing in the driver or core knows which
//! transport it got. That is what the netlayer contract (`../netlayer.zig`)
//! buys: a resident with no sockets in it satisfies the contract unchanged.
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
//! yields). Teardown callbacks recover the resident's stored `std.Io` and use the
//! same primitives, so the mock transport does not carry a separate spin-lock
//! discipline from the production adapters.

const std = @import("std");

const foundation = @import("foundation");
const engine = @import("engine");
const model = @import("model");
const codec = @import("codec");
const netlayer = @import("../netlayer.zig");
const connection = @import("../connection.zig");
const frame_stream = @import("../frame_stream.zig");
const poll = @import("../poll.zig");
const wake_channel = @import("../wake_channel.zig");

const Io = std.Io;

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
const known_transport = model.transport.Known.inproc;
pub const transport_name = known_transport.metadata().symbol;

/// Build an in-process locator without parsing or allocating. The designator is
/// an opaque switchboard name borrowed until the dial path retains it.
pub fn locator(designator: []const u8) model.PeerLocator {
    return .{
        .transport = transport_name,
        .designator = designator,
        .hints = model.Hints.emptyFalse(),
    };
}

/// An adapter-owned edge notification for a listener arrival, in addition to
/// the listener's own pollable readiness channel. Used when an embedding needs
/// a callback edge rather than a borrowed descriptor.
pub const ArrivalNotifier = struct {
    ctx: *anyopaque,
    notify_fn: *const fn (*anyopaque) void,

    /// Must return promptly and must not synchronously close or re-enter its
    /// listener. The listener pins this call across concurrent close.
    fn notify(self: ArrivalNotifier) void {
        self.notify_fn(self.ctx);
    }
};

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

    fn write(self: *Channel, bytes: []const u8) (std.mem.Allocator.Error || error{Closed})!void {
        if (bytes.len == 0) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.Closed;
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
    io: Io,
    dial_to_listen: Channel,
    listen_to_dial: Channel,
    refs_lock: Io.Mutex = .init,
    refs: usize = 2,

    fn create(allocator: std.mem.Allocator, io: Io) std.mem.Allocator.Error!*Duplex {
        const self = try allocator.create(Duplex);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .dial_to_listen = .{ .allocator = allocator, .io = io },
            .listen_to_dial = .{ .allocator = allocator, .io = io },
        };
        return self;
    }

    fn release(self: *Duplex) void {
        self.refs_lock.lockUncancelable(self.io);
        self.refs -= 1;
        const remaining = self.refs;
        self.refs_lock.unlock(self.io);
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

/// The owner side of an inproc `Endpoint`: the shared `Duplex` to release and
/// the write channel to close on teardown. Closing the write side gives the
/// partner's reader a clean EOF; releasing the duplex drops this end's share of
/// the pipe pair.
const InprocContext = struct {
    duplex: *Duplex,
    write_chan: *Channel,

    pub fn closeStream(self: InprocContext) void {
        self.write_chan.close();
        self.duplex.release();
    }

    fn shutdown(self: InprocContext) void {
        self.duplex.dial_to_listen.close();
        self.duplex.listen_to_dial.close();
    }
};

/// One end of a connection, the shared `netlayer.PinnedStream` over an
/// in-process `ChannelSource` pipe pair (the vtable recovers the concrete
/// reader/writer from `&interface` by field offset, exactly as tcp's
/// `TcpStream`). Closing it signals EOF to the partner and releases the shared
/// duplex.
const Endpoint = netlayer.PinnedStream(ChannelSource, InprocContext);

/// Pin one endpoint over the duplex's two channels: `read_chan` inbound,
/// `write_chan` outbound. The context owns the duplex and the write channel the
/// generic's `close` hook needs.
fn endpointCreate(
    allocator: std.mem.Allocator,
    duplex: *Duplex,
    read_chan: *Channel,
    write_chan: *Channel,
    bufs: Buffers,
) std.mem.Allocator.Error!*Endpoint {
    return Endpoint.create(
        allocator,
        .{ .chan = read_chan },
        .{ .chan = write_chan },
        bufs,
        .{ .duplex = duplex, .write_chan = write_chan },
    );
}

/// Build a peer-less `InprocFrameStream` over `endpoint`, the host-driven frame
/// boundary the C ABI sits on, where the host owns the peer. The mirror of
/// `Endpoint.intoConnection` for the frame-stream path.
fn endpointFrameStream(endpoint: *Endpoint, io: Io, allocator: std.mem.Allocator, codec_id: model.CodecId, max_frame_bytes: usize) InprocFrameStream {
    return .{
        .endpoint = endpoint,
        .io = io,
        .codec_id = codec_id,
        .max_frame_bytes = max_frame_bytes,
        .allocator = allocator,
    };
}

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
    /// How far the codec has got framing the partial frame at the front of the
    /// supply; the tcp `FrameStream` keeps the same state for the same reason.
    scan: codec.framing.StreamScan = .{},

    /// Block for one whole `codec_id` frame as an owned `Frame`; `Closed` on the
    /// partner's graceful EOF.
    pub fn readFrame(self: *InprocFrameStream) frame_stream.FrameError!foundation.Frame {
        return frame_stream.readFrameFrom(&self.endpoint.reader.interface, self.allocator, self.codec_id, self.max_frame_bytes, &self.spill, &self.scan);
    }

    /// Write one frame's borrowed bytes into the partner's pipe.
    pub fn writeFrame(self: *InprocFrameStream, bytes: []const u8) frame_stream.FrameError!void {
        return frame_stream.writeFrameTo(&self.endpoint.writer.interface, bytes);
    }

    pub fn deinit(self: *InprocFrameStream) void {
        self.spill.deinit(self.allocator);
        Endpoint.close(self.endpoint);
    }

    /// Interrupt blocked reads and writes without freeing the endpoint.
    /// Release remains a separate operation after every caller has returned.
    pub fn shutdown(self: *InprocFrameStream) void {
        self.endpoint.context.shutdown();
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
    lock: Io.Mutex = .init,
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
        return endpointFrameStream(dialer, self.io, self.allocator, codec_id, max_frame_bytes);
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
        const wake = wake_channel.WakeChannel.open() catch return error.BindFailed;
        errdefer wake.deinit();
        ml.* = .{ .network = self, .allocator = allocator, .designator = owned, .wake = wake };
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
        // No endpoint registered at this designator is the in-process
        // refused-partner case (ADR-0081): the peer is not listening.
        const listener = self.acquire(designator) orelse return error.ConnectionRefused;
        defer self.releaseDial(listener);

        const duplex = try Duplex.create(self.allocator, self.io);
        var duplex_armed = false;
        errdefer if (!duplex_armed) {
            duplex.dial_to_listen.deinit();
            duplex.listen_to_dial.deinit();
            self.allocator.destroy(duplex);
        };

        // The dialer writes the dial→listen pipe and reads the listen→dial pipe.
        const dialer = try endpointCreate(self.allocator, duplex, &duplex.listen_to_dial, &duplex.dial_to_listen, bufs);
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
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const listener = self.listeners.get(designator) orelse return null;
        listener.dialing += 1;
        return listener;
    }

    /// Drop a dial's pin on `listener` and wake a `listenerClose` parked on
    /// it. The decrement happens under the network lock (the counter's guard)
    /// while the listener mutex is held, so the close path, which rechecks
    /// the counter under both — cannot free the listener until this returns.
    fn releaseDial(self: *Network, listener: *InprocListener) void {
        const io = self.io;
        listener.mutex.lockUncancelable(io);
        self.lock.lockUncancelable(io);
        listener.dialing -= 1;
        self.lock.unlock(io);
        listener.dial_drained.signal(io);
        listener.mutex.unlock(io);
    }

    fn register(self: *Network, designator: []const u8, listener: *InprocListener) error{ BindFailed, OutOfMemory }!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        if (self.listeners.contains(designator)) return error.BindFailed;
        self.listeners.put(self.allocator, designator, listener) catch return error.OutOfMemory;
    }

    fn unregister(self: *Network, designator: []const u8) void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        // idempotent: deregister teardown, tolerant of a designator that was
        // never registered or already removed.
        _ = self.listeners.remove(designator);
    }
};

fn networkIo(ctx: *anyopaque) ?std.Io {
    const self: *Network = @ptrCast(@alignCast(ctx));
    return self.io;
}

const netlayer_vtable = Netlayer.VTable{
    .profile = known_transport.metadata(),
    .dial = .{ .blocking = dial },
    .listen = listen,
    .io = networkIo,
};

fn dial(
    ctx: *anyopaque,
    peer: *engine.Peer,
    loc: model.PeerLocator,
    bufs: Buffers,
    options: netlayer.OperationOptions,
) netlayer.DialError!Connection {
    try options.requireInherited();
    const self: *Network = @ptrCast(@alignCast(ctx));
    const dialer = try self.dialEndpoint(loc.designator, bufs);
    return dialer.intoConnection(self.io, peer);
}

fn listen(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    config: netlayer.ListenConfig,
) netlayer.ListenStartOutcome {
    return .{ .admitted = listenFallible(ctx, allocator, config) catch |err|
        return .{ .failed = .init(err) } };
}

fn listenFallible(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    config: netlayer.ListenConfig,
) netlayer.ListenError!netlayer.ListenResult {
    try config.options.requireInherited();
    const self: *Network = @ptrCast(@alignCast(ctx));
    const ml = try self.createListener(allocator, config.designator);
    return .{ .ready = .{ .ctx = ml, .vtable = &listener_vtable } };
}

const listener_vtable = Listener.VTable{
    .transport_name = transport_name,
    .designator_scheme = known_transport.metadata().designator_scheme,
    .sealed_channel = known_transport.metadata().sealed_channel,
    .accept = listenerAccept,
    .waitAcceptable = listenerWaitAcceptable,
    .localLocator = listenerLocalLocator,
    .canonicalizeLocator = listenerCanonicalizeLocator,
    .close = listenerClose,
};

/// A bound in-process listener: a queue of dialed-but-not-yet-accepted duplexes,
/// drained by `accept`.
pub const InprocListener = struct {
    network: *Network,
    allocator: std.mem.Allocator,
    designator: []u8,
    /// No application bytes flow here. It turns in-process queue arrival and
    /// shutdown into the same pollable readiness contract socket listeners use.
    wake: wake_channel.WakeChannel,
    wake_failure: wake_channel.FailureLatch = .{},
    mutex: Io.Mutex = .init,
    arrived: Io.Condition = .init,
    /// Accept and readiness operations that may still touch this listener.
    /// This counts the whole operation, including finite waits that sleep with
    /// the mutex released; close joins it before freeing listener storage.
    operations: usize = 0,
    operations_drained: Io.Condition = .init,
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
    arrival_notifier: ?ArrivalNotifier = null,
    /// Notifier callbacks currently outside the listener mutex. Close waits
    /// for this pin before the adapter-owned callback context may be freed.
    notifying: usize = 0,
    notify_drained: Io.Condition = .init,

    /// Install one adapter-owned readiness edge. A pending dial is signaled
    /// immediately, so attaching after registration cannot lose an arrival.
    /// The notifier owner must outlive this listener and may release it only
    /// after `close` returns.
    pub fn setArrivalNotifier(self: *InprocListener, notifier: ArrivalNotifier) void {
        const io = self.network.io;
        self.mutex.lockUncancelable(io);
        std.debug.assert(self.arrival_notifier == null);
        self.arrival_notifier = notifier;
        const pending = self.pending.items.len != 0;
        if (pending) self.notifyArrivalPinned();
        self.mutex.unlock(io);
    }

    /// Borrowed readiness descriptor. The listener owns it through `close`.
    pub fn readinessFd(self: *const InprocListener) i32 {
        return self.wake.read;
    }

    /// Invoke the installed notifier without holding the listener mutex while
    /// retaining an in-flight pin that `listenerClose` drains. Called with the
    /// mutex held and returns with it held.
    fn notifyArrivalPinned(self: *InprocListener) void {
        const notifier = self.arrival_notifier orelse return;
        const io = self.network.io;
        self.notifying += 1;
        self.mutex.unlock(io);
        notifier.notify();
        self.mutex.lockUncancelable(io);
        self.notifying -= 1;
        if (self.notifying == 0) self.notify_drained.signal(io);
    }

    fn enqueue(self: *InprocListener, duplex: *Duplex) error{ ConnectionLost, OutOfMemory, WakeNudgeFailed }!void {
        const io = self.network.io;
        self.mutex.lockUncancelable(io);
        // A pinned dial can land after `listenerClose` swept the pending
        // list; admitting it would strand a duplex no accept ever drains, so
        // a closed listener refuses the connection instead.
        if (self.closed) {
            self.mutex.unlock(io);
            return error.ConnectionLost;
        }
        self.pending.append(self.allocator, duplex) catch |err| {
            self.mutex.unlock(io);
            return err;
        };
        _ = self.wake.nudge() catch |err| {
            std.debug.assert(self.pending.pop() == duplex);
            self.wake_failure.record(err);
            self.closed = true;
            self.arrived.broadcast(io);
            self.mutex.unlock(io);
            return err;
        };
        self.arrived.signal(io);
        self.notifyArrivalPinned();
        self.mutex.unlock(io);
    }

    /// Block until a dialed duplex is queued and dequeue it, or return
    /// `ConnectionLost` if the listener closes with nothing pending. The shared
    /// accept-wait core of both the driver-path `accept` and the frame-stream
    /// `acceptFrameStream`, so the parked-waiter / close handshake lives once.
    /// A dequeued duplex plus the listener fields the caller needs after the
    /// mutex is released. Once the duplex is off the pending list and the
    /// operation lease is retired, a concurrent `listenerClose` may free the
    /// listener out from under the remaining endpoint construction.
    /// Snapshotting `allocator` and `network` (both outlive the listener struct)
    /// under the mutex lets the caller finish the accept without touching `self`.
    const Accepted = struct {
        duplex: *Duplex,
        allocator: std.mem.Allocator,
        network: *Network,
    };

    fn waitUntilPendingOrClosed(self: *InprocListener) void {
        const io = self.network.io;
        while (self.pending.items.len == 0 and !self.closed) {
            self.arrived.waitUncancelable(io, &self.mutex);
        }
    }

    fn waitForDuplex(self: *InprocListener) netlayer.AcceptError!Accepted {
        const io = self.network.io;
        self.mutex.lockUncancelable(io);
        self.operations += 1;
        defer {
            self.operations -= 1;
            if (self.operations == 0) self.operations_drained.signal(io);
            self.mutex.unlock(io);
        }
        try self.wake_failure.check();
        self.waitUntilPendingOrClosed();
        try self.wake_failure.check();
        if (self.pending.items.len == 0) {
            return error.ConnectionLost; // closed with nothing pending
        }
        self.wake.drain() catch |err| {
            self.wake_failure.record(err);
            self.closed = true;
            self.arrived.broadcast(io);
            return err;
        };
        const notify_more = self.pending.items.len > 1;
        if (notify_more) {
            _ = self.wake.nudge() catch |err| {
                self.wake_failure.record(err);
                self.closed = true;
                self.arrived.broadcast(io);
                return err;
            };
            self.notifyArrivalPinned();
        }
        return .{
            .duplex = self.pending.orderedRemove(0),
            .allocator = self.allocator,
            .network = self.network,
        };
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
        const accepted = try self.waitForDuplex();
        // `self` may already be freed by a concurrent `listenerClose`; use only
        // the fields snapshotted under the mutex.
        const ep = acceptEndpoint(accepted.allocator, accepted.duplex, .{ .read = read_buf, .write = write_buf }) catch return error.OutOfMemory;
        return endpointFrameStream(ep, accepted.network.io, allocator, codec_id, max_frame_bytes);
    }

    /// Stop accepting and free the listener. The frame-path name for the same
    /// teardown the driver-path contract reaches through the listener vtable's
    /// `close`.
    pub fn close(self: *InprocListener) ?netlayer.ListenerCloseFailure {
        return listenerClose(self);
    }

    /// Stop admission and wake blocked accepters without freeing the listener.
    /// Idempotent so a foreign runtime can cancel, join its accept lease, then
    /// call `close` for the one ownership release.
    pub fn shutdown(self: *InprocListener) void {
        listenerShutdown(self);
    }
};

/// Build the listener's endpoint over an accepted duplex (it writes the
/// listen-to-dial pipe and reads the dial-to-listen pipe, the mirror of the dialer).
/// On allocation failure the duplex is torn down so the dialer gets EOF. Shared
/// by the driver-path `accept` and the frame-stream `acceptFrameStream`.
fn acceptEndpoint(allocator: std.mem.Allocator, duplex: *Duplex, bufs: Buffers) std.mem.Allocator.Error!*Endpoint {
    return endpointCreate(allocator, duplex, &duplex.dial_to_listen, &duplex.listen_to_dial, bufs) catch {
        duplex.dial_to_listen.close();
        duplex.listen_to_dial.close();
        duplex.release();
        return error.OutOfMemory;
    };
}

fn listenerWaitAcceptable(ctx: *anyopaque, timeout_ms: i32) netlayer.AcceptError!bool {
    const self: *InprocListener = @ptrCast(@alignCast(ctx));
    const io = self.network.io;
    self.mutex.lockUncancelable(io);
    self.operations += 1;
    defer {
        self.operations -= 1;
        if (self.operations == 0) self.operations_drained.signal(io);
        self.mutex.unlock(io);
    }
    try self.wake_failure.check();
    if (self.pending.items.len != 0) return true;
    if (self.closed) return error.ConnectionLost;
    self.mutex.unlock(io);
    var fds = [_]std.posix.pollfd{.{
        .fd = self.wake.read,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = poll.wait(&fds, timeout_ms) catch {
        self.mutex.lockUncancelable(io);
        return error.ConnectionLost;
    };
    self.mutex.lockUncancelable(io);
    try self.wake_failure.check();
    if (self.closed and self.pending.items.len == 0) return error.ConnectionLost;
    return ready != 0 and self.pending.items.len != 0;
}

fn listenerAccept(ctx: *anyopaque, peer: *engine.Peer, bufs: Buffers) netlayer.AcceptError!Connection {
    const self: *InprocListener = @ptrCast(@alignCast(ctx));
    const accepted = try self.waitForDuplex();
    // `self` may already be freed by a concurrent `listenerClose`; use only the
    // fields snapshotted under the mutex.
    const ep = acceptEndpoint(accepted.allocator, accepted.duplex, bufs) catch return error.OutOfMemory;
    return ep.intoConnection(accepted.network.io, peer);
}

/// Read the pin count under its guard (the network lock). Called by
/// `listenerClose`'s wait loop while it holds the listener mutex; lock order is
/// listener mutex, then network lock, everywhere both are held.
fn dialsPinned(self: *InprocListener) bool {
    const io = self.network.io;
    self.network.lock.lockUncancelable(io);
    defer self.network.lock.unlock(io);
    return self.dialing > 0;
}

fn listenerLocalLocator(ctx: *anyopaque, allocator: std.mem.Allocator) netlayer.ListenError!model.PeerLocator {
    const self: *InprocListener = @ptrCast(@alignCast(ctx));
    return model.clonePeerLocator(allocator, .{
        .transport = transport_name,
        .designator = self.designator,
    });
}

fn listenerCanonicalizeLocator(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    candidate: model.PeerLocator,
) netlayer.ListenError!model.PeerLocator {
    const self: *InprocListener = @ptrCast(@alignCast(ctx));
    return netlayer.canonicalizeFixedLocator(allocator, candidate, transport_name, self.designator);
}

fn listenerClose(ctx: *anyopaque) ?netlayer.ListenerCloseFailure {
    const self: *InprocListener = @ptrCast(@alignCast(ctx));
    listenerShutdown(self);
    const io = self.network.io;
    self.mutex.lockUncancelable(io);
    // `listenerShutdown` woke every parked operation. Join the complete
    // accept/readiness call, including finite waits that released this mutex;
    // only then may storage free.
    while (self.operations > 0) self.operations_drained.waitUncancelable(io, &self.mutex);
    // Then wait out every dial that pinned this listener through
    // `Network.acquire`. The registry entry is already gone, so no new pin
    // can form and the count only falls; each pinned dial either enqueued
    // before this close swept the pending list, or finds `closed` set and is
    // refused. Freeing earlier would destroy the listener under a dial that
    // already holds its pointer.
    while (dialsPinned(self)) self.dial_drained.waitUncancelable(io, &self.mutex);
    // A notifier runs outside this mutex so a wake implementation never joins
    // the listener's lock graph. Its explicit pin keeps the adapter payload
    // alive until the final callback returns.
    while (self.notifying > 0) self.notify_drained.waitUncancelable(io, &self.mutex);
    self.mutex.unlock(io);

    self.pending.deinit(self.allocator);
    self.wake.deinit();
    self.allocator.free(self.designator);
    const failure = if (self.wake_failure.failure()) |err|
        netlayer.ListenerCloseFailure.init(err)
    else
        null;
    self.allocator.destroy(self);
    return failure;
}

fn listenerShutdown(self: *InprocListener) void {
    const io = self.network.io;
    self.network.unregister(self.designator);
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    if (self.closed) return;
    self.closed = true;
    // A dialer parked on a never-accepted duplex gets EOF, and its endpoint slot
    // is released on its behalf since this listener will never build it.
    for (self.pending.items) |duplex| {
        duplex.dial_to_listen.close();
        duplex.listen_to_dial.close();
        duplex.release();
    }
    self.pending.clearRetainingCapacity();
    self.arrived.broadcast(io);
    _ = self.wake.nudge() catch |err| self.wake_failure.record(err);
    // The adapter readiness edge represents either an arrival or terminal
    // closure. A reactor parked on the synthetic fd must wake for both.
    self.notifyArrivalPinned();
}
