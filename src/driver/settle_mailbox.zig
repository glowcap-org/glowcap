//! The off-turn settle mailbox (ADR-0102 stage 4): the one sanctioned way a
//! worker thread hands a resolver settle back to the thread that owns its
//! Host. A worker calls `post` from any thread with that thread's `std.Io`;
//! the entry is recorded into a fixed slot under an io-aware mutex and the
//! owning thread is woken through the mailbox's socketpair. Under ADR-0089,
//! `WouldBlock` is coalesced success because unread bytes already make the read
//! half readable; every other wake fault is retained and terminalizes the
//! owner without abandoning rows admitted earlier. The owning thread drains
//! the wake and applies every recorded settle through the ordinary top-level
//! resolver verbs, so nothing about the Host's one-thread contract changes: the
//! mailbox carries the *call*, never the authority.
//!
//! `driver.HostRuntime` polls the mailbox's wake fd beside its wires; the
//! completion loop arms an ordinary recv on it (a socketpair is a socket,
//! which is why it is not a pipe). Both apply on their own thread.
//!
//! Bounds, named: the slots are allocated once at init — a post allocates
//! nothing — and each entry's payload clones into its slot's fixed storage,
//! so a full mailbox refuses `MailboxFull` and an oversized value refuses
//! `ValueTooLarge`, loudly, instead of blocking the loop or growing without
//! bound. Off-thread settles carry plain data only (`NotPlainData` otherwise):
//! a capability never crosses threads, per the decision.

const std = @import("std");
const model = @import("model");
const net = @import("net");
const driver_core = @import("driver_core");

const Io = std.Io;

pub const Resolution = union(enum) {
    fulfilled: model.Argument,
    broken: []const u8,
};

pub const PostError = error{
    /// Every slot holds an unapplied settle; the owning thread has not caught
    /// up. Retry after it drains, or treat as backpressure.
    MailboxFull,
    /// The cloned payload does not fit the slot's fixed storage
    /// (`slot_payload_bytes`). Settle with a smaller value, or move the bulk
    /// through a channel the application owns.
    ValueTooLarge,
    /// The value names a capability (a reference or handoff). Authority never
    /// crosses threads; an answer that carries it settles on the owning
    /// thread, or forwards to a send.
    NotPlainData,
    /// The settle was not committed because the owner could not be woken.
    /// The mailbox is unusable until its runtime is repaired or closed.
    WakeNudgeFailed,
    /// The owner already observed that its wake read half cannot be drained.
    WakeDrainFailed,
};

/// Fixed per-entry payload storage. A settle is a completion notice, not a
/// bulk channel; a worker with more bytes than this hands them over through
/// its own storage and settles with the key.
pub const slot_payload_bytes = 512;

/// Default slot count for `init`; an application expecting more concurrent
/// unapplied settles sizes it explicitly.
pub const default_slots = 16;

const Slot = struct {
    resolver_id: u64,
    resolution: Resolution,
    storage: [slot_payload_bytes]u8 align(16),
};

