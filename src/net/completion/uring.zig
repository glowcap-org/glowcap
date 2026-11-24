//! The Linux io_uring completion backend for `completion.Loop`.
//!
//! It implements the completion-backend interface documented in
//! `completion.Loop` (`loop.zig`) and provides the io_uring primitive and Zig
//! TCP socket operations. All portable connection orchestration lives in
//! `completion.Loop`, which is generic over this backend.
//!
//! Linux reaches this backend through `linux.zig`. That selector uses the epoll
//! sibling when the host cannot supply the required io_uring facilities. The
//! kqueue (Darwin) sibling implements the same interface. A Windows IOCP
//! backend is not implemented. The portable server does not change when a
//! backend is added.
//!
//! io_uring is a true completion (proactor) model: operations are submitted to
//! a ring and the kernel posts a completion when each finishes. `submit*`
//! queues an SQE. `poll` flushes the queue, waits for at least one completion,
//! and hands the results back to the server.
//!
//! The ring holds no operation on a listener's descriptor, neither one this
//! backend opened nor one a caller polls for a listener. A pending ring
//! operation holds its own reference to the socket, so one armed on a
//! listener would keep the port bound after a killed process. Listener work
//! (open, accept, poll, and the close or cancel of one that is armed) runs on
//! an inner `epoll.Backend`, created with the first listener, and the ring
//! keeps one multishot poll on that backend's epoll descriptor. An epoll
//! registration holds no reference to its socket, so the ring holds only the
//! epoll file.
//!
//! A listener operation costs `epoll` syscalls the ring path does not: an
//! accept is one `epoll_ctl` add when armed, a zero-timeout `epoll_wait` on
//! the next turn and again on the turn after, and one `epoll_ctl` delete when
//! it completes. A listener poll costs the same. Connections, which carry the
//! wire traffic, never touch the inner backend. A `poll` that parks submits
//! once more first, and only when an entry is queued: the ring's shared head
//! and tail say so, so a turn with nothing queued adds no syscall.
//!
//! The shared read-buffer pool (ADR-0019) is a kernel provided-buffer ring: one
//! buffer group is registered at init, recvs are submitted with buffer select
//! (no caller buffer), the kernel picks a buffer when data arrives and names it
//! on the CQE, and `recycleBorrowed` returns it to the ring. A recv that finds the
//! ring empty completes with `ENOBUFS`, which surfaces to the loop as
//! `Completion.recv_no_buffer`: pool contention, never a connection error.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const IoUring = linux.IoUring;

const completion = @import("loop.zig");
const model = @import("model");
const socket_tcp = @import("socket_tcp.zig");
const tcp_keepalive = @import("tcp_keepalive.zig");
const epoll = @import("epoll.zig");
const kernel = @import("uring_kernel.zig");

comptime {
    if (builtin.target.os.tag != .linux) @compileError("the io_uring completion backend is Linux-only");
}

const tcp_os = socket_tcp.Os.linux;

