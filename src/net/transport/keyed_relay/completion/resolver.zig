//! Asynchronous DNS ownership for the completion relay carrier.
//!
//! DNS lookup is the one blocking part of opening a hostname route. One
//! environment-owned `std.Io` task resolves the whole name, while the reactor
//! remains parked on `wakeFd`. Address connection attempts stay in the
//! completion backend and race there; this module never opens a socket.

const std = @import("std");

const address_race = @import("../address_race.zig");
const carrier_failure = @import("../../../carrier_failure.zig");
const operation_owner = @import("../../../operation_owner.zig");
const SpinLock = @import("../../../sync.zig").SpinLock;
const wake_channel = @import("../../../wake_channel.zig");

const Io = std.Io;
const IpAddress = Io.net.IpAddress;
pub const max_addresses = address_race.max_resolved_addresses;

pub const Result = union(enum) {
    addresses: struct {
        values: [max_addresses]IpAddress,
        len: u8,
    },
    failed: carrier_failure.Failure,
};

pub const Job = struct {
    runtime: *Runtime,
    operation: operation_owner.CancelableOperation = undefined,
    host: []u8,
    port: u16,
    owner_id: u32,
    canceled: std.atomic.Value(bool) = .init(false),
    result: Result = undefined,
    completed_next: ?*Job = null,
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    io: Io,
    operations: operation_owner.OperationOwner,
    wake: wake_channel.WakeChannel,
    wake_failure: wake_channel.FailureLatch = .{},
    completed_lock: SpinLock = .{},
    completed_head: ?*Job = null,
    completed_tail: ?*Job = null,
    live_jobs: usize = 0,
    closing: bool = false,

    /// Allocate at a stable address because resolver tasks and the reserved
    /// cancellation worker retain this runtime until `deinit` joins them.
    pub fn init(allocator: std.mem.Allocator, io: Io) !*Runtime {
        const self = try allocator.create(Runtime);
        errdefer allocator.destroy(self);
        const wake = try wake_channel.WakeChannel.open();
        errdefer wake.deinit();
        self.* = .{
            .allocator = allocator,
            .io = io,
            .operations = undefined,
            .wake = wake,
        };
        try self.operations.init(io);
        return self;
    }

    /// Start one copied-host lookup. Refusal transfers no job to the caller.
    pub fn start(self: *Runtime, owner_id: u32, host: []const u8, port: u16) !*Job {
        self.completed_lock.lock();
        const closing = self.closing;
        self.completed_lock.unlock();
        if (closing) return error.ResolverClosing;

        const owned_host = try self.allocator.dupe(u8, host);
        errdefer self.allocator.free(owned_host);
        const job = try self.allocator.create(Job);
        errdefer self.allocator.destroy(job);
        job.* = .{
            .runtime = self,
            .host = owned_host,
            .port = port,
            .owner_id = owner_id,
        };
        self.completed_lock.lock();
        self.live_jobs += 1;
        self.completed_lock.unlock();
        self.operations.startCancelable(
            &job.operation,
            resolve,
            .{job},
            job,
            retire,
        ) catch |err| {
            self.completed_lock.lock();
            self.live_jobs -= 1;
            self.completed_lock.unlock();
            return err;
        };
        return job;
    }

    /// Request cancellation without joining the reactor thread. Completion is
    /// still delivered through `takeCompleted`; the caller releases the job
    /// only after that terminal edge.
    pub fn cancel(self: *Runtime, job: *Job) void {
        if (job.runtime != self) return;
        job.canceled.store(true, .release);
        _ = self.operations.cancel(&job.operation);
    }

    pub fn wakeFd(self: *const Runtime) i32 {
        return self.wake.read;
    }

    /// A refused completion arm selects bounded polling: the owner leaves the
    /// arm visibly absent, caps its next wait, and retries. Results remain in
    /// this runtime's queue, so submission pressure cannot erase or falsely
    /// fail a resolver operation.
    pub fn maintainWake(self: *Runtime, backend: anytype, user_data: u64) void {
        if (backend.resolver_wake_armed) return;
        // best-effort: left unarmed, the next maintainWake call re-arms.
        backend.platform.submitRecv(user_data, self.wakeFd()) catch return;
        backend.resolver_wake_armed = true;
    }

    pub fn drainWake(self: *Runtime) wake_channel.Failure!void {
        try self.wake_failure.check();
        self.wake.drain() catch |err| {
            self.wake_failure.record(err);
            return err;
        };
    }

    pub fn takeCompleted(self: *Runtime) ?*Job {
        self.completed_lock.lock();
        defer self.completed_lock.unlock();
        const job = self.completed_head orelse return null;
        self.completed_head = job.completed_next;
        if (self.completed_head == null) self.completed_tail = null;
        job.completed_next = null;
        return job;
    }

    pub fn hasLiveJobs(self: *Runtime) bool {
        self.completed_lock.lock();
        defer self.completed_lock.unlock();
        return self.live_jobs != 0;
    }

    pub fn release(self: *Runtime, job: *Job) void {
        std.debug.assert(job.runtime == self);
        self.allocator.free(job.host);
        self.allocator.destroy(job);
        self.completed_lock.lock();
        std.debug.assert(self.live_jobs != 0);
        self.live_jobs -= 1;
        self.completed_lock.unlock();
    }

    /// Final barrier. The owner must first cancel every known job and consume
    /// every completion, so no failure fact disappears during destruction.
    pub fn deinit(self: *Runtime) void {
        self.completed_lock.lock();
        self.closing = true;
        self.completed_lock.unlock();
        self.operations.join();
        self.completed_lock.lock();
        const clean = self.live_jobs == 0 and self.completed_head == null;
        self.completed_lock.unlock();
        std.debug.assert(clean);
        self.wake.deinit();
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};

fn resolve(job: *Job) void {
    defer _ = job.runtime.operations.reap(&job.operation);
    const host = Io.net.HostName.init(job.host) catch |err| {
        job.result = .{ .failed = .init(.resolve, err) };
        return;
    };
    var queue_storage: [max_addresses]Io.net.HostName.LookupResult = undefined;
    var queue: Io.Queue(Io.net.HostName.LookupResult) = .init(&queue_storage);
    // `resolve` already runs inside the one owned resolver task. The standard
    // lookup contract cannot block on a queue with at least 16 seats, so 32
    // seats let it finish directly and keep cancellation under OperationOwner
    // rather than creating a second future with a second retirement edge.
    Io.net.HostName.lookup(host, job.runtime.io, &queue, .{ .port = job.port }) catch |err| {
        job.result = .{ .failed = .init(.resolve, err) };
        return;
    };

    var values: [max_addresses]IpAddress = undefined;
    var len: u8 = 0;
    var overflow = false;
    while (queue.getOneUncancelable(job.runtime.io)) |item| switch (item) {
        .canonical_name => {},
        .address => |address| {
            if (len < max_addresses) {
                values[len] = address;
                len += 1;
            } else overflow = true;
        },
    } else |queue_error| switch (queue_error) {
        error.Closed => {},
    }
    if (job.canceled.load(.acquire)) {
        job.result = .{ .failed = .init(.resolve, error.Canceled) };
    } else if (overflow) {
        job.result = .{ .failed = .init(.resolve, error.TooManyAddresses) };
    } else if (len == 0) {
        job.result = .{ .failed = .init(.resolve, error.NoAddressReturned) };
    } else {
        job.result = .{ .addresses = .{ .values = values, .len = len } };
    }
}

fn retire(context: *anyopaque) void {
    const job: *Job = @ptrCast(@alignCast(context));
    const runtime = job.runtime;
    // A targeted group cancellation may stop `resolve` before it can publish
    // its own result. Cancellation is the exact terminal fact in that case.
    if (job.canceled.load(.acquire))
        job.result = .{ .failed = .init(.resolve, error.Canceled) };

    runtime.completed_lock.lock();
    if (runtime.completed_tail) |tail|
        tail.completed_next = job
    else
        runtime.completed_head = job;
    runtime.completed_tail = job;
    runtime.completed_lock.unlock();
    _ = runtime.wake.nudge() catch |err| runtime.wake_failure.record(err);
}
