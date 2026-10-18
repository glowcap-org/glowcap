//! The in-process netlayer (`inproc`): a resident behind the netlayer
//! contract with no sockets at all.
//!
//! A `Network` is a switchboard. A listener binds to a designator, a dialer
//! names that designator, and the two are wired by a pair of in-process byte
//! pipes, one per direction, exposed as the same `*std.Io.Reader` /
//! `*std.Io.Writer` pair every other resident produces. A resident with no
//! sockets in it satisfies the netlayer contract (`../netlayer.zig`)
//! unchanged. The runtime's `driver.connect` and `driver.listen` reach an
//! in-process partner through the completion-loop sibling,
//! `inproc_completion`, with the same verified keyed handshake every other
//! transport runs.
//!
//! This transport is for in-process testing and mocking: a full OCapN
//! conversation between two peers in one program, with no kernel transport and no
//! file descriptors, so a test exercises the protocol without socket timing or fd
//! limits. The pipes block the reading thread until the partner writes, which is
//! correct under a threaded `std.Io` (the handshake's two halves run on two
//! fibers). It is not built for high-fan-out production, where the completion loop
//! and a real transport carry the load. Pipe buffers are unbounded here
//! because a mock has a cooperative partner, so it does not need the inbound
//! read bounds a real netlayer holds.
//!
//! Blocking uses `std.Io.Mutex` / `std.Io.Condition`, the io-aware primitives, so
//! one handshake half parks until the other produces bytes under whatever `std.Io`
//! backs the conversation (a threaded backend blocks the thread, a fiber backend
//! yields). Teardown callbacks recover the resident's stored `std.Io` and use the
//! same primitives, so the mock transport does not carry a separate spin-lock
//! discipline from the production adapters.

const std = @import("std");

const engine = @import("engine");
const model = @import("model");
const netlayer = @import("../netlayer.zig");
const connection = @import("../connection.zig");
const poll = @import("../poll.zig");
const wake_channel = @import("../wake_channel.zig");
const stream = @import("inproc/stream.zig");

const Io = std.Io;

const Connection = connection.Connection;
const Netlayer = netlayer.Netlayer;
const Buffers = netlayer.Buffers;
// Aliased so the `Network` struct's `netlayer()` method does not shadow the
// `netlayer` module import when these error sets are named inside its body.
const DialError = netlayer.DialError;
const ListenError = netlayer.ListenError;
const AcceptError = netlayer.AcceptError;
const Duplex = stream.Duplex;
const Endpoint = stream.Endpoint;
pub const InprocFrameStream = stream.FrameStream;

/// The transport symbol this resident registers under and signs into
/// `op:start-session`. Matches the `glowcap_inproc_*` C ABI family.
const known_transport = model.transport.Known.inproc;
pub const transport_name = known_transport.metadata().symbol;

/// Build an in-process locator without parsing or allocating. The designator is
/// an opaque switchboard name borrowed until the dial path retains it.
pub fn locator(designator: []const u8) model.PeerLocator {
    return .hintless(transport_name, designator);
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

// ── The switchboard ──────────────────────────────────────────────────────────

/// The in-process network: the shared state behind one or more `inproc` netlayer
/// residents. Listeners register by designator. Dialers resolve against it. One
/// network per test (or per process region). `network.netlayer()` is the
/// network as a stream netlayer, the shape `test/net` drives. The network must
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

    /// This network as a `net.netlayer.Netlayer`.
    pub fn netlayer(self: *Network) Netlayer {
        return .{ .ctx = self, .vtable = &netlayer_vtable };
    }

    /// Dial `designator` and return a peer-less `InprocFrameStream`, the
    /// host-driven frame boundary the C ABI sits on. The frame-stream sibling of
    /// the driver-path `dial`. `read_buf` / `write_buf` are caller-owned and
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
        return stream.frameStream(dialer, self.io, self.allocator, codec_id, max_frame_bytes);
    }

    /// Bind a frame-level listener on `designator`, returning the raw
    /// `*InprocListener` whose `acceptFrameStream` yields peer-less streams (the
    /// C ABI listener handle). The driver-path `listen` wraps the same listener in
    /// the netlayer vtable. This hands it back directly. Close with
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
    /// and the frame-stream `connectFrameStream`. The concurrency (pinning the
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
        const dialer = try stream.endpointCreate(self.allocator, duplex, &duplex.listen_to_dial, &duplex.dial_to_listen, bufs);
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
    /// the counter under both, cannot free the listener until this returns.
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
    .dial = .{ .blocking = netlayer.adaptBlockingDial(dial) },
    .listen = netlayer.adaptListen(listen),
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
) netlayer.ListenError!netlayer.ListenResult {
    try config.options.requireInherited();
    const self: *Network = @ptrCast(@alignCast(ctx));
    const ml = try self.createListener(allocator, config.designator);
    return .{ .ready = ListenerShell.listener(ml) };
}