pub const Backend = struct {
    pub const Fd = linux.fd_t;
    pub const adapter_depth = 0;
    /// Platform dial target: a resolved `IpAddress`. OCapN locator resolve
    /// lives on `tcp.DialResolver`, not on this platform Backend.
    pub const ConnectTarget = std.Io.net.IpAddress;
    pub const ListenerAddress = socket_tcp.Ip4;

    /// The one buffer group registered on the ring. Group ids only need to be
    /// unique per ring.
    const buf_group_id: u16 = 0;

    allocator: std.mem.Allocator,
    ring: IoUring,
    /// The kernel-shared provided-buffer ring. The mmap is owned here and is
    /// address-stable, so the backend struct itself can move by value.
    buf_ring: *align(std.heap.page_size_min) linux.io_uring_buf_ring,
    /// Backing storage for the pool: `buf_count` buffers of `buf_bytes` each.
    buffers: []u8,
    buf_bytes: u32,
    buf_count: u16,
    /// The local IPv4 address every listener binds. The port remains loop
    /// policy and arrives later through `openListener`.
    listener_ip4: [4]u8,
    /// The backend every listener operation runs on, created with the first
    /// listener (`listenerBackend`). The ring waits on its epoll descriptor,
    /// never on a listening socket: a pending ring operation holds its own
    /// reference to the file it waits on, and a listener held that way
    /// outlives a process that dies without closing it. Heap-allocated so the
    /// ring's watch and this pointer stay valid when the backend moves, and so
    /// a backend that never listens pays only the pointer.
    inner: ?*epoll.Backend = null,
    /// Whether the ring's multishot poll on the inner epoll descriptor is
    /// queued or live. Its completion without `IORING_CQE_F_MORE` ends it, and
    /// the CQE path queues it again.
    watch_armed: bool = false,
    /// True unless the last inner peek returned nothing and no delegated
    /// submit or watch completion has followed it, so a false `dirty` means
    /// the inner backend holds no completion the ring has not announced.
    /// `peek` consults the inner backend only while `dirty`, which keeps it
    /// free of syscalls in steady state.
    dirty: bool = false,
    /// The first refusal that blocks every ring submission. A connect entry
    /// names a stack address the kernel copies only on a successful submit, so
    /// once that submit refuses, nothing may hand the queue to the kernel
    /// again. Every later submit, listener operation, and flush reports the cause.
    /// `listener_fault` is the other latch: it ends listener work and leaves the
    /// ring's own operations free.
    fault: ?anyerror = null,
    /// The first failure of the ring's watch on the inner epoll descriptor,
    /// named by `completion.failureFromErrno`. The watch is not queued again,
    /// so an accept or listener poll the inner backend holds can no longer
    /// wake the ring. Their owners see the cause once from `poll` or `peek`
    /// (`deferred_error`), and `openListener`, `submitAccept`, and a listener
    /// `submitPoll` refuse with it. Closing or cancelling a held operation
    /// still completes it, which is how a loop retires. Connections are
    /// untouched, and a later failure never replaces the first.
    listener_fault: ?anyerror = null,
    /// An error held for the next `poll` or `peek`, which returns it before it
    /// reaps anything, as the epoll backend does: the inner backend's own
    /// deferred error met in a batch that already holds completions, or the
    /// cause of `listener_fault`. A held error is never replaced.
    deferred_error: ?anyerror = null,
    /// Which source `drainCompletions` serves first while the inner backend
    /// may hold work. It flips on each such call, so a full `out` starves
    /// neither: what one call leaves stays in the CQ ring or the inner
    /// backend, and `readyPending` reports it.
    listener_turn: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        queue_entries: u16,
        read_buffers: u16,
        read_buffer_bytes: u32,
    ) !Backend {
        return initWithListenerIp4(
            allocator,
            queue_entries,
            read_buffers,
            read_buffer_bytes,
            .{ 127, 0, 0, 1 },
        );
    }

    /// Build a backend whose listener binds `listener_ip4`. The ordinary
    /// constructor keeps the least-exposed default, `127.0.0.1`. A service
    /// intended for other hosts can opt into an interface address or
    /// `0.0.0.0` before moving the backend into `Loop.initWithBackend`.
    pub fn initWithListenerIp4(
        allocator: std.mem.Allocator,
        queue_entries: u16,
        read_buffers: u16,
        read_buffer_bytes: u32,
        listener_ip4: [4]u8,
    ) !Backend {
        if (read_buffer_bytes == 0) return error.InvalidReadBufferBytes;
        // Translate generic std errors at the call that owns their meaning.
        // Later constructor work can return the same names without selecting
        // a different Linux backend.
        var ring = IoUring.init(queue_entries, 0) catch |err| return kernel.classifyInitFailure(err);
        errdefer ring.deinit();
        // `poll` waits inside the ring with a timeout, which the kernel takes
        // as an extended enter argument from 5.11. The provided-buffer ring
        // below needs 5.19, so this only keeps the refusal exact.
        if (ring.features & linux.IORING_FEAT_EXT_ARG == 0) return error.IoUringSystemOutdated;

        // The kernel requires a power-of-two ring; round the requested pool up.
        const count = try std.math.ceilPowerOfTwo(u16, @max(read_buffers, 1));
        const buf_ring = IoUring.setup_buf_ring(ring.fd, count, buf_group_id, .{ .inc = false }) catch |err| {
            // The arguments above are locally validated and fixed. EINVAL from
            // REGISTER_PBUF_RING therefore means this kernel exposes io_uring
            // without the provided-buffer facility this backend requires.
            // Name that capability miss so the Linux selector can fall back.
            // Unrelated setup failures remain fatal.
            return kernel.classifyBufferRingFailure(err);
        };
        errdefer IoUring.free_buf_ring(ring.fd, buf_ring, count, buf_group_id);

        // Allocate backing bytes only after the kernel accepts the ring. A
        // fallback host should never allocate the io_uring pool it cannot use.
        const buffers = try allocator.alloc(u8, @as(usize, count) * read_buffer_bytes);
        errdefer allocator.free(buffers);

        IoUring.buf_ring_init(buf_ring);
        const mask = IoUring.buf_ring_mask(count);
        var id: u16 = 0;
        while (id < count) : (id += 1) {
            const pos = @as(usize, read_buffer_bytes) * id;
            IoUring.buf_ring_add(buf_ring, buffers[pos .. pos + read_buffer_bytes], id, mask, id);
        }
        IoUring.buf_ring_advance(buf_ring, count);

        return .{
            .allocator = allocator,
            .ring = ring,
            .buf_ring = buf_ring,
            .buffers = buffers,
            .buf_bytes = read_buffer_bytes,
            .buf_count = count,
            .listener_ip4 = listener_ip4,
        };
    }

    /// The ring goes first and the inner backend after it. The ring's watch
    /// holds its own reference to the inner epoll file, so neither order
    /// leaves the kernel naming a closed descriptor.
    pub fn deinit(self: *Backend) void {
        IoUring.free_buf_ring(self.ring.fd, self.buf_ring, self.buf_count, buf_group_id);
        self.allocator.free(self.buffers);
        self.ring.deinit();
        if (self.inner) |inner| {
            inner.deinit();
            self.allocator.destroy(inner);
        }
    }

    /// Take a free SQE, flushing the submission queue to the kernel when it is
    /// full. A dispatch batch can arm more operations than the ring has SQ
    /// entries (each of up to 256 completions may arm a recv and a send), and
    /// SQEs otherwise flush only in `poll` and `flush`, so without this a busy batch would
    /// fail healthy submissions, closing live connections or, on the accept
    /// re-arm, killing the whole loop. The mid-batch flush is safe: the kernel
    /// buffers completion overflow, and `poll` still reaps everything.
    fn getSqe(self: *Backend) !*linux.io_uring_sqe {
        if (self.fault) |err| return err;
        return self.ring.get_sqe() catch {
            try self.submitRing();
            return self.ring.get_sqe();
        };
    }

    /// Hand queued submissions to the kernel without reaping. Until then a
    /// submitted operation cannot complete, so `readinessFd` cannot report it.
    /// An empty submission queue costs no syscall: the ring's shared head and
    /// tail say whether anything waits, and an enter with nothing to submit
    /// and nothing to wait for does no work.
    pub fn flush(self: *Backend) !void {
        if (self.fault) |err| return err;
        // A watch the CQE path could not queue again is armed here.
        try self.armWatch();
        if (self.ring.sq_ready() == 0) return;
        try self.submitRing();
    }

    /// Nothing here waits on a timer: every completion arrives through the
    /// descriptor.
    /// A platform listener is bound when `openListener` returns. Nothing
    /// pends.
    pub fn listenerPending(_: *const Backend, _: Fd) bool {
        return false;
    }

    /// Whether a completion or an error may be held for the next `peek`: a
    /// close or cancel the inner backend queued, an accept whose listener
    /// already has a connection waiting, a completion left because `out` was
    /// full, or a held error. The ring's descriptor reports none of these. A
    /// flush-only fault is not held work: it fails the next `flush`, not a peek.
    pub fn readyPending(self: *const Backend) bool {
        if (self.deferred_error != null) return true;
        const inner = self.inner orelse return false;
        return self.dirty or inner.readyPending();
    }

    pub fn waitBoundMs(_: *const Backend, requested_ms: i32) i32 {
        return requested_ms;
    }

    /// The descriptor that turns readable when `poll` has completions to
    /// return, once `flush` has run after the last submission. A resident
    /// that hands the loop's readiness to another waiter polls on it
    /// (`net.completion_resident`).
    pub fn readinessFd(self: *const Backend) Fd {
        return self.ring.fd;
    }

    /// Arm one accept on a listener this backend opened. It completes from
    /// `poll` or `peek` once the listener is readable, and a close completes
    /// it as the epoll backend does.
    pub fn submitAccept(self: *Backend, user_data: u64, listen_fd: Fd) !void {
        const inner = try self.listenerBackend();
        try inner.submitAccept(user_data, listen_fd);
        self.dirty = true;
    }

    /// The inner backend, created on first use. The set, its watch SQE, and
    /// the pointer all exist or none does: the watch is queued last, so a
    /// refusal anywhere frees what was built and commits nothing.
    fn listenerBackend(self: *Backend) !*epoll.Backend {
        if (self.fault) |err| return err;
        if (self.listener_fault) |err| return err;
        if (self.inner) |inner| return inner;
        const inner = try self.allocator.create(epoll.Backend);
        errdefer self.allocator.destroy(inner);
        // The pool is the smallest the epoll backend accepts and is never
        // used: connections never run on this backend. Accepted sockets stay
        // blocking because the ring's recv and send need that.
        inner.* = try epoll.Backend.initWithListenerIp4(self.allocator, 0, 1, 1, self.listener_ip4);
        errdefer inner.deinit();
        inner.accepted_flags = linux.SOCK.CLOEXEC;
        self.inner = inner;
        errdefer self.inner = null;
        try self.armWatch();
        return inner;
    }

    /// Queue the ring's one multishot poll on the inner epoll descriptor when
    /// it is not queued or live, and no failure ended it for good. It reports
    /// each readiness of the set, and a set already ready when the poll is
    /// submitted reports at once.
    fn armWatch(self: *Backend) !void {
        const inner = self.inner orelse return;
        if (self.watch_armed or self.listener_fault != null) return;
        const sqe = try self.getSqe();
        sqe.prep_poll_add(inner.epoll_fd, linux.POLL.IN);
        sqe.len = linux.IORING_POLL_ADD_MULTI;
        sqe.user_data = watch_ud;
        self.watch_armed = true;
    }

    /// Backend-private completion identity for the ring's watch on the inner
    /// epoll descriptor. Its top three bits are 7. The Loop's `Op` tags stay
    /// in 0...5, and the resident's `Kind` sits at bit 56 with a value of at
    /// most 8, so neither emits it.
    const watch_ud: u64 = 0b111 << 61;

    /// Start an outbound TCP connect: open a socket, submit connect, return the
    /// fd. On submit failure the socket is closed here, the Loop never sees it.
    pub fn startDial(self: *Backend, user_data: u64, target: ConnectTarget) !Fd {
        const fd = try openSocket();
        errdefer self.closeFd(fd);
        if (!socket_tcp.setNodelay(tcp_os, fd)) return error.SocketConfigurationFailed;
        try self.submitConnect(user_data, fd, target);
        return fd;
    }

    fn submitConnect(self: *Backend, user_data: u64, fd: Fd, target: ConnectTarget) !void {
        const ip4 = try socket_tcp.ip4FromTarget(target);
        var addr = socket_tcp.sockaddrIn4(tcp_os, ip4);
        const sqe = try self.getSqe();
        sqe.prep_connect(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
        sqe.user_data = user_data;
        // io_uring stores the sockaddr pointer in the SQE. Submit immediately so
        // the kernel copies it before this stack frame goes away. A refusal
        // leaves the entry queued with that address, so it latches `fault`.
        self.submitRing() catch |err| {
            self.fault = err;
            return err;
        };
    }

    /// Hand the submission queue to the kernel, retrying a signal interrupt,
    /// which leaves the queue as it was.
    fn submitRing(self: *Backend) !void {
        while (true) {
            _ = self.ring.submit() catch |err| switch (err) {
                error.SignalInterrupt => continue,
                else => return err,
            };
            return;
        }
    }

    /// Arm a buffer-select recv: the kernel picks a pool buffer when data
    /// arrives and names it on the CQE.
    pub fn submitRecv(self: *Backend, user_data: u64, fd: Fd) !void {
        const sqe = try self.getSqe();
        sqe.prep_rw(.RECV, fd, 0, 0, 0);
        sqe.rw_flags = 0;
        sqe.flags |= linux.IOSQE_BUFFER_SELECT;
        sqe.buf_index = buf_group_id;
        sqe.user_data = user_data;
    }

    /// A `readable` or `writable` poll rides the ring, and its CQE result is
    /// the ready event mask, which is non-negative. A `listener` poll runs on
    /// the inner backend instead and completes with 0. A descriptor holds one
    /// listener poll or armed accept at a time, and a second refuses with
    /// `error.DescriptorBusy` before any state changes, as does a `readable` or
    /// `writable` poll on a descriptor that holds listener work.
    pub fn submitPoll(self: *Backend, user_data: u64, fd: Fd, interest: completion.Interest) !void {
        if (interest == .listener) {
            const inner = try self.listenerBackend();
            try inner.submitPoll(user_data, fd, .listener);
            self.dirty = true;
            return;
        }
        // A descriptor a listener holds is one provider object's: a dial or
        // connection never shares it (`external/provider.zig`).
        if (self.tracked(fd)) return error.DescriptorBusy;
        const sqe = try self.getSqe(); // reports `fault`
        sqe.prep_poll_add(fd, switch (interest) {
            .readable => linux.POLL.IN,
            .writable => linux.POLL.OUT,
            .listener => unreachable,
        });
        sqe.user_data = user_data;
    }

    pub fn submitSend(self: *Backend, user_data: u64, fd: Fd, bytes: []const u8) !void {
        const sqe = try self.getSqe();
        sqe.prep_send(fd, bytes, 0);
        sqe.user_data = user_data;
    }

    pub fn submitCancel(
        self: *Backend,
        cancel_user_data: u64,
        target_user_data: u64,
        fd: Fd,
    ) !void {
        if (self.tracked(fd)) {
            // A listener poll or accept lives on the inner backend, not in the
            // ring: it completes the target with -1, then the cancel with 0.
            // A target the inner backend does not hold is a ring operation.
            if (self.inner.?.submitCancel(cancel_user_data, target_user_data, fd)) {
                self.dirty = true;
                return;
            } else |err| if (err != error.InvalidCancelTarget) return err;
        }
        const sqe = try self.getSqe();
        sqe.prep_cancel(target_user_data, 0);
        sqe.user_data = cancel_user_data;
    }

    /// A descriptor with an armed accept or listener poll closes on the inner
    /// backend, which completes each such operation with -1 and then the close
    /// with 0. Any other descriptor closes through the ring, so an operation
    /// of the ring's on it is cancelled first (`completion.Backend`).
    pub fn submitClose(self: *Backend, user_data: u64, fd: Fd) !void {
        if (self.tracked(fd)) {
            try self.inner.?.submitClose(user_data, fd);
            self.dirty = true;
            return;
        }
        const sqe = try self.getSqe();
        sqe.prep_close(fd);
        sqe.user_data = user_data;
    }

    /// Whether the inner backend holds an operation on `fd`.
    fn tracked(self: *const Backend, fd: Fd) bool {
        const inner = self.inner orelse return false;
        return inner.tracks(fd);
    }

    /// Return a recv completion's pool buffer to the kernel ring. This base
    /// backend creates only receive borrows. Richer wrapper-owned borrows are
    /// consumed by their wrapper before they can reach this seam.
    /// Sockets carry no lower-layer peer identity: the total Backend
    /// contract's `verifiedChannelKey` member (ADR-0028) always answers null.
    pub fn verifiedChannelKey(self: *Backend, fd: Fd) ?[32]u8 {
        _ = self;
        _ = fd;
        return null;
    }

    pub fn applyKeepalive(_: *Backend, fd: Fd, keepalive: completion.Keepalive) tcp_keepalive.ApplyError!void {
        return tcp_keepalive.apply(@intCast(fd), keepalive);
    }

    pub fn wireFraming(_: *Backend, _: Fd) model.transport.WireFraming {
        return .byte_stream;
    }

    pub fn recycleBorrowed(self: *Backend, comp: completion.Completion) void {
        std.debug.assert(comp.borrowed.kind == .recv);
        const buffer_id: u16 = @intCast(comp.borrowed.token);
        IoUring.buf_ring_add(
            self.buf_ring,
            kernel.bufferSlice(self.buffers, self.buf_bytes, buffer_id),
            buffer_id,
            IoUring.buf_ring_mask(self.buf_count),
            0,
        );
        IoUring.buf_ring_advance(self.buf_ring, 1);
    }

    /// Flush queued submissions, reap, and otherwise wait inside the ring
    /// for the first completion or `timeout_ms` (negative waits without
    /// limit), copying up to `out.len` completions back with each selected
    /// pool buffer as a borrowed view. The kernel runs the receive work it
    /// owes this thread inside the wait, before it checks the queue, so a
    /// reply that lands while the thread parks wakes it once. A poll on the
    /// ring's descriptor would wake the thread once to run that work and
    /// again for the completion it posts. A zero timeout submits and then
    /// peeks: the completion ring is shared memory, so an empty ring is
    /// final without a wait syscall. A signal ends the turn empty, and the
    /// loop owns the deadline. A turn that reaped only the listener watch
    /// queued it again, so a poll that parks submits first, and a wait without
    /// a limit waits again where a finite one returns the empty turn.
    pub fn poll(self: *Backend, out: []completion.Completion, timeout_ms: i32) !usize {
        try self.flush();
        var waited = false;
        while (true) {
            const reaped = try self.drainCompletions(out);
            if (reaped) |n| if (n > 0) return n;
            // A watch that ended in failure this turn holds its cause for the
            // next drain. Nothing else may be ready to end a park, so the
            // cause is returned before waiting.
            if (self.deferred_error != null) continue;
            if (timeout_ms == 0) return 0;
            if (waited and (timeout_ms >= 0 or reaped == null)) return 0;
            try self.flush();
            try kernel.waitInRing(self.ring.fd, timeout_ms);
            waited = true;
        }
    }

    /// Reap what the kernel has already completed and submit nothing, so a
    /// caller that batches its submissions for one later `flush` can still
    /// turn completions into state between verbs.
    pub fn peek(self: *Backend, out: []completion.Completion) !usize {
        return (try self.drainCompletions(out)) orelse 0;
    }

    /// Reap the ring and the inner backend into `out`. `null` is a turn that
    /// reaped nothing at all, and zero a turn that reaped only the watch.
    /// A held error comes first, before anything is reaped. After that the two
    /// sources alternate which goes first while the inner backend may hold
    /// work (`listener_turn`), and the second takes the room the first left.
    /// Every CQE copied is turned into a completion: nothing here returns early
    /// past one, so a failure found along the way waits in `deferred_error`.
    fn drainCompletions(self: *Backend, out: []completion.Completion) !?usize {
        if (self.deferred_error) |err| {
            self.deferred_error = null;
            return err;
        }
        var produced: usize = 0;
        if (self.dirty) {
            const listeners_first = self.listener_turn;
            self.listener_turn = !self.listener_turn;
            if (listeners_first) produced += try self.serveListeners(out, produced);
        }
        var cqes: [256]linux.io_uring_cqe = undefined;
        const want = @min(out.len - produced, cqes.len);
        const n = if (want == 0) 0 else try self.ring.copy_cqes(cqes[0..want], 0);
        for (cqes[0..n]) |cqe| {
            if (cqe.user_data == watch_ud) {
                self.watchReported(cqe);
                continue;
            }
            out[produced] = kernel.completionFromCqe(cqe, self.buffers, self.buf_bytes);
            produced += 1;
        }
        // The watch may have just reported, or the first pass left room.
        if (self.dirty and produced < out.len) produced += try self.serveListeners(out, produced);
        return if (n == 0 and produced == 0) null else produced;
    }

    /// Reap the inner backend into `out[produced..]`. While `dirty` its set may
    /// hold a completion the ring has not announced, and `dirty` stays set as
    /// long as a peek finds one. The inner backend's error is returned when
    /// nothing was reaped this call, once, as the epoll backend returns it. When
    /// ring completions are already in `out` it waits in `deferred_error`, so
    /// they are not dropped.
    fn serveListeners(self: *Backend, out: []completion.Completion, produced: usize) !usize {
        const got = self.inner.?.peek(out[produced..]) catch |err| {
            if (produced == 0) return err;
            if (self.deferred_error == null) self.deferred_error = err;
            return 0;
        };
        self.dirty = got != 0;
        return got;
    }

    /// A watch completion makes the inner backend worth a peek. One that ends
    /// without `IORING_CQE_F_MORE` is queued again here, so no turn leaves the
    /// listeners deaf. One that ends in failure latches `listener_fault`: only
    /// the ring's teardown or an explicit cancel ends one without error, and
    /// any other refusal would repeat on every re-arm. The latch keeps every
    /// completion this call's caller already holds.
    fn watchReported(self: *Backend, cqe: linux.io_uring_cqe) void {
        self.dirty = true;
        if (cqe.flags & linux.IORING_CQE_F_MORE != 0) return;
        self.watch_armed = false;
        const canceled = -@as(i32, @backingInt(linux.E.CANCELED));
        if (cqe.res < 0 and cqe.res != canceled) {
            const cause = completion.failureFromErrno(linux.errno(@as(usize, @bitCast(@as(isize, cqe.res)))));
            if (self.listener_fault == null) self.listener_fault = cause;
            if (self.deferred_error == null) self.deferred_error = cause;
            return;
        }
        // best-effort: a refusal (no submission slot) leaves the watch unarmed
        // until the next `flush`, which arms it and reports its own refusal;
        // `dirty` holds whatever the set gained meanwhile.
        self.armWatch() catch {};
    }

    /// The interface every listener binds. `openListener` chooses only the
    /// port.
    pub fn listenerIp4(self: *const Backend) [4]u8 {
        return self.listener_ip4;
    }

    /// The port a listener binds on the construction-time interface.
    pub const ListenTarget = u16;

    pub fn loopListenTarget(port: u16) ListenTarget {
        return port;
    }

    pub fn openListener(self: *Backend, port: u16) !Fd {
        return (try self.listenerBackend()).openListener(port);
    }

    pub fn openSocket() !Fd {
        return socket_tcp.openSocket(tcp_os);
    }

    pub fn listenerAddress(_: *Backend, fd: Fd) !ListenerAddress {
        const address = try socket_tcp.boundIp4(tcp_os, fd);
        return .{
            .bytes = address.bytes,
            .port = address.port,
        };
    }

    pub fn listenerPort(address: ListenerAddress) ?u16 {
        return address.port;
    }

    pub fn closeFd(self: *Backend, fd: Fd) void {
        if (self.tracked(fd)) return self.inner.?.closeFd(fd); // an operation forgotten here completes nowhere
        _ = linux.close(fd);
    }

    /// Unblock an armed recv so `Loop.closeAndDrain` does not wait on a quiet peer.
    pub fn shutdownFd(self: *Backend, fd: Fd) void {
        _ = self;
        _ = linux.shutdown(fd, linux.SHUT.RDWR);
    }
};

/// Narrow test seam for the backend internals the tests drive. Empty in every
/// production build so platform internals do not become library surface.
pub const white_box = if (builtin.is_test) struct {
    pub const TestBackend = Backend;
    pub const initFailureFor = kernel.classifyInitFailure;
    pub const bufferRingFailureFor = kernel.classifyBufferRingFailure;
    pub const watch_user_data = Backend.watch_ud;
    pub const nodelayEnabled = socket_tcp.white_box.nodelayEnabled;

    /// Deliver a watch completion with `res`, as the ring would, without the ring.
    pub fn reportWatch(backend: *Backend, res: i32) void {
        backend.watchReported(.{ .user_data = Backend.watch_ud, .res = res, .flags = 0 });
    }
} else struct {};