pub const SettleMailbox = struct {
    allocator: std.mem.Allocator,
    slots: []Slot,
    lock: Io.Mutex = .init,
    /// Ring state: `head` is the next entry to apply, `count` the recorded
    /// entries. Posts append at `head + count`; apply consumes at `head`.
    head: usize = 0,
    count: usize = 0,
    channel: net.wake_channel.WakeChannel,
    wake_failure: net.wake_channel.FailureLatch = .{},

    /// Allocate the mailbox on the heap — workers hold the pointer across
    /// threads, so it needs one stable address — with `slot_count` fixed
    /// slots and a `net.wake_channel.WakeChannel` as the wake.
    pub fn init(allocator: std.mem.Allocator, slot_count: usize) !*SettleMailbox {
        const channel = try net.wake_channel.WakeChannel.open();
        errdefer channel.deinit();
        const slots = try allocator.alloc(Slot, slot_count);
        errdefer allocator.free(slots);
        const self = try allocator.create(SettleMailbox);
        self.* = .{
            .allocator = allocator,
            .slots = slots,
            .channel = channel,
        };
        return self;
    }

    /// Tear down on the owning thread, after every worker holding this
    /// mailbox has stopped posting.
    pub fn deinit(self: *SettleMailbox) void {
        self.channel.deinit();
        const allocator = self.allocator;
        allocator.free(self.slots);
        allocator.destroy(self);
    }

    /// The fd the owning thread waits on: readable while posted settles are
    /// pending. Poll it beside the wires, or arm a recv on it in a
    /// completion loop — it is a socket on purpose.
    pub fn wakeFd(self: *const SettleMailbox) i32 {
        return self.channel.read;
    }

    /// Wake the owner without recording a settle — the stopper's share of
    /// the channel: a thread that flipped a done flag wakes the parked wait
    /// through the same sanctioned entry the settles use.
    pub fn wake(self: *SettleMailbox) net.wake_channel.Failure!void {
        try self.wake_failure.check();
        _ = self.channel.nudge() catch |err| {
            self.wake_failure.record(err);
            return err;
        };
    }

    /// Record a settle from any thread and wake the owner. The resolution is
    /// borrowed for the call and cloned into the slot; refusals are loud
    /// (`PostError`) and consume nothing.
    pub fn post(self: *SettleMailbox, io: Io, resolver_id: u64, resolution: Resolution) PostError!void {
        try self.wake_failure.check();
        if (resolution == .fulfilled and !model.argumentIsPlainData(&resolution.fulfilled)) {
            return PostError.NotPlainData;
        }
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        if (self.count == self.slots.len) return PostError.MailboxFull;
        const slot = &self.slots[(self.head + self.count) % self.slots.len];
        var fba = std.heap.FixedBufferAllocator.init(&slot.storage);
        slot.resolver_id = resolver_id;
        slot.resolution = switch (resolution) {
            .fulfilled => |value| .{
                .fulfilled = model.cloneArgument(fba.allocator(), value) catch
                    return PostError.ValueTooLarge,
            },
            .broken => |reason| .{
                .broken = fba.allocator().dupe(u8, reason) catch
                    return PostError.ValueTooLarge,
            },
        };
        self.count += 1;
        _ = self.channel.nudge() catch |err| {
            // The owner cannot consume this row while the ring lock is held.
            // Roll admission back so a failed post never settles later after
            // its caller has already observed refusal.
            self.count -= 1;
            self.wake_failure.record(err);
            return err;
        };
    }

    /// Drain the wake channel, on the owning thread, before applying: a post
    /// racing the apply leaves its byte unread, so the next wait wakes again
    /// rather than losing the entry.
    pub fn drainWake(self: *SettleMailbox) net.wake_channel.Failure!void {
        try self.wake_failure.check();
        self.channel.drain() catch |err| {
            self.wake_failure.record(err);
            return err;
        };
    }

    /// Apply every recorded settle through `host`'s top-level resolver verbs,
    /// on the thread that owns `host`.
    ///
    /// `AlreadySettled` means the resolver was already consumed and nothing
    /// is owed. Every other refusal is returned after all admitted rows are
    /// consumed, so the owner can terminalize without stranding later rows.
    /// The lock brackets only the ring bookkeeping; the resolver verb runs
    /// unlocked while the entry's slot stays reserved, so a concurrent post
    /// can fill every other slot but never the one being applied.
    pub fn apply(self: *SettleMailbox, io: Io, host: *driver_core.Host) !void {
        var first_failure: ?anyerror = null;
        while (true) {
            self.lock.lockUncancelable(io);
            if (self.count == 0) {
                self.lock.unlock(io);
                if (first_failure) |err| return err;
                return;
            }
            const slot = &self.slots[self.head % self.slots.len];
            self.lock.unlock(io);

            const outcome = switch (slot.resolution) {
                .fulfilled => |value| host.resolverFulfill(slot.resolver_id, value),
                .broken => |reason| host.resolverBreak(slot.resolver_id, reason),
            };
            outcome catch |err| switch (err) {
                // Already consumed: nothing was owed.
                error.AlreadySettled => {},
                else => if (first_failure == null) {
                    first_failure = err;
                },
            };

            self.lock.lockUncancelable(io);
            self.head +%= 1;
            self.count -= 1;
            self.lock.unlock(io);
        }
    }
};