/// The contract listener over an `InprocListener`, which owns its own storage
/// and frees it in `close`. Readiness stays behind `waitAcceptable`. The
/// synthetic wake descriptor is not published as the contract's `readiness_fd`.
const ListenerShell = netlayer.ListenerShell(struct {
    pub const State = InprocListener;
    pub const metadata = known_transport.metadata();

    pub const accept = listenerAccept;
    pub const waitAcceptable = listenerWaitAcceptable;
    pub const localLocator = listenerLocalLocator;
    pub const canonicalizeLocator = listenerCanonicalizeLocator;
    pub const close = listenerClose;
});

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
    /// the mutex released. Close joins it before freeing listener storage.
    operations: usize = 0,
    operations_drained: Io.Condition = .init,
    /// Dials currently pinning this listener (between `Network.acquire` and
    /// `releaseDial`), guarded by the *network* lock so the pin is atomic with
    /// the registry lookup. `listenerClose` unregisters first, no new pin can
    /// form, then waits for this to reach zero before freeing anything.
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

    /// Block for the next dialer and return a peer-less `InprocFrameStream`, the
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
        return stream.frameStream(ep, accepted.network.io, allocator, codec_id, max_frame_bytes);
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
    return stream.endpointCreate(allocator, duplex, &duplex.dial_to_listen, &duplex.listen_to_dial, bufs) catch {
        duplex.dial_to_listen.close();
        duplex.listen_to_dial.close();
        duplex.release();
        return error.OutOfMemory;
    };
}

fn listenerWaitAcceptable(self: *InprocListener, timeout_ms: i32) netlayer.AcceptError!bool {
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

fn listenerAccept(self: *InprocListener, peer: *engine.Peer, bufs: Buffers) netlayer.AcceptError!Connection {
    const accepted = try self.waitForDuplex();
    // `self` may already be freed by a concurrent `listenerClose`; use only the
    // fields snapshotted under the mutex.
    const ep = acceptEndpoint(accepted.allocator, accepted.duplex, bufs) catch return error.OutOfMemory;
    return ep.intoConnection(accepted.network.io, peer);
}

/// Read the pin count under its guard (the network lock). Called by
/// `listenerClose`'s wait loop while it holds the listener mutex. Lock order is
/// listener mutex, then network lock, everywhere both are held.
fn dialsPinned(self: *InprocListener) bool {
    const io = self.network.io;
    self.network.lock.lockUncancelable(io);
    defer self.network.lock.unlock(io);
    return self.dialing > 0;
}

fn listenerLocalLocator(self: *InprocListener, allocator: std.mem.Allocator) netlayer.ListenError!model.PeerLocator {
    return model.clonePeerLocator(allocator, .{
        .transport = transport_name,
        .designator = self.designator,
    });
}

fn listenerCanonicalizeLocator(
    self: *InprocListener,
    allocator: std.mem.Allocator,
    candidate: model.PeerLocator,
) netlayer.ListenError!model.PeerLocator {
    return netlayer.canonicalizeFixedLocator(allocator, candidate, transport_name, self.designator);
}

fn listenerClose(self: *InprocListener) ?netlayer.ListenerCloseFailure {
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
