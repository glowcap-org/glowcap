//! Inline state and supported completion-backend facade for WebRTC.

const std = @import("std");
const model = @import("model");
const net = @import("net");
const sidecar = @import("../sidecar.zig");
const connections = @import("connections.zig");
const lifecycle = @import("lifecycle.zig");
const readiness = @import("readiness.zig");
const signaling = @import("signaling.zig");

const completion = net.completion;
const BufferPool = completion.BufferPool;
const Peer = sidecar.Peer;
const Resident = sidecar.Resident;

pub const DialResolver = signaling.DialResolver;
pub const SignalingAuthority = signaling.SignalingAuthority;
pub const max_signal_bytes = signaling.signaling_frame_bytes;

/// The WebRTC completion backend for `net.completion.Loop`: one resident
/// readiness fd and non-blocking try-I/O adapted to the socket-shaped completion
/// contract.
///
/// Construct with `initBound`, then pass this value to
/// `completion.Loop(Backend, DialResolver).initWithBackend`. Outbound dials
/// create an offerer and complete only on `ev_open`. Inbound answerers exist
/// because `startAnswer` built one from an offer the signaling owner handed
/// in, or because that owner built one by hand and transferred it through
/// `adoptAnswerer`. They join the ordinary accept completion only after open.
///
/// `startAnswer`, `adoptAnswerer`, `provideAnswer`, and
/// `provideRemoteCandidate` are the four thread-safe entries. They queue under
/// one spinlock and nudge the loop wake fd. All other state belongs to the
/// loop thread. The resident must outlive this backend and have no other
/// readiness consumer. Producers and wake callers must stop before `deinit`
/// closes the wake fd.
///
/// State stays inline: the behavioral owners below are compile-time method
/// indexes, not runtime objects or mirrors.
pub const Backend = struct {
    const Self = @This();

    pub const Fd = i32;
    pub const ConnectTarget = signaling.ConnectTarget;
    pub const ListenerAddress = void;

    /// Sentinel listen handle: reachability is a signaling inbox, not a socket.
    pub const listen_fd: Fd = 0;

    /// One open DataChannel's adapter row: the sidecar peer beside the seats,
    /// hints, and terminal cause every multiplexed sidecar backend shares.
    /// Tests pin this exact cost so the scale path cannot grow unnoticed.
    pub const connection_state_bytes = @sizeOf(connections.Entry);

    const ConnectionOps = connections.Machine(Self, Fd);
    const SignalingOps = signaling.Machine(Self, Fd, ConnectionOps);
    const LifecycleOps = lifecycle.Machine(Self, Fd);
    const ReadinessOps = readiness.Machine(Self, SignalingOps, ConnectionOps);

    allocator: std.mem.Allocator,
    /// Borrowed. Must outlive the backend.
    resident: *Resident,
    signaling: SignalingAuthority,
    readiness_fd: i32,
    /// Completions that need no further readiness, drained before blocking.
    ready: completion.ReadyQueue = .{},
    /// Adopted-answer outcomes waiting for a submitAccept owner.
    accept_stash: std.ArrayList(signaling.AcceptOutcome) = .empty,
    accept_ud: ?u64 = null,
    /// Synthetic descriptors minted monotonically by this backend.
    conns: std.AutoHashMap(Fd, connections.Entry),
    /// Sidecar peer id to synthetic fd, including pre-open rows.
    by_id: std.AutoHashMap(usize, Fd),
    /// Offerer bring-ups in flight by signaling exchange fd.
    pending_dials: std.AutoHashMap(Fd, signaling.DialRow),
    /// Adopted answerers not yet open.
    adopting: std.AutoHashMap(Fd, signaling.AdoptRow),
    /// Guards fd minting and the fixed-capacity foreign-thread inbox. No
    /// `std.Io` token crosses this seam, so the critical section contains only
    /// integer and pre-reserved slice-header mutation.
    signal_mutex: net.sync.SpinLock = .{},
    signal_in: std.ArrayList(signaling.SignalIn) = .empty,
    /// Seats reserved while a producer fills its exclusive payload slot. A row
    /// is not visible until its copy completes. This prevents producers from
    /// oversubscribing the inbox in that interval.
    signal_reservations: usize = 0,
    signal_payloads: signaling.SignalPayloadPool,
    /// Wake pair for foreign-thread signaling and owner stop requests.
    signal_wake: net.wake_channel.WakeChannel,
    signal_wake_failure: net.wake_channel.FailureLatch = .{},
    /// One descriptor over the signaling wake and the sidecar's readiness:
    /// this backend's own readiness descriptor.
    ready_set: net.readiness.ReadySet,
    /// Loop-owned queue swapped with signal_in without per-wake allocation,
    /// preserving the inbox's pre-reserved capacity while work is applied.
    signal_work: std.ArrayList(signaling.SignalIn) = .empty,
    next_fd: Fd = 1,
    /// Descriptors outside this backend that a `submitPoll` waits on.
    watched: std.ArrayList(readiness.Watched) = .empty,
    /// The park's poll set, this backend's readiness then each watch.
    /// `submitPoll` sizes it and `initBound` seats the readiness row.
    park_fds: std.ArrayList(std.posix.pollfd) = .empty,
    buffer_pool: BufferPool,

    /// Bind the resident and preallocate every bounded endpoint-level pool.
    pub fn initBound(
        allocator: std.mem.Allocator,
        resident: *Resident,
        authority: SignalingAuthority,
        read_buffers: u16,
        read_buffer_bytes: u32,
    ) !Backend {
        const signal_wake = try net.wake_channel.WakeChannel.open();
        errdefer signal_wake.deinit();
        var buffer_pool = try BufferPool.init(allocator, read_buffers, read_buffer_bytes);
        errdefer buffer_pool.deinit();
        var signal_in = std.ArrayList(signaling.SignalIn).empty;
        errdefer signal_in.deinit(allocator);
        try signal_in.ensureTotalCapacity(allocator, signaling.max_signal_in);
        var signal_work = std.ArrayList(signaling.SignalIn).empty;
        errdefer signal_work.deinit(allocator);
        try signal_work.ensureTotalCapacity(allocator, signaling.max_signal_in);
        var accept_stash = std.ArrayList(signaling.AcceptOutcome).empty;
        errdefer accept_stash.deinit(allocator);
        try accept_stash.ensureTotalCapacity(allocator, signaling.max_accept_stash);
        var signal_payloads = try signaling.SignalPayloadPool.init(allocator);
        errdefer signal_payloads.deinit(allocator);
        var park_fds = std.ArrayList(std.posix.pollfd).empty;
        errdefer park_fds.deinit(allocator);
        try park_fds.ensureTotalCapacity(allocator, 1);
        const fd = resident.readinessFd();
        if (fd < 0) return error.ListenFailed;
        var ready_set = try net.readiness.ReadySet.init();
        errdefer ready_set.deinit();
        try ready_set.add(signal_wake.read);
        try ready_set.add(fd);
        return .{
            .allocator = allocator,
            .resident = resident,
            .signaling = authority,
            .readiness_fd = fd,
            .conns = std.AutoHashMap(Fd, connections.Entry).init(allocator),
            .by_id = std.AutoHashMap(usize, Fd).init(allocator),
            .pending_dials = std.AutoHashMap(Fd, signaling.DialRow).init(allocator),
            .adopting = std.AutoHashMap(Fd, signaling.AdoptRow).init(allocator),
            .signal_in = signal_in,
            .signal_payloads = signal_payloads,
            .signal_wake = signal_wake,
            .ready_set = ready_set,
            .signal_work = signal_work,
            .accept_stash = accept_stash,
            .park_fds = park_fds,
            .buffer_pool = buffer_pool,
        };
    }

    /// Producers must be stopped before teardown closes the shared wake pair.
    pub fn deinit(self: *Backend) void {
        var dial_it = self.pending_dials.valueIterator();
        while (dial_it.next()) |row| {
            var peer = row.peer;
            peer.deinit();
            self.allocator.free(row.designator);
        }
        self.pending_dials.deinit();
        var adopt_it = self.adopting.valueIterator();
        while (adopt_it.next()) |row| {
            var peer = row.peer;
            peer.deinit();
        }
        self.adopting.deinit();
        var conn_it = self.conns.valueIterator();
        while (conn_it.next()) |entry| {
            var peer = entry.peer;
            peer.deinit();
        }
        self.conns.deinit();
        self.by_id.deinit();
        for (self.accept_stash.items) |*outcome| switch (outcome.*) {
            .connected => |*held| held.peer.deinit(),
            .failed => {},
        };
        self.accept_stash.deinit(self.allocator);
        for (self.signal_in.items) |queued| SignalingOps.freeQueued(self, queued);
        self.signal_in.deinit(self.allocator);
        for (self.signal_work.items) |queued| SignalingOps.freeQueued(self, queued);
        self.signal_work.deinit(self.allocator);
        std.debug.assert(self.signal_reservations == 0);
        self.signal_payloads.deinit(self.allocator);
        self.ready_set.deinit();
        self.signal_wake.deinit();
        self.ready.deinit(self.allocator);
        self.watched.deinit(self.allocator);
        self.park_fds.deinit(self.allocator);
        self.buffer_pool.deinit();
    }

    /// Nothing to arm: the signaling inbox is the listener substrate.
    /// Reachability is the signaling inbox. There is nothing to choose.
    pub const ListenTarget = void;

    pub fn loopListenTarget(_: u16) ListenTarget {}

    pub fn openListener(_: *Backend, _: ListenTarget) !Fd {
        return listen_fd;
    }

    pub fn listenerAddress(_: *Backend, fd: Fd) !ListenerAddress {
        if (fd != listen_fd) return error.InvalidListener;
    }

    pub fn listenerPort(_: ListenerAddress) ?u16 {
        return null;
    }

    pub fn applyKeepalive(_: *Backend, _: Fd, _: completion.Keepalive) !void {
        return error.OperationUnsupported;
    }

    pub fn wireFraming(_: *Backend, _: Fd) model.transport.WireFraming {
        return .message;
    }

    pub const startDial = SignalingOps.startDial;
    pub const startAnswer = SignalingOps.startAnswer;
    pub const adoptAnswerer = SignalingOps.adoptAnswerer;
    pub const provideAnswer = SignalingOps.provideAnswer;
    pub const provideRemoteCandidate = SignalingOps.provideRemoteCandidate;
    pub const wake = SignalingOps.wake;
    pub const submitAccept = SignalingOps.submitAccept;

    pub const recycleBorrowed = ConnectionOps.recycleBorrowed;
    pub const verifiedChannelKey = ConnectionOps.verifiedChannelKey;
    pub const submitRecv = ConnectionOps.submitRecv;
    pub const submitSend = ConnectionOps.submitSend;

    pub const closeFd = LifecycleOps.closeFd;
    pub const shutdownFd = LifecycleOps.shutdownFd;
    pub const submitClose = LifecycleOps.submitClose;

    pub const poll = ReadinessOps.poll;
    pub const peek = ReadinessOps.peek;
    pub const readinessFd = ReadinessOps.readinessFd;
    pub const flush = ReadinessOps.flush;
    pub const waitBoundMs = ReadinessOps.waitBoundMs;
    pub const submitPoll = ReadinessOps.submitPoll;
    pub const submitCancel = ReadinessOps.submitCancel;
};
